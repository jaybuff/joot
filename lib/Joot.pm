package Joot;

use strict;
use warnings;

use IPC::Cmd;
use LWP::Simple;
use Log::Log4perl qw(:easy);
use YAML::Tiny;

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $args  = shift || {};

	# initialize logging if it's not already
	my $level = $args->{verbose} ? $DEBUG : $INFO;
	if ( Log::Log4perl->initialized() ) {
		get_logger()->level($level);
	}
	else {
		Log::Log4perl->easy_init($level);
	}
	$IPC::Cmd::VERBOSE = $args->{verbose};

	# determine which config file we're going to read in
	if ( !$args->{config_file} || !-r $args->{config_file} ) {
		$args->{config_file} = ( -r "$ENV{HOME}/.joot" ) ? "$ENV{HOME}/.joot" : "/etc/joot.cfg";
	}

	my $self = bless $args, $class;
	$self->{joot_home} = $self->config( "joot_home", "/var/joot" );
	DEBUG("set home to $self->{joot_home}");

	#TODO this should run as sudo
	foreach my $subdir (qw( joots images )) {
		my $dir = "$self->{joot_home}/$subdir";
		if ( !-d $dir ) {
			DEBUG("mkdir 0755 $dir");
			mkdir $dir, 0755;
		}
	}

	return $self;
}

sub _bin {
	my $prog = shift;

	# use this search path.  die if $prog isn't in one of these dirs
	#TODO put these paths in config file?
	my @paths = qw(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin);
	foreach my $path (@paths) {
		if ( -x "$path/$prog" ) {
			return "$path/$prog";
		}
	}

	die "couldn't find $prog in " . join( ":", @paths );
}

sub run {
	my $self = shift;
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

# two ways to call config:
# my $cfg = $self->config();
# print "foo setting is " . $cfg->{foo};
# or
# print "foo setting is " . $self->config( "foo", "foo_default" );
# default is optional (will die if setting is missing)
sub config {
	my $self    = shift;
	my $field   = shift;
	my $default = shift;

	# read in the config file, parse it and store it in the object
	# only do this once
	if ( !$self->{config} ) {
		DEBUG( "Reading config file " . $self->{config_file} );
		$self->{config} = YAML::Tiny::LoadFile( $self->{config_file} );
	}

	# if the user requests a field, send back the value (or the default)
	# otherwise, give them the whole hash reference
	if ( defined $field ) {
		if ( exists $self->{config}->{$field} ) {
			return $self->{config}->{$field};
		}
		elsif ( defined $default ) {
			return $default;
		}
		else {
			die "Config file is missing required setting \"$field\"\n";
		}
	}

	return $self->{config};
}

sub chroot {
	my $self = shift;
	my $joot_name = shift || die "missing joot name to chroot into\n";

    my $joot_home = $self->{joot_home};

    # considered creating our own /dev/jootN block devices to avoid conflicting
    # with user's /dev/nbd* usage, but don't know how to determine minor numbers
    # 43 is defined in linux kernel under include/linux/major.h as NBD_MAJOR
    # but if I use minor # 0, it conflicts with /dev/nbd0
    # sudo mknod /dev/joot0 b 43 0

    # TODO if it is already mounted we should use the existing mount point
    # TODO make device name configurable instead of assuming nbd
    my @nbd_sys_dirs = glob("/sys/block/nbd*" );
    if ( !@nbd_sys_dirs ) { 
        die "Couldn't find any nbd devices in /sys/block.  Try \"sudo modprobe nbd\"\n";
    }

    my $device;
    foreach my $dir ( @nbd_sys_dirs ) { 
        if ( !-e "$dir/pid" ) { 
            $dir =~ m#^/sys/block/(nbd\d+)#;
            $device = $1;
            last;
        }
    }

    #TODO update config file to map device to joot 
        
    my $joot_dir = "$joot_home/joots/$joot_name/";
    $self->run( _bin("sudo"), _bin("qemu-nbd"), "--connect", "/dev/$device", "--socket", "$joot_dir/$device.sock", "$joot_dir/disk.qcow2" );

    # confirm it was connected
    # if we don't get a pid in 5 seconds, die
    $SIG{ALRM} = sub { die "failed to connect ndb device to /dev/$device\n"; };
    alarm(5);
    while (1) { 
        if ( -e "/sys/block/$device/pid" ) {
            alarm(0); # cancel alarm
            last;
        }
    }


    $self->run( _bin("sudo"), _bin("mkdir"), "-p", "$joot_dir/mnt" );

    #TODO choose a partition rather than just p1 (from an image config file?)
    $self->run( _bin("sudo"), _bin("mount"), "/dev/${device}p1", "$joot_dir/mnt" );
    chroot( "$joot_dir/mnt" );
    exec _bin("bash");

    #XXX when do we unmount this thing?

}

#TODO how to handle mapping image urls to image names?
sub install_image {
	my $self       = shift;
	my $image_url  = shift;
	my $image_name = shift;

	my $images = $self->images();
	if ( $images->{$image_name} ) {
		WARN "tried to install an image that is already installed";
		return;
	}

	# TODO fetch image
	# should I use curl (progress meter is nice) or LWP::Simple (part of perl base)
	my $joot_home = $self->{joot_home};

	# put it into "$joot_home/images/$image_name";

	# TODO
	# make the qcow disk size something bigger than 10GB
}

sub create {
	my $self       = shift;
	my $joot_name  = shift or die "missing joot name to create\n";
	my $image_name = shift;

	my $joots = $self->list();
	if ( $joots->{$joot_name} ) {
		die "$joot_name already exists.\n";
	}

	#TODO default image name (from config?  or uname?)
	die "missing image name for create" if !$image_name;

	my $images = $self->images();
	if ( !exists $images->{$image_name} ) {
		die "\"$image_name\" is an invalid image name\n";
	}

	# download and install it if it's not already installed
	if ( !$images->{$image_name} ) {

		# TODO
		$self->install_image( "XXX", "Ubuntu-10.04" );
	}

	my $image     = $images->{$image_name};
	my $joot_home = $self->{joot_home};
    my $joot_dir = "$joot_home/joots/$joot_name/";
    $self->run( _bin("sudo"), _bin("mkdir"), qw( -p 0755 ), $joot_dir );
	$self->run( _bin("sudo"), _bin("qemu-img"), qw(create -f qcow2 -o), "backing_file=$image->{file}", "$joot_dir/disk.qcow2" );

	#TODO write our a config file for this joot?
}

#XXX confirm the layout of $images hash
# {
#   "debian.5-0.x86.20100901" => {
#       file => "/var/joot/images/debian.5-0.x86.20100901.qcow",
#   }
# }
sub images {
	my $self = shift;

	#TODO
	return { "debian.5-0.x86.20100901" => { file => "$self->{joot_home}/images/debian.5-0.x86.20100901.qcow", } };
}

sub list {
	my $self = shift;

}

sub delete {
	my $self = shift;
	my $joot_name = shift || die "missing joot name to delete\n";

	die "delete not implemented";
}

sub rename {
	my $self     = shift;
	my $old_name = shift || die "rename: missing old name\n";
	my $new_name = shift || die "rename: missing new name\n";

	die "rename not implemented";

}

1;
