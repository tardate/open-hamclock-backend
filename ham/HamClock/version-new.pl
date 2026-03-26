#!/usr/bin/perl
use strict;
use warnings;
use CGI;

my $q = CGI->new;
my $cache_dir = "/opt/hamclock-backend/cache";

print $q->header('text/plain');

# Parse User-Agent (e.g., HamClock/4.22.1b01)
my $ua_string = $q->user_agent() || "";

# We just need to check if there is a version string at all
my ($client_ver) = $ua_string =~ m|/(\d+\.[\w\.]+)|;

unless ($client_ver) {
    print "Unknown\n";
    exit;
}

# Determine file based on 'b' in the raw client version string
my $type = ($client_ver =~ /b/i) ? "beta" : "stable";
my $path = "$cache_dir/HC_RELEASE-$type.txt";

if (-f $path) {
    open(my $fh, '<', $path) or die "Cannot open $path: $!";
    local $/; # Slurp the whole file
    my $content = <$fh>;
    close($fh);
    print $content;
} else {
    print "Unknown\n";
}
