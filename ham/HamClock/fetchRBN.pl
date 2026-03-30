#!/usr/bin/env perl
use strict;
use warnings;

use CGI qw(param header);
use LWP::UserAgent;
use URI;
use JSON::PP qw(decode_json);
use File::Spec;

# ---------------- Config ----------------
my $RBN_BASE    = 'https://www.reversebeacon.net/spots.php';
my $CACHE_DIR   = '/opt/hamclock-backend/cache';
my $CACHE_FILE  = File::Spec->catfile($CACHE_DIR, 'rbn_h_version.txt');
my $TIMEOUT_SEC = 15;

# Ensure cache directory exists (if possible)
if (!-d $CACHE_DIR) {
    mkdir $CACHE_DIR or die "Cannot create cache dir: $!" if !-e $CACHE_DIR;
}

# ---------------- Logic ----------------

# 1. Get current hash (from cache or default)
my $current_h = get_cached_h(); // '';

# 2. Extract CGI params
my $ofcall = uc(param('ofcall') // '');
my $maxage = int(param('maxage') // 3600);

if (!$ofcall) {
    print header(-type => 'text/plain', -status => 400);
    print "ERROR: Missing ofcall\n";
    exit;
}

# 3. Attempt the fetch
my $ua = LWP::UserAgent->new(timeout => $TIMEOUT_SEC, agent => 'HamClock-Relay/1.2');
my $json_data = fetch_rbn($ofcall, $maxage, $current_h);

# 4. Handle Hash Rotation (400 error with new ver_h)
if ($json_data->{error} && $json_data->{ver_h}) {
    $current_h = $json_data->{ver_h};
    save_cached_h($current_h);
    # Retry once with the new hash
    $json_data = fetch_rbn($ofcall, $maxage, $current_h);
}

# 5. Final Output
if ($json_data->{spots}) {
    print header(-type => 'text/plain; charset=ISO-8859-1');
    process_and_print($json_data);
} else {
    print header(-type => 'text/plain', -status => 502);
    print "ERROR: RBN Request Failed after retry.\n";
}

# ---------------- Subroutines ----------------

sub fetch_rbn {
    my ($call, $ma, $h) = @_;
    my $uri = URI->new($RBN_BASE);
    $uri->query_form(h => $h, ma => $ma, cdx => $call, s => 0, r => 100);
    
    my $res = $ua->get($uri);
    return {} unless $res->content; # Return empty if no content
    
    return eval { decode_json($res->decoded_content) } // {};
}

sub process_and_print {
    my $data = shift;
    my $spots = $data->{spots};
    my $info  = $data->{call_info} // {};

    for my $id (sort { $a <=> $b } keys %$spots) {
        my $s = $spots->{$id};
        my $de_call = $s->[0];
        my $hz = int(($s->[1] // 0) * 1000);
        
        my $de_grid = "";
        if ($info->{$de_call}) {
            $de_grid = latlon_to_maiden6($info->{$de_call}->[6], $info->{$de_call}->[7]);
        }
        
        # Format: epoch, ofgrid, ofcall, degrid, decall, mode, hz, snr
        printf("%d,,%s,%s,%s,%s,%d,%d\n", 
               $s->[-1], $s->[2], $de_grid, $de_call, guess_mode($hz), $hz, $s->[3]);
    }
}

# --- Cache Helpers ---
sub get_cached_h {
    return undef unless -f $CACHE_FILE;
    open my $fh, '<', $CACHE_FILE or return undef;
    my $h = <$fh>;
    close $fh;
    $h =~ s/\s+//g;
    return $h;
}

sub save_cached_h {
    my $h = shift;
    open my $fh, '>', $CACHE_FILE or warn "Could not write cache: $!";
    print $fh $h;
    close $fh;
}

# --- Standard Radio Helpers ---
sub guess_mode {
    my $f = shift;
    return 'FT8' if $f =~ /^(1840|3573|7074|10136|14074|18100|21074|24915|28074)000/;
    return 'FT4' if $f =~ /^(3568|7047|10140|14080|18104|21140|28180)000/;
    return 'CW';
}

sub latlon_to_maiden6 {
    my ($lat, $lon) = @_;
    return "" if !defined $lat || !defined $lon;
    my $ln = $lon + 180; my $lt = $lat + 90;
    my $f1 = chr(ord('A') + int($ln/20)); my $f2 = chr(ord('A') + int($lt/10));
    my $s1 = int(($ln%20)/2); my $s2 = int(($lt%10)/1);
    my $u1 = chr(ord('A') + int((($ln%20)%2)*12)); my $u2 = chr(ord('A') + int((($lt%10)%1)*24));
    return "$f1$f2$s1$s2$u1$u2";
}
