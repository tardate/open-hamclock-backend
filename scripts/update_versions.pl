#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;

# --- Configuration ---
my $owner      = "komacke";
my $repo       = "hamclock";
my $cache_dir  = "/opt/hamclock-backend/cache/version_cache";
my $tags_url   = "https://api.github.com/repos/$owner/$repo/tags";

mkdir $cache_dir unless -d $cache_dir;

my $ua = LWP::UserAgent->new(timeout => 15);
$ua->agent("Version-Cache-Updater/1.0");

# 1. Fetch Tags from GitHub
my $tags_resp = $ua->get($tags_url);
die "GitHub API Error: " . $tags_resp->status_line unless $tags_resp->is_success;

my $tags = decode_json($tags_resp->decoded_content);

my ($stable_tag, $beta_tag);
foreach my $tag (@$tags) {
    my $name = $tag->{name};
    $stable_tag = $name if (!$stable_tag && $name !~ /b/i);
    $beta_tag   = $name if (!$beta_tag   && $name =~ /b/i);
    last if $stable_tag && $beta_tag;
}

# 2. Process and Save to HC_RELEASE-stable.txt and HC_RELEASE-beta.txt
foreach my $item (
    { type => 'stable', tag => $stable_tag },
    { type => 'beta',   tag => $beta_tag   }
) {
    my $out_file = "$cache_dir/HC_RELEASE-" . $item->{type} . ".txt";
    
    # Handle missing tags
    if (!$item->{tag}) {
        open(my $fh, '>', $out_file) or die "Could not write $out_file: $!";
        print $fh "Unknown\n";
        close($fh);
        print "No version found for $item->{type}\n";
        next;
    }

    # --- Version Stripping Logic ---
    # Removes the 3rd field if present (e.g., 4.22.1 -> 4.22)
    # This looks for digit.digit.digit and captures just the first two
    my $display_version = $item->{tag};
    $display_version =~ s/^[vV]//;
    $display_version =~ s/^(\d+\.\d+)\.\d+/$1/; 

    # Fetch HC_RELEASE.txt content for this tag
    my $raw_url = "https://raw.githubusercontent.com/$owner/$repo/$item->{tag}/HC_RELEASE.txt";
    my $resp = $ua->get($raw_url);
    
    open(my $fh, '>', $out_file) or die "Could not write $out_file: $!";
    
    # Line 1: Stripped Version
    print $fh $display_version . "\n";

    my $status_msg = "Fetched version $display_version for $item->{type}";
    
    # Line 2+: Content or Fallback
    if ($resp->is_success && $resp->decoded_content =~ /\S/) {
        print $fh $resp->decoded_content;
        $status_msg .= " (with release notes)";
    } else {
        print $fh "No info for version " . $display_version . "\n";
        $status_msg .= " (no release notes found)";
    }
    
    close($fh);
    chmod 0644, $out_file; # Ensure web server can read it
    print "Success: Wrote $out_file -> $status_msg\n";
}
