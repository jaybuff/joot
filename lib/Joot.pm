package Joot;

use strict;
use warnings;

use vars '$VERSION';
$VERSION = "0.0.1";

use Cwd ();
use English '-no_match_vars';
use File::Copy  ();
use File::Spec  ();
use Joot::Image ();
use Joot::Util ':standard';
use JSON ();
use Log::Log4perl ':easy';
use LWP::UserAgent ();

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $name  = shift;

    my $self = bless { name => $name, }, $class;
    my $joot_home = config("joot_home");
    DEBUG("set home to $joot_home");

    foreach my $subdir (qw( joots images )) {
        my $dir = "$joot_home/$subdir";
        if ( !-d $dir ) {
            mkpath($dir);
        }
    }

    $self->load_plugins();

    return $self;
}

# usage:
# chroot( "foo" );
# chroot( "foo", { user => "root", cmd => "adduser jaybuff" } );
# possible args:
# user      user to enter the chroot as
# cmd       run this command instead of the user's shell
# no-home   don't mount the user's home directory inside the chroot
# ro-home   mount the user's home dir as read-only
sub chroot {    ## no critic qw(Subroutines::ProhibitBuiltinHomonyms Subroutines::RequireArgUnpacking)
    my $self = shift;
    my $args = ( ref( $_[-1] ) eq "HASH" ) ? pop : {};

    my $joot_name = $self->name();
    if ( !$self->exists() ) {
        die "Joot \"$joot_name\" does not exist\n";
    }

    # allow the user to specify the user to enter the chroot as
    my $user = $args->{user} || ( $REAL_USER_ID ? getpwuid($REAL_USER_ID) : $ENV{SUDO_USER} );

    # if the user doesn't exist in the real root that's okay
    my $real_homedir = ( getpwnam($user) )[7] || "";

    if ( !$args->{'no-home'} ) {
        my $mount_args = $args->{'ro-home'} ? { 'read-only' => 1 } : {};
        $self->mount( $real_homedir, $mount_args );
    }
    else {

        # if it happens to already be mounted, unmount it
        # TODO what if someone is using it in another instance?
        $self->umount($real_homedir);
    }

    $self->automount();
    my $mnt = Cwd::abs_path( $self->mount_point() );

    # special handling of ssh socket
    my ( @kill_pids, @to_chown );
    if ( $ENV{SSH_AUTH_SOCK} && -S $ENV{SSH_AUTH_SOCK} ) {

        # we don't know the uid for $user until we chroot, so defer this chown
        eval {
            push @kill_pids, proxy_socket( $ENV{SSH_AUTH_SOCK}, "$mnt/$ENV{SSH_AUTH_SOCK}" );
            push @to_chown, $ENV{SSH_AUTH_SOCK};    # relative to the chroot
            1;
        } or do {
            WARN "Failed to proxy ssh auth socket: $@";
        };
    }

    # we'll run this after the command (or shell) exits
    my $clean_up;
    if (@kill_pids) {
        $clean_up = sub {
            return if ( !@kill_pids );
            my $pid_list = join " ", @kill_pids;
            DEBUG "kill TERM $pid_list";
            kill( "TERM", @kill_pids ) or die "Failed to kill TERM $pid_list: $OS_ERROR\n";
            @kill_pids = ();    # don't kill them twice
        };

        # if we die we need to clean up
        $SIG{__DIE__} = $clean_up;
    }

    chroot($mnt) or die "Failed to chroot $mnt: $OS_ERROR\n";

    my ( $uid, $gid, $homedir, $shell ) = ( getpwnam($user) )[ 2, 3, 7, 8 ] or do {
        DEBUG "getpwnam( $user ) failed: $OS_ERROR";
        FATAL "User $user doesn't exist inside joot '$joot_name'";
        FATAL "Try running \"$PROGRAM_NAME $joot_name --user root --cmd 'adduser $user'\" to create the account";
        die "\n";
    };

    if (@to_chown) {
        chown( $uid, $gid, @to_chown ) or die "Failed to chown " . join( ", ", @to_chown ) . ": $OS_ERROR\n";
    }

    # chdir to user's $homedir which we (may have) mounted above
    if ( !$args->{'no-home'} && $real_homedir && $real_homedir ne $homedir ) {
        WARN "${user}'s home dir in chroot is different than home dir outside of chroot.";
        WARN "Mounted home dir in $real_homedir, but chdir'ing to $homedir";
    }
    chdir($homedir) or do {
        WARN "Failed to chdir $homedir: $OS_ERROR\n";
        FATAL "home directory '$homedir' doesn't exist inside joot '$joot_name'";
        FATAL "Try running \"$PROGRAM_NAME $joot_name --user root --cmd 'mkdir -p $homedir'\" to create it";
        die "\n";
    };

    # clean up %ENV
    # set this env var so the user has a way to tell what joot they're in
    $ENV{JOOT_NAME} = $joot_name;
    foreach my $env_var (qw( SUDO_COMMAND SUDO_GID SUDO_UID SUDO_USER )) {
        delete $ENV{$env_var};
    }
    $ENV{LOGNAME} = $ENV{USERNAME} = $ENV{USER} = $user;
    $ENV{HOME} = $homedir;

    my $exec_cmd = sub {
        if ( $user ne "root" ) { 
            drop_root($user);
        }

        # the user may have passed in this command to run instead of their shell
        if ( my $cmd = $args->{cmd} ) {
            exec($cmd) or die "failed to exec $cmd: $!\n";
        }

        # start the user's shell inside this chroot
        if ( !-x $shell ) {
            FATAL "can't execute $shell.  use \"$PROGRAM_NAME $joot_name --cmd 'chsh /bin/sh'\" to fix";
            die "\n";
        }

        my $shell_name = ( File::Spec->splitpath($shell) )[2];
        DEBUG("exec $shell as login shell");

        # see perldoc -f exec for explanation of this rarely used syntax
        exec $shell "-$shell_name" or die "Failed to exec shell $shell: $!\n";
    };

    # we fork here so we can clean up when the shell is done
    # if there is no clean up work, we just exec
    if ($clean_up) {
        my $pid = fork();
        if ( !defined $pid ) {
            die "Failed to fork: $!\n";
        }
        elsif ( $pid == 0 ) {
            &{$exec_cmd}();
        }

        waitpid( $pid, 0 );
        &{$clean_up}();

        return;
    }

    &{$exec_cmd}();
    return;
}

sub get_config {
    my $self = shift;

    my $joot_dir  = $self->joot_dir();
    my $conf_file = "$joot_dir/config.js";
    return JSON::from_json( slurp($conf_file) );
}

sub set_config {
    my $self = shift;
    my $conf = shift;

    my $joot_dir  = $self->joot_dir();
    my $conf_file = "$joot_dir/config.js";
    open my $conf_fh, '>', $conf_file or die "Failed to write to $conf_file: $!\n";
    my $config = JSON::to_json( $conf, { pretty => 1 } );
    print $conf_fh $config;
    close $conf_fh;

    return;
}

# three ways to call:
# $joot->mount( ); # mount $joot->mount_point and automounts
# $joot->mount( qw(/home/jaybuff /tmp /etc) );
# $joot->mount( qw(/home/jaybuff /tmp /etc), $args );
#
# possible args:
# always        save this mount in the config file so we always mount it
# read-only     mount as read only
# no-automount  don't call automount
sub mount {    ## no critic qw(Subroutines::RequireArgUnpacking)
    my $self = shift;
    my $args = ( ref( $_[-1] ) eq "HASH" ) ? pop : {};
    my @dirs = @_;

    my $joot_name = $self->name();
    if ( !$self->exists() ) {
        die "Joot \"$joot_name\" does not exist\n";
    }

    $self->run_hook( "mount", $args, @dirs );

    my $conf = $self->get_config();
    if ( $args->{always} ) {
        delete $args->{always};
        foreach my $dir (@dirs) {
            $conf->{automount}->{$dir} = $args;
        }
        $self->set_config($conf);
    }

    return;
}

sub automount {
    my $self = shift;

    my $conf = $self->get_config();

    # we need to sanitize the directories so we can properly sort them
    # if /foo and /foo/bar are both in auto mounts, we have to mount
    # /foo before we can mount /foo/bar, thus the need to sort.
    my $auto;
    foreach my $dir ( keys %{ $conf->{automount} } ) {
        my $absdir = Cwd::abs_path($dir);
        if ( !$absdir ) {
            WARN "$dir doesn't exist, not mounting";
            next;
        }
        $auto->{$absdir} = $conf->{automount}->{$dir};
    }

    foreach my $dir ( sort keys %{$auto} ) {
        $self->mount( $dir, $auto->{$dir} );
    }

    return;
}

# return the directory where this joot is/should be mounted
sub mount_point {
    my $self = shift;

    my $joot_dir = $self->joot_dir();
    return "$joot_dir/mnt";
}

# unmount specified dirs or everything if no dirs passed in
sub umount {    ## no critic qw(Subroutines::RequireArgUnpacking)
    my $self = shift;
    my $args = ( ref( $_[-1] ) eq "HASH" ) ? pop : {};
    my @dirs = @_;

    if ( !$self->exists() ) {
        die "Joot \"" . $self->name() . "\" does not exist\n";
    }

    if ( $self->run_hook( "umount", $args, @dirs ) == 0 ) {
        die "There are no plugins registered that implement the umount hook\n";
    }

    $self->run_hook( "post_umount", $args, @dirs );

    return;
}

sub joot_dir {
    my $self = shift;
    my $joot_name = $self->name() || die "joot name is not set\n";
    return $self->joots_dir() . $joot_name;
}

sub joots_dir {
    my $joot_home = config("joot_home");
    return "$joot_home/joots/";
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
    my $image_name = shift;

    my $joot_dir = $self->joot_dir();
    if ( -e $joot_dir ) {
        die $self->name() . " already exists.\n";
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
    $self->run_hook( "pre_create", $image );

    if ( $self->run_hook( "create", $image ) == 0 ) {
        die "There are no plugins registered that implement the create hook\n";
    }

    my $conf = {
        image     => $image->config(),
        creator   => $ENV{SUDO_USER} || $ENV{USER},
        ctime     => time(),
    };

    # not all systems use /dev/pts, so only add it if this system does
    foreach my $autodir ( qw( /proc /sys /dev /dev/pts ) ) { 
        if ( -e $autodir ) {
            $conf->{automount}->{$autodir} = {};
        }
    }

    $self->set_config($conf);

    $self->mount( { 'no-automount' => 1 } );
    my $mnt = $self->mount_point();
    my $files = config( "copy_from_root", [] );
    if ( ref($files) ne "ARRAY" ) {
        die "setting copy_from_root in config must be an array\n";
    }
    foreach my $file ( @{$files} ) {
        if ( !-e $file ) {
            WARN "$file doesn't exist.  not copying into joot";
            next;
        }
        File::Copy::copy( $file, "$mnt/$file" );
    }

    $self->run_hook("post_create");

    return 1;
}

#TODO also list images that are downloaded, but not referenced in any index
sub images {
    my $self = shift;

    my $images;
    my $image_sources = config("image_sources");
    foreach my $url ( @{$image_sources} ) {
        eval {

            # content looks like this:
            # {
            #    "http://getjoot.org/images/debian.5-0.x86.20100901.qcow.bz2": {
            #        "root_partition": 1,
            #    }
            # }
            my $content = get_url("$url");
            my $index   = JSON::from_json($content);
            if ( ref($index) ne "HASH" ) {
                die "expected JSON hash from $url\n";
            }
            foreach my $image_url ( keys %{$index} ) {
                my $image = Joot::Image->new( $image_url, $index->{$image_url} );
                my $name = $image->name();
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
            WARN $EVAL_ERROR;
          }
    }

    return $images;
}

sub list {
    my $self = shift;

    my $joots     = {};
    my $joots_dir = $self->joots_dir();
    opendir( my $dh, $joots_dir ) or die "can't read directory $joots_dir: $!\n";
    while ( my $joot_name = readdir($dh) ) {
        next if ( $joot_name =~ /^\.\.?$/x );    # skip . and .. dirs
        my $joot = Joot->new($joot_name);
        if ( !$joot->exists() ) {
            WARN "$joots_dir/$joot_name exists, but $joot_name doesn't exist";
            next;
        }

        $joots->{$joot_name} = $joot->get_config();
    }

    return $joots;
}

sub delete {    ## no critic qw(Subroutines::ProhibitBuiltinHomonyms Subroutines::RequireArgUnpacking)
    my $self = shift;

    # umount may fail if it doesn't exist, but we want to be sure to delete it
    # in case it got corrupted
    eval { $self->umount(); };

    my $mnt = $self->mount_point();
    if ( scalar glob("$mnt/*") ) {
        die "$mnt is not empty.  Perhaps joot couldn't be unmounted?\n";
    }

    my $joot_dir = $self->joot_dir();
    if ( !-d $joot_dir ) {
        WARN $self->name() . " doesn't exist";
        return;
    }

    rmpath($joot_dir);
    return;
}

sub rename {    ## no critic qw(Subroutines::ProhibitBuiltinHomonyms)
    my $self = shift;
    my $new_name = shift || die "rename: missing new name\n";

    if ( !$self->exists() ) {
        die "Joot \"" . $self->name() . "\" does not exist\n";
    }

    $self->umount();

    my $old = $self->joot_dir();
    my $new = Joot->new($new_name)->joot_dir();

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

sub name {
    my $self = shift;
    return $self->{name} || "";
}

sub exists {
    my $self = shift;

    return eval { $self->get_config() };
}

sub load_plugins {
    my $self = shift;
    foreach my $plugin ( @{ config("plugins") } ) {
        if ( !eval "use Joot::Plugin::$plugin; 1;" ) {
            die "Failed to load plugin $plugin: $@\n";
        }
    }

    return;
}

# returns number of hooks run;
sub run_hook {
    my $self = shift;
    my $hook = shift or die "missing hook name\n";
    my @args = @_;

    my $count = 0;
    foreach my $plugin ( @{ config("plugins") } ) {
        my $class = "Joot::Plugin::$plugin";
        if ( $class->can($hook) ) {
            my $function = "${class}::$hook";
            DEBUG "Dispatching to $function";
            {
                no strict 'refs';
                $function->( $self, @args );
                $count++;
            }
        }
    }

    return $count;
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
    socat
    sudo
    env 
    mount
    umount
    ps
    bunzip2
    gunzip

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
