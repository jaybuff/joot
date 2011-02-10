#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 9;
use Test::Exception;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Joot::Util ":standard";

# get_ua tests
{
    my $ua;
    lives_ok( sub { $ua = get_ua() }, "get_ua" );
    isa_ok( $ua, "LWP::UserAgent", "ua isa LWP::UserAgent" );
    $ua->agent("foo");
    $ua = get_ua();
    isnt( $ua->agent(), "foo", "get_ua didn't save changes" );
}

# config
{
    $ENV{JOOT_CONFIG} = "$FindBin::Bin/unit.conf";
    is( config("joot_home"), "./t/joot_home", "got scalar from config" );
    is_deeply( config("image_sources"), ["file:t/data/images.js"], "got array from config" );

    # with default
    is( config( "joot_home", "default" ), "./t/joot_home", "config scalar default when set" );
    is( config( "unset",     "default" ), "default",     "config scalar default when unset" );

}

# slurp
{
    my $content;
    lives_ok( sub { $content = slurp("$FindBin::Bin/unit.conf"); }, "slurp" );
    like( $content, qr/image_sources/, "slurped file has expected content" );
}

# bin
# run
# get_url
# mkpath
# rmpath
