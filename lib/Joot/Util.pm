package Joot::Util;

use strict;
use warnings;

our ( @EXPORT_OK, %EXPORT_TAGS );

use base 'Exporter';
my @standard = qw( config nbd_connect nbd_disconnect bin run slurp get_ua get_url mkpath rmpath mount );
@EXPORT_OK = ( @standard, qw( is_disk_connected get_nbd_device ) );
%EXPORT_TAGS = ( standard => \@standard );

use Cwd          ();
use File::Path   ();
use IPC::Cmd     ();
use JSON         ();
use Log::Log4perl ':easy';
use LWP::UserAgent ();

# two ways to call config:
# my $cfg = config();
# print "foo setting is " . $cfg->{foo};
# or
# print "foo setting is " . config( "foo", "foo_default" );
# default is optional (will die if setting is missing)
{
    my $config;    # singleton

    sub config {
        my $field   = shift;
        my $default = shift;

        # read in the config file, parse it and store it in the object
        # only do this once
        if ( !$config ) {

            # determine which config file we're going to read in
            my $config_file;
            foreach my $file ( $ENV{JOOT_CONFIG}, "$ENV{HOME}/.joot", "/etc/joot.cfg" ) {
                if ( $file && -r $file ) {
                    $config_file = $file;
                    last;
                }
            }
            if ( !$config_file ) {
                die "couldn't find valid config file\n";
            }
            DEBUG( "Reading config file " . $config_file );
            $config = JSON::from_json( slurp($config_file), { relaxed => 1 } );
        }

        # if the user requests a field, send back the value (or the default)
        # otherwise, give them the whole hash reference
        if ( defined $field ) {
            if ( exists $config->{$field} ) {
                return $config->{$field};
            }
            elsif ( defined $default ) {
                return $default;
            }
            else {
                die "Config file is missing required setting \"$field\"\n";
            }
        }

        return $config;
    }
}

sub get_ua {
    my $ua = LWP::UserAgent->new();
    $ua->timeout(3);
    $ua->env_proxy();    # respect HTTP_PROXY env vars

    return $ua;
}

# if target is already mounted, do nothing
# otherwise, mount it using the mount flags the user sent in (if any)
# note that flags should be an array, not a string
sub mount { 
    my $src = shift;
    my $target = shift;
    my $mount_args = \@_;
    
    # normalize input
    $target = Cwd::abs_path( $target );

    # lines from /proc/mount look like this:
    # /dev/sdh1 /home/jaybuff/joot/joots/foo/mnt/home/jaybuff ext3 rw,relatime,errors=continue,data=writeback 0 0
    my $mounts = slurp( "/proc/mounts" );
    foreach my $line (split "\n", $mounts) { 
        my ($mtarget) = (split /\s+/x, $line, 3)[1];
        $mtarget = Cwd::abs_path( $mtarget );

        if ( $target eq $mtarget ) { 
            DEBUG "$target is already mounted";
            return;
        }
    }

    run( bin('mount'), @{ $mount_args }, $src, $target );
    return;
}

sub nbd_disconnect {
    my $device = shift;
    run( bin("qemu-nbd"), "--disconnect", $device );
    return;
}

# check all the pids in /sys/block/nbd*/pid to see if disk is already connected
# if it's connected return the device otherwise return false
sub is_disk_connected {
    my $disk = shift;

    foreach my $dir ( glob("/sys/block/nbd*") ) {
        if ( -e "$dir/pid" ) {
            my $pid = slurp("$dir/pid");
            chomp $pid;

            # $out should look like this:
            # /usr/bin/qemu-nbd --connect /dev/nbd0 --socket /var/run/joot/nbd0.sock /home/jaybuff/joot/joots/foo//disk.qcow2
            my $out = run( bin('ps'), '--pid', $pid, qw(-o args --no-headers) );
            my $last_arg = (split /\s+/x, $out)[-1] or next;
            my $maybe_disk = Cwd::abs_path( $last_arg );
            if ( $maybe_disk eq Cwd::abs_path($disk) ) {
                if ( $dir =~ m#^/sys/block/(nbd\d+)#x ) {
                    my $device = $1;
                    return "/dev/$device";
                }
            }
        }
    }

    return;
}

# get the next unused nbd device
# note that this doesn't create a lock on this device, beward race conditions
sub get_nbd_device {

    # considered creating our own /dev/jootN block devices to avoid conflicting
    # with user's /dev/nbd* usage, but don't know how to determine minor numbers
    # 43 is defined in linux kernel under include/linux/major.h as NBD_MAJOR
    # but if I use minor # 0, it conflicts with /dev/nbd0
    # i.e. this doesn't work:
    # sudo mknod /dev/joot0 b 43 0

    # TODO make device name configurable instead of assuming nbd
    my @nbd_sys_dirs = glob("/sys/block/nbd*");
    if ( !@nbd_sys_dirs ) {
        die "Couldn't find any nbd devices in /sys/block.  Try \"sudo modprobe nbd\"\n";
    }

    # custom sort because /sys/block/nbd9 should come before /sys/block/nbd10
    my $nbd_sort = sub {
        my ($l) = $a =~ /(\d+)/x or return $a cmp $b;
        my ($r) = $b =~ /(\d+)/x or return $a cmp $b;
        $l <=> $r;
    };

    my $device;
    foreach my $dir ( sort $nbd_sort @nbd_sys_dirs ) {
        if ( !-e "$dir/pid" ) {
            if ( $dir =~ m#^/sys/block/(nbd\d+)#x ) {
                $device = $1;
                last;
            }
        }
    }

    # TODO try to mknod more devices?
    if ( !$device ) {
        FATAL "Unable to allocate nbd device.  Maybe they're all in use?";
        die "\n";
    }

    return "/dev/$device";
}

# attach the qcow image to a device
# return the path to the attached device
sub nbd_connect {
    my $disk = shift;
    if ( !-e $disk ) {
        die "File not found: $disk\n";
    }

    $disk = Cwd::abs_path($disk);

    if ( my $device = is_disk_connected($disk) ) {
        DEBUG "$disk is already attached to $device";
        return $device;
    }

    my $sock_dir = config("sockets_dir");
    $sock_dir =~ s#/*$##x;    # remove trailing slashes
    if ( !-d $sock_dir ) {
        run( bin("mkdir"), "-p", $sock_dir );
    }


    my $device = get_nbd_device();
    my ($device_name) = ( $device =~ m#/dev/(.+)#x );
    run( bin("qemu-nbd"), "--connect", $device, "--socket", "$sock_dir/$device_name.sock", $disk );

    # confirm it was connected
    # if we don't get a pid in 5 seconds, die
    local $SIG{ALRM} = sub { die "failed to connect ndb device to $device\n"; };
    alarm(5);
    while (1) {
        if ( -e "/sys/block/$device_name/pid" ) {
            alarm(0);    # cancel alarm
            last;
        }
    }

    return $device;
}

sub bin {
    my $prog = shift;

    # use this search path.  die if $prog isn't in one of these dirs
    my @paths = qw(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin);
    foreach my $path (@paths) {
        if ( -x "$path/$prog" ) {
            return "$path/$prog";
        }
    }

    die "couldn't find $prog in " . join( ":", @paths ) . "\n";
}

sub run {
    my @args = @_;

    my $cmd = join( " ", @args );
    my ( $success, $err, $full_buf, $stdout_buf, $stderr_buf ) = IPC::Cmd::run( command => \@args );

    if ( !$success ) {
        FATAL "Error executing $cmd";
        if ($full_buf) {
            FATAL join( "", @{$full_buf} );
        }
        die "$err\n";
    }

    return join( "", @{$stdout_buf} );
}

sub slurp {
    my $file = shift;
    return do {
        local $/ = undef;
        open my $fh, '<', $file or die "can't read contents of $file: $!\n";
        my $content = <$fh>;
        close $fh;
        $content;
    };
}

sub get_url {
    my $url = shift;

    my $ua = get_ua();

    DEBUG("fetching $url");
    my $response = $ua->get($url);

    if ( !$response->is_success ) {
        die $response->status_line() . "\n";
    }

    return $response->decoded_content();
}

sub mkpath {
    my $dir = shift;

    File::Path::make_path( $dir, { verbose => get_logger()->level() == $DEBUG } );
    return;
}

sub rmpath {
    my $dir = shift;

    File::Path::remove_tree( $dir, { verbose => get_logger()->level() == $DEBUG } );
    return;
}

1;
