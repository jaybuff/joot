#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use FindBin;
use lib "$FindBin::Bin/../lib";

#use Log::Log4perl qw(:easy);
#Log::Log4perl->easy_init($DEBUG);

use Joot;
use Joot::Util 'rmpath';

if ( $< != 0 ) {
    plan skip_all => 'Must run these tests as root';
}
else {
    plan tests => 7;
}

# clean up from failed previous runs and after this one
my $home = Cwd::abs_path("$FindBin::Bin/joot_home/");
rmpath($home);
END { rmpath($home); }

$ENV{JOOT_CONFIG} = "$FindBin::Bin/unit.conf";
my $joot = Joot->new( "foo" );

throws_ok( sub { $joot->create( "bogus_image" ); }, qr/"bogus_image" is an invalid image name/ );
throws_ok( sub { $joot->create(); }, qr/missing image name for create/ );

lives_ok( sub { $joot->create( "test_image" ); }, "create joot" );
throws_ok( sub { $joot->create( "test_image" ); }, qr/foo already exists./ );
ok( -d $joot->joot_dir(), "joot dir was created" );
ok( -f $joot->disk(),     "disk was created" );
lives_ok( sub { $joot->delete(); }, "delete joot" );
