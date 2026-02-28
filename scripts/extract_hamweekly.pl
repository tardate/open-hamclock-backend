#!/usr/bin/perl
use strict;
use warnings;
use XML::Feed;

binmode(STDOUT, ':encoding(UTF-8)');

my $url = 'https://daily.hamweekly.com/atom.xml';

my $feed = XML::Feed->parse(URI->new($url))
    or die XML::Feed->errstr;

for my $entry ($feed->entries) {
    my $headline = $entry->title;
    print "Hamweekly.com: $headline\n";
}
