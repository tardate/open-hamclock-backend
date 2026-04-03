#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;

# 1. Primary NASA URLs (Direct links to files)
my %primary_map = (
    "1024_211193171.mp4" => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_211193171.mp4",
    "1024_HMIB.mp4"      => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_HMIB.mp4",
    "1024_HMIIC.mp4"     => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_HMIIC.mp4",
    "1024_0131.mp4"      => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0131.mp4",
    "1024_0193.mp4"      => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0193.mp4",
    "1024_0211.mp4"      => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0211.mp4",
    "1024_0304.mp4"      => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0304.mp4",
);

# 2. Fallback Base URLs (Filename will be appended)
my %fallback_base_map = (
    "1024_211193171.mp4" => "https://suntoday.lmsal.com/suntoday/",
    "1024_HMIB.mp4"      => "https://suntoday.lmsal.com/suntoday/",
    "1024_HMIIC.mp4"     => "https://suntoday.lmsal.com/suntoday/",
    "1024_0131.mp4"      => "https://suntoday.lmsal.com/suntoday/",
    "1024_0193.mp4"      => "https://suntoday.lmsal.com/suntoday/",
    "1024_0211.mp4"      => "https://suntoday.lmsal.com/suntoday/",
    "1024_0304.mp4"      => "https://suntoday.lmsal.com/suntoday/",
);

my $filename = $ENV{'QUERY_STRING'} || "";

if (exists $primary_map{$filename}) {
    my $ua = LWP::UserAgent->new;
    $ua->timeout(5); 
    
    # Check if NASA file is alive
    my $response = $ua->head($primary_map{$filename});

    if ($response->is_success) {
        # Success: Redirect to NASA
        redirect_to($primary_map{$filename});
    } else {
        # Failure: Construct fallback URL (Base + Filename)
        my $fallback_url = $fallback_base_map{$filename} . $filename;
        redirect_to($fallback_url);
    }
} else {
    print "Status: 404 Not Found\n";
    print "Content-type: text/plain\n\n";
    print "Movie not found.";
}

sub redirect_to {
    my ($url) = @_;
    print "Status: 307 Temporary Redirect\n";
    print "Location: $url\n\n";
    exit;
}
