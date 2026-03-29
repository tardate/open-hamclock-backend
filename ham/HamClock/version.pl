#!/usr/bin/perl
use strict;
use warnings;
use CGI;

my $q = CGI->new;
my $cache_dir = "/opt/hamclock-backend/cache";

print $q->header('text/plain');

# 1. Parse User-Agent (e.g., HamClock/4.22b01)
my $ua_string = $q->user_agent() || "";
my ($client_ver) = $ua_string =~ m|/([\d\.b]+)|i; 

unless ($client_ver) {
    print "Unknown\n";
    exit;
}

# 2. Get the current Stable version number
my $stable_ver_num = "";
my $stable_path = "$cache_dir/HC_RELEASE-stable.txt";
if (-f $stable_path) {
    open(my $fh, '<', $stable_path) or die $!;
    $stable_ver_num = <$fh>;
    close($fh);
    $stable_ver_num =~ s/\s+//g; # Clean up whitespace/newlines
}

# 3. Determine Offer Type
my $offer_type = "stable";

if ($client_ver =~ /b/i) {
    # Extract numeric base: "4.22b01" -> "4.22"
    my ($base_ver) = $client_ver =~ /^([\d\.]+)/;

    # Logic: Only stay on beta if base_ver > stable_ver_num
    if ($base_ver && $stable_ver_num) {
        if (version_cmp($base_ver, $stable_ver_num) > 0) {
            $offer_type = "beta";
        } else {
            # base is 4.22, stable is 4.22 -> offer stable
            $offer_type = "stable";
        }
    }
}

# 4. Output the file
my $final_path = "$cache_dir/HC_RELEASE-$offer_type.txt";
if (-f $final_path) {
    open(my $fh, '<', $final_path) or die $!;
    local $/;
    my $content = <$fh>;
    close($fh);
    print $content;
} else {
    print "Unknown\n";
}

# Robust version comparison: returns 1 if v1 > v2, -1 if v1 < v2, 0 if equal
sub version_cmp {
    my ($v1, $v2) = @_;
    my @a = split(/\./, $v1);
    my @b = split(/\./, $v2);
    while (@a || @b) {
        my $curr_a = shift @a || 0;
        my $curr_b = shift @b || 0;
        return 1  if $curr_a > $curr_b;
        return -1 if $curr_a < $curr_b;
    }
    return 0;
}
