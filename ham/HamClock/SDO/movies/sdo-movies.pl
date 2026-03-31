#!/usr/bin/perl
use strict;
use warnings;

# Define the mapping of filenames to their target URLs
my %movie_map = (
    "1024_211193171.mp4" => "https://suntoday.lmsal.com/suntoday/",
    "1024_HMIB.mp4" => "https://suntoday.lmsal.com/suntoday/",
    "1024_HMIIC.mp4" => "https://suntoday.lmsal.com/suntoday/",
    "1024_0131.mp4" => "https://suntoday.lmsal.com/suntoday/",
    "1024_0193.mp4" => "https://suntoday.lmsal.com/suntoday/",
    "1024_0211.mp4" => "https://suntoday.lmsal.com/suntoday/",
    "1024_0304.mp4" => "https://suntoday.lmsal.com/suntoday/",
);

# Get the filename from the query string (e.g., aia171.mp4)
my $filename = $ENV{'QUERY_STRING'};

if (exists $movie_map{$filename}) {
    # Print the 307 Redirect header
    print "Status: 307 Temporary Redirect\n";
    print "Location: $movie_map{$filename}\n\n";
} else {
    # Fallback if the filename isn't in your list
    print "Status: 404 Not Found\n";
    print "Content-type: text/plain\n\n";
    print "Movie not found.";
}
