#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 10;
use Test::Exception;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Joot::Plugin::QCOW qw( nbd_connect nbd_disconnect is_disk_connected );

$ENV{JOOT_CONFIG} = "$FindBin::Bin/unit.conf";

# nbd_connect/nbd_disconnect/is_disk_connected/get_nbd_device
SKIP: {
    if ( $< != 0 ) {
        skip( "run these tests as root so they can run qemu-nbd", 10 );
    }
    my $device;
    my $disk = "$FindBin::Bin/data/test_image.qcow2";

    my $expected_dev;
    lives_ok( sub { $expected_dev = Joot::Plugin::QCOW::get_nbd_device() }, "get_nbd_device" );

    # if you call get_nbd_device twice you get the same thing because
    # nobody used the device
    is( $expected_dev, Joot::Plugin::QCOW::get_nbd_device(), "get_nbd_device called twice" );

    # return false because it's not connected yet
    ok( !is_disk_connected($disk), "is_disk_connected" );

    lives_ok( sub { $device = nbd_connect($disk) }, "connecting $disk" );
    is( $device, $expected_dev, "connected with expected device" );

    is( is_disk_connected($disk), $device, "is_disk_connected returns true" );

    # if the disk is already connected it should return the already connected device
    is( nbd_connect($disk), $device, "already connected disk returns same device" );

    lives_ok( sub { nbd_disconnect($device) }, "nbd_disconnect" );
    ok( !is_disk_connected($disk), "is_disk_connected returns false after disconnect" );

    throws_ok(
        sub { nbd_connect("/non/existant/file") },
        qr#File not found: /non/existant/file#,
        "nbd_connect throws on bad file"
    );
}
