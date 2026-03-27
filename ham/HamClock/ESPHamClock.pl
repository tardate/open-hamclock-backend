#!/usr/bin/perl

use strict;
use warnings;
use CGI;

# —————————————————————————
# Configuration
# —————————————————————————

# —————————————————————————
# Pass query string through verbatim — no parsing, no validation needed here.
# voacap-service returns 400 with a clear message if params are missing.
# —————————————————————————

my $qs = $ENV{QUERY_STRING} || $ARGV[0] || '';

# Parse User-Agent (e.g., HamClock/4.22.1b01)
my $q = CGI->new;
my $ua_string = $q->user_agent() || "";
my ($client_ver) = $ua_string =~ m|/(\d+\.[\w\.]+)|;
my $type = ($client_ver =~ /b/i) ? "beta" : "stable";

my $query = CGI->new;
my $location_url = "http://clearskyinstitute.com/ham/HamClock/${qs}"; # The destination URL

print $query->redirect(-status => 307, -location => $location_url);
exit; # It is important to exit after a redirect
