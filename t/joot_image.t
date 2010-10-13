#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Joot::Image;

$ENV{JOOT_CONFIG} = "$FindBin::Bin/unit.conf";
my $image = Joot::Image->new("http://example.com/joot/debian-5.0-i386-20101008.qcow2");
is( $image->name(), "debian-5.0-i386-20101008", "name is ok" );
is( $image->path(), "./joot_home/images/debian-5.0-i386-20101008.qcow2", "path is ok" );

$image = Joot::Image->new("http://example.com//joot/debian.5.0.tgz" );
is( $image->name(), "debian.5.0", "name is ok" );
is( $image->path(), "./joot_home/images/debian.5.0.tgz", "path is ok" );


