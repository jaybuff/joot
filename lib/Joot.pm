package Joot;

use strict;
use warnings;

use vars '$VERSION';
$VERSION = "0.0.1";

use English '-no_match_vars';
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

# usage:
# chroot( "foo" );
# chroot( "foo", { user => "root", cmd => "adduser jaybuff" } );
sub chroot {    ## no critic qw(Subroutines::ProhibitBuiltinHomonyms)
    my $self      = shift;
    my $joot_name = shift || die "missing joot name to chroot into\n";
    my $args      = shift;

    # allow the user to specify the user to enter the chroot as
    my $user = $args->{user} || getpwuid($REAL_USER_ID);
    my $real_homedir = ( getpwnam($user) )[7];

    # mount /proc, /sys, /dev and the user's home dir
    $self->mount( $joot_name, $real_homedir, qw(/proc /sys /dev) );

    my $mnt = $self->mount_point($joot_name);
    chroot($mnt);
    my ( $uid, $gid, $homedir, $shell ) = ( getpwnam($user) )[ 2, 3, 7, 8 ];

    # check that the user exists in the chroot
    if ( !defined $uid ) {
        FATAL "User $user doesn't exist inside joot '$joot_name'";
        FATAL "Try running \"$PROGRAM_NAME $joot_name --user root --cmd 'adduser $user'\" to create the account";
        die "\n";
    }

    # chdir to user's $homedir which we mounted above
    if ( $real_homedir ne $homedir ) {
        WARN "${user}'s home dir in chroot is different than home dir outside of chroot.";
        WARN "Mounted home dir in $real_homedir, but chdir'ing to $homedir";
    }
    chdir($homedir);

    # set effective/real gid and uid to the uid/gid of the user we're
    # entering the chroot as
    # this is basically setuid/setgid
    ( $REAL_USER_ID,  $EFFECTIVE_USER_ID )  = ( $uid, $uid );
    ( $REAL_GROUP_ID, $EFFECTIVE_GROUP_ID ) = ( $gid, $gid );

    # clean up %ENV
    # set this env var so the user has a way to tell what joot they're in
    $ENV{JOOT_NAME} = $joot_name;
    foreach my $env_var (qw( SUDO_COMMAND SUDO_GID SUDO_UID SUDO_USER )) {
        delete $ENV{$env_var};
    }
    $ENV{LOGNAME} = $ENV{USERNAME} = $ENV{USER} = $user;
    $ENV{HOME} = $homedir;

    # the user may have passed in this command to run instead of their shell
    if ( my $cmd = $args->{cmd} ) {
        exec($cmd) or die "failed to exec $cmd: $!\n";
    }

    # start the user's shell inside this chroot
    if ( !-x $shell ) {
        FATAL "can't execute $shell.  use \"$PROGRAM_NAME $joot_name --cmd 'chsh /bin/sh'\" to fix";
        die "\n";
    }

    #TODO make the user's shell a login shell so .bashrc, etc are executed
    exec($shell) or die "Failed to exec shell $shell: $!\n";
}

#TODO support automount setting in config file
# three ways to call:
# $joot->mount( $name ); # mount just $joot->mount_point
# $joot->mount( $name, qw(/home/jaybuff /tmp /etc) );
# $joot->mount( $name, qw(/home/jaybuff /tmp /etc), $args );
#
# possible args:
# always    save this mount in the config file so we always mount it
# read-only mount as read only
sub mount { ## no critic qw(Subroutines::RequireArgUnpacking)
    my $self      = shift;
    my $joot_name = shift;
    my $args      = ( ref( $_[-1] ) eq "HASH" ) ? pop : {};
    my @dirs      = @_;

    if ( $args->{always} ) {

        #TODO open up config file for joot and add option
        die "--always not implemented\n";
    }

    # connect and mount the joot first
    # this is a no op if it's already connected/mounted
    my $mnt = $self->mount_point($joot_name);
    mkpath($mnt);

    my $joot_dir = $self->joot_dir($joot_name);
    my $device   = nbd_connect("$joot_dir/disk.qcow2");

    #TODO some images have partitions (mount ${device}p1 etc)
    if ( !is_mounted($mnt) ) {
        run( bin('mount'), $device, $mnt );
    }
    else {
        DEBUG "$mnt is already mounted";
    }

    foreach my $dir (@dirs) {
        my $target = "$mnt/$dir";

        if ( is_mounted($target) ) {
            DEBUG "$target is already mounted";
            next;
        }

        if ( !-e $dir ) {
            WARN "$dir doesn't exist.  Not trying to mount";
            next;
        }

        mkpath($target);
        run( bin('mount'), '--bind', $dir, $target );

        # can't bind mount readonly in one mount command
        # see http://lwn.net/Articles/281157/
        if ( $args->{'read-only'} ) {
            run( bin('mount'), '-o', 'remount,ro', $target );
        }
    }

    return;
}

# return the directory where this joot is/should be mounted
sub mount_point {
    my $self      = shift;
    my $joot_name = shift;

    my $joot_dir = $self->joot_dir($joot_name);
    return "$joot_dir/mnt";
}

# unmount specified dirs or everything if no dirs passed in
sub umount { ## no critic qw(Subroutines::RequireArgUnpacking)
    my $self      = shift;
    my $joot_name = shift;
    my $args      = ( ref( $_[-1] ) eq "HASH" ) ? pop : {};
    my @dirs      = @_;

    my $mnt = $self->mount_point($joot_name);
    if ( !@dirs ) {
        DEBUG "unmounting all mounts for this joot";
        foreach my $dir ( grep {/^$mnt/x} get_mounts() ) {
            run( bin("umount"), $dir );
        }

        # by now $mnt is unmounted, so we can disconnect the disk from nbd
        my $disk = $self->disk($joot_name);
        if ( my $device = Joot::Util::is_disk_connected($disk) ) {
            nbd_disconnect($device);
        }
        else {
            DEBUG "$disk wasn't connect to a nbd device; not trying to disconnect";
        }
        return;
    }

    # if the joot itself isn't mounted, there can't be anything mounted under it
    if ( !is_mounted($mnt) ) {
        DEBUG "joot isn't mounted, nothing to do";
        return;
    }

    foreach my $dir (@dirs) {
        if ( is_mounted("$mnt/$dir") ) {
            run( bin("umount"), "$mnt/$dir" );
        }
        else {
            DEBUG "$dir isn't mounted in $joot_name";
        }
    }

    return;
}

sub joot_dir {
    my $self      = shift;
    my $joot_name = shift || "";
    my $joot_home = config("joot_home");
    return "$joot_home/joots/$joot_name";
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

    #TODO default image (from config?  or uname?)
    if ( !$image_name ) {
        die "missing image name for create\n";
    }

    my $image = $self->get_image($image_name);

    # download and install it if it's not already installed
    if ( !$image->cached() ) {
        $image->download();
    }

    mkpath($joot_dir);
    run( bin("qemu-img"), qw(create -f qcow2 -o), "backing_file=" . $image->path(), $self->disk($joot_name) );

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

sub disk {
    my $self      = shift;
    my $joot_name = shift;

    my $joot_dir = $self->joot_dir($joot_name);
    return "$joot_dir/disk.qcow2";
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
            DEBUG $EVAL_ERROR;
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
    my $args  = ( ref( $_[-1] ) eq "HASH" ) ? pop : {};
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
