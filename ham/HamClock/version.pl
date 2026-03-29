#!/usr/bin/perl
use strict;
use warnings;
use CGI;

my $q = CGI->new;
my $cache_dir = "/opt/hamclock-backend/cache";

print $q->header('text/plain');

# 1. Parse User-Agent (e.g., HamClock/4.22b01)
my $ua_string = $q->user_agent() || "";
my ($client_ver) = $ua_string =~ m|/([\d\.]+(?:b\d+)?)i?|; # Captures 4.22 or 4.22b01

unless ($client_ver) {
    print "Unknown\n";
    exit;
}

# 2. Get the current Stable version number from the cache file
my $stable_ver_num = "";
my $stable_path = "$cache_dir/HC_RELEASE-stable.txt";
if (-f $stable_path) {
    open(my $fh, '<', $stable_path) or die $!;
    $stable_ver_num = <$fh>;
    chomp($stable_ver_num) if $stable_ver_num;
    close($fh);
}

# 3. Determine if we should offer Stable or Beta
my $offer_type = "stable";

if ($client_ver =~ /b/i) {
    # It's a beta. Extract the base (e.g., 4.22 from 4.22b01)
    my ($base_ver) = $client_ver =~ /^([\d\.]+)/;

    # If the user's base version is GREATER than our stable, keep them on beta
    if ($base_ver && $stable_ver_num && is_version_greater($base_ver, $stable_ver_num)) {
        $offer_type = "beta";
    } else {
        # Base is <= stable (e.g., 4.22b01 vs 4.22), offer stable
        $offer_type = "stable";
    }
} else {
    # Not a beta user, stay on stable
    $offer_type = "stable";
}

# 4. Output the chosen file content
my $final_path = "$cache_dir/HC_RELEASE-$offer_type.txt";
if (-f $final_path) {
    open(my $fh, '<', $final_path) or die $!;
    local $/;
    print <$fh>;
    close($fh);
} else {
    print "Unknown\n";
}

### Helper to compare dotted versions (e.g., 4.9 vs 4.10)
sub is_version_greater {
    my ($v1, $v2) = @_;
    my @a = split(/\./, $v1);
    my @b = split(/\./, $v2);
    for (my $i = 0; $i < reverse(sort(@a, @b)); $i++) {
        $a[$i] //= 0;
        $b[$i] //= 0;
        return 1 if $a[$i] > $b[$i];
        return 0 if $a[$i] < $b[$i];
    }
    return 0;
}
