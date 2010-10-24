package Joot;

use strict;
use warnings;

use vars '$VERSION';
$VERSION = "0.0.1";

use File::Copy  ();
use IPC::Cmd    ();
use Joot::Image ();
use Joot::Util ':standard';
use JSON ();
use Log::Log4perl ':easy';
use LWP::UserAgent ();

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;

    if ( get_logger()->level() == $DEBUG ) {
        $IPC::Cmd::VERBOSE = 1;
    }

    my $self = bless {}, $class;
    my $joot_home = config("joot_home");
    DEBUG("set home to $joot_home");

    foreach my $subdir (qw( joots images )) {
        my $dir = "$joot_home/$subdir";
        if ( !-d $dir ) {
            mkpath($dir);
        }
    }

    return $self;
}

sub chroot {    ## no critic qw(Subroutines::ProhibitBuiltinHomonyms)
    my $self = shift;
    my $joot_name = shift || die "missing joot name to chroot into\n";

    my $joot_dir = $self->joot_dir($joot_name);

    #TODO check to see if it's already connected
    my $device = nbd_connect("$joot_dir/disk.qcow2");

    my $mnt = "$joot_dir/mnt";
    mkpath($mnt);

    #TODO some images have partitions (mount ${device}p1 etc)
    run( bin("mount"), $device, $mnt );

    # start the user's shell inside this chroot
    my $shell = (getpwent)[8];
    system( bin("chroot"), $mnt, $shell );

    # when the user exits the joot unmount and disconnect it
    run( bin("umount"), $mnt );
    nbd_disconnect($device);

    return;
}

sub joot_dir {
    my $self      = shift;
    my $joot_name = shift || "";
    my $joot_home = config("joot_home");
    return "$joot_home/joots/$joot_name/";
}

sub get_image {
    my $self       = shift;
    my $image_name = shift;

    my $images = $self->images();
    if ( !exists $images->{$image_name} ) {
        die "\"$image_name\" is an invalid image name\n";
    }
    return $images->{$image_name};
}

sub create {
    my $self       = shift;
    my $joot_name  = shift or die "missing joot name to create\n";
    my $image_name = shift;

    my $joot_dir = $self->joot_dir($joot_name);
    if ( -e $joot_dir ) {
        die "$joot_name already exists.\n";
    }
    mkpath($joot_dir);

    #TODO default image (from config?  or uname?)
    if ( !$image_name ) {
        die "missing image name for create\n";
    }

    my $image = $self->get_image($image_name);

    # download and install it if it's not already installed
    if ( !$image->cached() ) {
        $image->download();
    }

    run( bin("qemu-img"), qw(create -f qcow2 -o), "backing_file=" . $image->path(), "$joot_dir/disk.qcow2" );

    my $conf = {
        image   => $image->url(),
        creator => $ENV{SUDO_USER} || $ENV{USER},
        ctime   => time(),
    };

    my $conf_file = "$joot_dir/config.js";
    open my $conf_fh, '>', $conf_file or die "Failed to write to $conf_file: $!\n";
    print $conf_fh JSON::to_json($conf);
    close $conf_fh;

    return 1;
}

sub images {
    my $self = shift;

    my $images;
    my $image_sources = config("image_sources");
    foreach my $url ( @{$image_sources} ) {
        eval {
            my $content = get_url("$url");
            my $index   = JSON::from_json($content);
            if ( ref($index) ne "ARRAY" ) {
                die "expected JSON array from $url\n";
            }
            foreach my $image_url ( @{$index} ) {
                my $image = Joot::Image->new($image_url);
                my $name  = $image->name();
                if ( exists $images->{$name} ) {
                    my $other_url = $images->{$name}->url();
                    WARN "collision!  $image_url and $other_url have the same name.  Ignoring $image_url";
                    next;
                }

                $images->{$name} = $image;
            }
            1;
        } or do {
            WARN "Failed getting images from $url";
            DEBUG $@;
          }
    }

    return $images;
}

sub list {
    my $self = shift;

    my $joots    = {};
    my $joot_dir = $self->joot_dir();
    opendir( my $dh, $joot_dir ) or die "can't read directory $joot_dir: $!\n";
    while ( my $joot = readdir($dh) ) {
        my $conf = "$joot_dir/$joot/config.js";
        if ( !-e $conf ) {
            next;
        }

        $joots->{$joot} = JSON::from_json( slurp($conf) );
    }

    return $joots;
}

sub delete {    ## no critic qw(Subroutines::ProhibitBuiltinHomonyms Subroutines::RequireArgUnpacking)
    my $self  = shift;
    my @joots = @_;
    if ( !@joots ) {
        die "missing joot name to delete\n";
    }

    foreach my $joot_name (@joots) {
        my $joot_dir = $self->joot_dir($joot_name);
        if ( !-d $joot_dir ) {
            WARN "$joot_name doesn't exist";
            next;
        }

        rmpath($joot_dir);
    }
    return;
}

sub rename {    ## no critic qw(Subroutines::ProhibitBuiltinHomonyms)
    my $self     = shift;
    my $old_name = shift || die "rename: missing old name\n";
    my $new_name = shift || die "rename: missing new name\n";

    my $old = $self->joot_dir($old_name);
    my $new = $self->joot_dir($new_name);

    if ( -d $new ) {
        FATAL "Can't rename $new to $old because joot named $old already exists";
        return;
    }

    if ( !-d $old ) {
        FATAL "$old doesn't exist";
        return;
    }

    File::Copy::move( $old, $new );
    return;
}

# TODO
# make the qcow disk size something bigger than 10GB when it's installed

1;

__END__

=head1 NAME

Joot - Utility to manage disk images and chroots to provide you with quick clean room environments

=head1 SYNOPSIS

c<< my $joot = joot->new(); >>

=head1 DESCRIPTION

Joot is a utility that manages disk images and chroots to provide you with 
quick clean room environments for development, testing and package management.

=head1 METHODS

=head2 c<new()>

Constructor.  Takes no args.

=head2 c<chroot( $joot_name )>

=head2 c<joot_dir()>

=head2 c<get_image( $image_name )>

=head2 c<create( $name, $image )>

=head2 c<images()>

=head2 c<list()>

=head2 c<delete( $joot_name )>

=head2 c<rename( $old_name, $new_name )>

=head1 DEPENDENCIES

This application depends on these binaries:

    qemu-nbd
    qemu-img 

=head1 CONFIGURATION AND ENVIRONMENT

Joot will look for a config options in JOOT_CONFIG env var, ~/.joot or
/etc/joot.cfg in that order.

=head1 AUTHOR

Jay Buffington   (jaybuffington@gmail.com)

=head1 COPYRIGHT

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this software except in compliance with the License.
You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
