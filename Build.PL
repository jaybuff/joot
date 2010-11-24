#!/usr/bin/perl

use strict;
use warnings;

use Module::Build;

my $class = Module::Build->subclass( code => <<'ENDSUB' );
    sub ACTION_deb {
        my $self = shift;
        $self->do_system("yada rebuild");
        $self->do_system("debuild");
    }

    sub ACTION_debclean {
        my $self = shift;
        $self->do_system("debuild clean");
        $self->do_system("rm debian/rules debian/control");
    }
ENDSUB

my $build = $class->new(
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
    conf_files   => { 'joot.cfg' => 'conf/joot.cfg' },
    install_path => { 'conf'     => '/etc' }
);

$build->add_build_element('conf');
$build->create_build_script;
