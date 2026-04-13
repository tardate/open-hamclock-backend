#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;
use Sort::Versions;
use Digest::SHA;

# --- Configuration ---
my $owner      = "komacke";
my $repo       = "hamclock";
my $cache_dir  = "/opt/hamclock-backend/cache";
my $tags_url   = "https://api.github.com/repos/$owner/$repo/tags";
my $v3_ver     = "3.10";  # Hardcoded legacy version support
my $host_hostname = $ENV{'HOST_HOSTNAME'} // 'ohb.hamclock.app';

mkdir $cache_dir unless -d $cache_dir;

# Increased timeout to 60s for binary downloads
my $ua = LWP::UserAgent->new(timeout => 60);
$ua->agent("Version-Cache-Updater/1.0");

# Helper to verify SHA256 and cleanup on failure
sub verify_and_cleanup {
    my ($file_path, $sha_url, $associated_files) = @_;
    return 1 unless -f $file_path;

    my $sha_resp = $ua->get($sha_url);
    if (!$sha_resp->is_success) {
        print "Warning: Could not fetch SHA256 from $sha_url. Skipping verification.\n";
        return 1;
    }

    # Extract the first column (the hash) from the sha256sum file content
    my $expected_sha = (split(/\s+/, $sha_resp->decoded_content))[0];
    my $sha = Digest::SHA->new(256);
    $sha->addfile($file_path);
    my $actual_sha = $sha->hexdigest;

    if ($actual_sha eq $expected_sha) {
        return 1;
    } else {
        print "Error: SHA256 mismatch for $file_path! Deleting artifacts.\n";
        unlink $file_path;
        foreach my $f (@$associated_files) {
            unlink $f if -f $f;
        }
        return 0;
    }
}

# 1. Fetch Tags from GitHub
my $tags_resp = $ua->get($tags_url);
die "GitHub API Error: " . $tags_resp->status_line unless $tags_resp->is_success;

my $tags_data = decode_json($tags_resp->decoded_content);

my $tags = [];
foreach my $t (@$tags_data) {
    my $original = $t->{name};
    my $clean = $original;
    $clean =~ s/^[vV]//; # Strip v/V for sorting purposes
    push @$tags, { clean => $clean, original => $original };
}

my ($stable_tag, $beta_tag);
foreach my $tag (@$tags) {
    if (!$stable_tag && $tag->{clean} !~ /b/i) {
        $stable_tag = $tag;
    }
    if (!$beta_tag && $tag->{clean} =~ /b/i) {
        $beta_tag = $tag;
    }
    last if $stable_tag && $beta_tag;
}

# 2. Process and Save to .txt, .tag, and .zip files
# Added the '3.10' type to the loop, using the stable_tag as the source
foreach my $item (
    { type => 'stable', data => $stable_tag },
    { type => 'beta',   data => $beta_tag   },
    { type => $v3_ver,  data => $stable_tag }
) {
    my $base_name = "$cache_dir/HC_RELEASE-" . $item->{type};
    my $txt_file  = "$base_name.txt";
    my $tag_file  = "$base_name.tag";

    # Handle missing tags from API
    if (!$item->{data}) {
        print "No version found for $item->{type}\n";
        next;
    }

    my $clean_ver = $item->{data}->{clean};
    my $orig_ver  = $item->{data}->{original};

    # Determine current display version
    # If type is 3.10, force display version to 3.10; otherwise use clean_ver
    my $display_version = ($item->{type} eq $v3_ver) ? $v3_ver : $clean_ver;
    $display_version =~ s/^(\d+\.[\db]+)\..*/$1/i;

    # --- Change Detection Logic ---
    if (-f $txt_file) {
        if (open(my $cfh, '<', $txt_file)) {
            my $existing_version = <$cfh>;
            close($cfh);
            if ($existing_version) {
                chomp($existing_version);
                $existing_version =~ s/\R//g;
                if ($existing_version eq $display_version) {
                    print "Skipping $item->{type}: Version $display_version is already up to date.\n";
                    next;
                }
            }
        }
    }

    # --- If we are here, an update is needed ---

    # 1. Download the Release Asset ZIP
    my $zip_filename = "ESPHamClock-V$display_version.zip";
    my $zip_path     = "$cache_dir/$zip_filename";
    my $zip_url      = "https://github.com/$owner/$repo/releases/download/$orig_ver/$zip_filename";
    my $zip_sha_url  = "$zip_url.sha256";

    print "Update found! Downloading $item->{type} asset from $zip_url...\n";
    my $zip_resp = $ua->get($zip_url, ':content_file' => $zip_path);

    if ($zip_resp->is_success) {
        chmod 0644, $zip_path;
        # Check SHASUM; if it fails, delete artifacts and move to next type
        unless (verify_and_cleanup($zip_path, $zip_sha_url, [$txt_file, $tag_file])) {
            next;
        }
        print "Successfully saved and verified $zip_path\n";
    } else {
        print "Error: Failed to download $zip_filename. Release asset might be missing from tag $orig_ver.\n";
        print "Status: " . $zip_resp->status_line . "\n";
        next;
    }

    # 1b. Additionally download the .ino.bin if this is the v3_ver (3.10)
    if ($item->{type} eq $v3_ver) {
        my $bin_filename = "ESPHamClock-V$display_version.ino.bin";
        my $bin_path     = "$cache_dir/$bin_filename";
        # TODO: after published as an asset, update this
        #my $bin_url      = "https://github.com/$owner/$repo/releases/download/$orig_ver/${host_hostname}_${bin_filename}";
        my $bin_url      = "https://github.com/$owner/$repo/raw/refs/heads/main/old-versions/${host_hostname}_${bin_filename}";
        my $bin_sha_url  = "$bin_url.sha256";

        print "Downloading additional binary asset from $bin_url...\n";
        my $bin_resp = $ua->get($bin_url, ':content_file' => $bin_path);
        if ($bin_resp->is_success) {
            chmod 0644, $bin_path;
            verify_and_cleanup($bin_path, $bin_sha_url, [$txt_file, $tag_file, $zip_path]);
        } else {
            print "Error: Failed to download $bin_filename.\n";
        }
    }

    # 2. Write the .tag file
    open(my $tfh, '>', $tag_file) or next;
    print $tfh $orig_ver . "\n";
    close($tfh);
    chmod 0644, $tag_file;

    # 3. Fetch HC_RELEASE-*.txt content and write .txt file
    my $github_txt = "HC_RELEASE-" . $item->{type} . ".txt";
    my $raw_url = "https://raw.githubusercontent.com/$owner/$repo/$orig_ver/$github_txt";
    my $resp = $ua->get($raw_url);

    open(my $fh, '>', $txt_file) or next;

    # Line 1: Stripped Version
    print $fh $display_version . "\n";

    my $status_msg = "Fetched $orig_ver for $item->{type}";

    # Line 2+: Content or Fallback
    if ($resp->is_success && $resp->decoded_content =~ /\S/) {
        print $fh $resp->decoded_content;
        $status_msg .= " (with release notes)";
    } else {
        print $fh "No info for version " . $display_version . "\n";
        $status_msg .= " (no release notes found)";
    }

    close($fh);
    chmod 0644, $txt_file;
    print "Success: Processed $item->{type} -> $status_msg\n";
}
