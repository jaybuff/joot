package Joot::Plugin::QCOW;

use strict;
use warnings;

our ( @EXPORT_OK );

use base 'Exporter';
@EXPORT_OK = qw( nbd_connect nbd_disconnect is_disk_connected );

use Cwd;
use English '-no_match_vars';
use Joot ();
use Joot::Image ();
use Joot::Util qw(is_mounted run bin mkpath config slurp);
use Log::Log4perl ':easy';

sub mount {
    my $joot = shift;
    my $args = shift;
    my @dirs = @_;

    # connect and mount the joot first
    # this is a no op if it's already connected/mounted
    my $mnt = $joot->mount_point();
    mkpath($mnt);

    my $device = nbd_connect( disk( $joot ) );
    my $conf   = $joot->get_config();

    # partition is always > 0 if it exists
    if ( exists( $conf->{image} ) && $conf->{image}->{root_partition} ) {
        my $part = $conf->{image}->{root_partition};
        $device = "${device}p$part";

        # when the device is first connected, it takes a bit for the /dev
        # device to be created.  we'll give it 5 seconds before giving up
        my $joot_name = $joot->name();
        local $SIG{ALRM} = sub { die "config for $joot_name says root_partition is $part, but $device doesn't exist\n"; };
        alarm(5);
        while (1) {
            if ( -e $device ) {
                alarm(0);    # cancel alarm
                last;
            }
        }
    }

    #TODO some images have partitions (mount ${device}p1 etc)
    if ( !is_mounted($mnt) ) {
        run( bin('mount'), $device, $mnt );
    }
    else {
        DEBUG "$mnt is already mounted";
    }

    return;
}

# unmount specified dirs or everything if no dirs passed in
sub post_umount {  
    my $joot = shift;
    my $args = shift;
    my @dirs = @_;

    my $mnt = Cwd::abs_path( $joot->mount_point() );
    if ( !@dirs ) {
        # by now $mnt should be unmounted, so we can disconnect the disk from nbd
        my $disk = disk( $joot );
        if ( my $device = is_disk_connected($disk) ) {
            nbd_disconnect($device);
        }
        else {
            DEBUG "$disk wasn't connect to a nbd device; not trying to disconnect";
        }
        return;
    }

    return;
}

sub create {
    my $joot  = shift;
    my $image = shift;

    run( bin("qemu-img"), qw(create -f qcow2 -o), "backing_file=" . $image->path(), disk( $joot ) );

    return;
}

sub disk {
    my $joot = shift;

    my $joot_dir = $joot->joot_dir();
    return "$joot_dir/disk.qcow2";
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
            my $last_arg = ( split /\s+/x, $out )[-1] or next;
            if ( !-e $last_arg ) {
                WARN "qemu-nbd is connected to $last_arg which doesn't exist";
                next;
            }
            my $maybe_disk = Cwd::abs_path($last_arg);
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
# note that this doesn't create a lock on this device, beware race conditions
sub get_nbd_device {

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

    if ( !$device ) {
        FATAL "Unable to allocate nbd device.  Maybe they're all in use?  Try \"sudo modprobe nbd nbds_max=256\"";
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
        mkpath($sock_dir);
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

1;

__END__

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
