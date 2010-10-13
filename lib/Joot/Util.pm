package Joot::Util;

use strict;
use warnings;

our ( @EXPORT_OK, %EXPORT_TAGS );

use base 'Exporter';
@EXPORT_OK = qw( config nbd_connect bin run slurp get_ua get_url mkpath rmpath );
%EXPORT_TAGS = ( standard => \@EXPORT_OK );

use Carp 'croak';
use File::Path ();
use IPC::Cmd   ();
use JSON       ();
use Log::Log4perl ':easy';
use LWP::UserAgent ();

# two ways to call config:
# my $cfg = $self->config();
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
                croak "couldn't find valid config file\n";
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
                croak "Config file is missing required setting \"$field\"\n";
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

# attach the qcow image to a device
sub nbd_connect {
    my $disk = shift;

    # considered creating our own /dev/jootN block devices to avoid conflicting
    # with user's /dev/nbd* usage, but don't know how to determine minor numbers
    # 43 is defined in linux kernel under include/linux/major.h as NBD_MAJOR
    # but if I use minor # 0, it conflicts with /dev/nbd0
    # i.e. this doesn't work:
    # sudo mknod /dev/joot0 b 43 0

    # TODO make device name configurable instead of assuming nbd
    my @nbd_sys_dirs = glob("/sys/block/nbd*");
    if ( !@nbd_sys_dirs ) {
        croak "Couldn't find any nbd devices in /sys/block.  Try \"sudo modprobe nbd\"\n";
    }

    my $device;
    foreach my $dir (@nbd_sys_dirs) {
        if ( !-e "$dir/pid" ) {
            if ( $dir =~ m#^/sys/block/(nbd\d+)#x ) {
                $device = $1;
                last;
            }
        }
    }

    my $sock_dir = config("sockets_dir");
    if ( !-d $sock_dir ) {
        run( bin("mkdir"), "-p", $sock_dir );
    }

    run( bin("qemu-nbd"), "--connect", "/dev/$device", "--socket", "$sock_dir/$device.sock", $disk );

    # confirm it was connected
    # if we don't get a pid in 5 seconds, die
    local $SIG{ALRM} = sub { die "failed to connect ndb device to /dev/$device\n"; };
    alarm(5);
    while (1) {
        if ( -e "/sys/block/$device/pid" ) {
            alarm(0);    # cancel alarm
            last;
        }
    }

    return "/dev/$device";
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

    croak "couldn't find $prog in " . join( ":", @paths );
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
        croak $response->status_line;
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
