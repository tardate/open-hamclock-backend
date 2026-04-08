#!/usr/bin/perl
#
# there's appears to have been an endpoint at CSI that returned some values. Current
# HamClocks don't call this endpoint but old ESPHamClocks do. I don't know that its used
# for anything. I'd rather not return information about the server if it's not necessary.
# So just return static values to avoid the 404.
#
use strict;
use warnings;

print "Content-type: text/plain\n\n";
print "1.00 1";
