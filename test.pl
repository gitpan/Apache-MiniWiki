#!/usr/bin/perl


use lib qw(blib/lib);

use Test::Simple tests => 1;

use Apache::MiniWiki;

ok ($Apache::MiniWiki::VERSION >= 0.4, "loaded Apache::MiniWiki >= 0.4");


