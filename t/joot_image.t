#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Cwd ();
use Joot::Image;

$ENV{JOOT_CONFIG} = "$FindBin::Bin/unit.conf";
my $image = Joot::Image->new("http://example.com/joot/debian-5.0-i386-20101008.qcow2");
is( $image->name(), "debian-5.0-i386-20101008", "name is ok" );
is( $image->path(), Cwd::abs_path("./t/joot_home/images/debian-5.0-i386-20101008.qcow2"), "path is ok" );

$image = Joot::Image->new("http://example.com//joot/debian.5.0.qcow.gz");
is( $image->name(), "debian.5.0", "name is ok" );
$image = Joot::Image->new("http://example.com//joot/debian.5.0.qcow2.bz2");
is( $image->name(), "debian.5.0", "name is ok" );
is( $image->path(), Cwd::abs_path("./t/joot_home/images/debian.5.0.qcow2"), "path is ok" );
