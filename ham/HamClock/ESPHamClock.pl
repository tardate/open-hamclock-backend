#!/usr/bin/perl
use strict;
use warnings;
use CGI;

# --- Configuration ---
my $cache_dir    = "/opt/hamclock-backend/cache";

my $q = CGI->new;
# $q->keywords captures the $1 from the lighttpd rewrite (e.g., ESPHamClock.zip)
my ($query_file) = $q->keywords;
$query_file //= "";
my $user_agent = $q->user_agent() || "";

# 1. Determine the target filename
my $target_zip = "";

if ($query_file =~ /^ESPHamClock-V[\d\.]+(b\d+)?\.zip$/i) {
    # Case A: Specific version requested directly
    $target_zip = $query_file;
}
elsif ($query_file eq "ESPHamClock.zip") {
    # Case B: Generic request - Determine version from first line of .txt cache
    my $version_info_file;

    # Check if Agent indicates a beta user
    if ($user_agent =~ /^HamClock-.*\/.*b/i) {
        $version_info_file = "$cache_dir/HC_RELEASE-beta.txt";
    } else {
        $version_info_file = "$cache_dir/HC_RELEASE-stable.txt";
    }

    if (-e $version_info_file) {
        if (open(my $fh, '<', $version_info_file)) {
            my $version_line = <$fh>; # Read first line (the stripped version)
            close($fh);

            if ($version_line) {
                # \R handles all line ending types (\n, \r\n, etc.)
                $version_line =~ s/\R//g;
                # Constructs filename like ESPHamClock-V4.22.zip
                $target_zip = "ESPHamClock-V$version_line.zip";
            }
        }
    }
}

# 2. Check for file existence and serve
my $full_path = "$cache_dir/$target_zip";

if ($target_zip ne "" && -f $full_path) {
    my $filesize = -s $full_path;

    print $q->header(
        -type           => 'application/zip',
        -attachment     => $target_zip,
        -content_length => $filesize,
    );

    open(my $fh, '<', $full_path) or die "Cannot open file: $!";
    binmode $fh;
    binmode STDOUT;

    my $buffer;
    # Stream in 4KB chunks for memory efficiency
    while (read($fh, $buffer, 4096)) {
        print $buffer;
    }
    close($fh);
} else {
    # 404 Error: Either $target_zip was never set or the file is missing
    print $q->header(
        -status => '404 Not Found',
        -type   => 'text/plain'
    );
    print "404 Not Found: The requested version is not available on this server.\n";
}
