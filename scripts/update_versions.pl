#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;
use Sort::Versions;

# --- Configuration ---
my $owner      = "komacke";
my $repo       = "hamclock";
my $cache_dir  = "/opt/hamclock-backend/cache";
my $tags_url   = "https://api.github.com/repos/$owner/$repo/tags";

mkdir $cache_dir unless -d $cache_dir;

# Increased timeout to 60s for binary downloads
my $ua = LWP::UserAgent->new(timeout => 60);
$ua->agent("Version-Cache-Updater/1.0");

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
foreach my $item (
    { type => 'stable', data => $stable_tag },
    { type => 'beta',   data => $beta_tag   }
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

    # Determine current display version (stripped)
    my $display_version = $clean_ver;
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

    print "Update found! Downloading $item->{type} asset from $zip_url...\n";
    my $zip_resp = $ua->get($zip_url, ':content_file' => $zip_path);

    if ($zip_resp->is_success) {
        chmod 0644, $zip_path;
        print "Successfully saved $zip_path\n";
    } else {
        print "Error: Failed to download $zip_filename. Release asset might be missing from tag $orig_ver.\n";
        print "Status: " . $zip_resp->status_line . "\n";
        # Optionally 'next' here if you don't want to update .txt if zip fails
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
