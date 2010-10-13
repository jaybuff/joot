#!/usr/bin/perl

use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
    module_name => 'Joot',
    license     => 'apache',
    requires    => {
        'perl'           => '5.6.0',
        'File::Copy'     => 0,
        'File::Path'     => '2.04',
        'LWP::UserAgent' => '5.185',
        'IPC::Cmd'       => 0,
        'JSON'           => '2.17',
        'Log::Log4perl'  => 0,
    },
    build_requires => {
        'Test::More'         => 0,
        'Test::Exception'    => 0,
        'Test::Pod'          => '1.14',
        'Test::Perl::Critic' => 0,
        'Test::Perl::Tidy'   => 0,
    },
);

$build->create_build_script;
