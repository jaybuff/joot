#!/usr/bin/perl

use strict;
use warnings;

use Test::Exception;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
if ( $< != 0 ) {
    plan skip_all => 'Must run these tests as root';
}
else {
    plan tests => 6;
}

#use Log::Log4perl qw(:easy);
#Log::Log4perl->easy_init($DEBUG);

use Joot;
use Joot::Util;

# clean up from failed previous runs and after this one
my $home = "$FindBin::Bin/joot_home/";
Joot::Util::rmpath($home);
END { Joot::Util::rmpath($home); }
    

$ENV{JOOT_CONFIG} = "$FindBin::Bin/unit.conf";
my $joot = Joot->new();

throws_ok( sub { $joot->create( "foo", "bogus_image" ); }, qr/"bogus_image" is an invalid image name/ );
throws_ok( sub { $joot->create("foo"); }, qr/missing image name for create/ );

lives_ok( sub { $joot->create( "foo", "test_image" ); }, "create joot" );
throws_ok( sub { $joot->create( "foo", "test_image" ); }, qr/foo already exists./ );
ok( -d $joot->joot_dir("foo"), "joot dir was created" );
ok( -f $joot->disk("foo"),     "disk was created" );
