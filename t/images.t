#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Exception;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Joot;

$ENV{JOOT_CONFIG} = "$FindBin::Bin/unit.conf";
my $joot = Joot->new();
my $images;
lives_ok( sub { $images = $joot->images( "bogus" ); }, "list of images with bogus arg" );
lives_ok( sub { $images = $joot->images(); }, "list of images" );

isa_ok( $images, "HASH" );
foreach my $image_name ( keys %{ $images } ) {
    my $image = $images->{$image_name};
    isa_ok( $image, "Joot::Image" );
}
