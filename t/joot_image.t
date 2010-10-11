#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Joot::Image;

my $image = Joot::Image->new("http://example.com/joot/debian-5.0-i386-20101008.qcow2");
is( $image->name(), "debian-5.0-i386-20101008", "name" );

$image = Joot::Image->new("http://example.com//joot/debian.5.0.tgz" );
is( $image->name(), "debian.5.0", "name" );
