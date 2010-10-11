package Joot;

use strict;
use warnings;

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
			run( bin("mkdir"), "-p", "$dir" );
		}
	}

	return $self;
}

sub chroot {
	my $self = shift;
	my $joot_name = shift || die "missing joot name to chroot into\n";

	my $joot_dir = $self->joot_dir($joot_name);

	#TODO check to see if it's already connected?
	my $device = nbd_connect("$joot_dir/disk.qcow2");

	run( bin("mkdir"), "-p", "$joot_dir/mnt" );

	#TODO choose a partition rather than just p1 (from an image config file?)
	run( bin("mount"), "/dev/${device}p1", "$joot_dir/mnt" );
	chroot("$joot_dir/mnt");

	#TODO use the user's shell $ENV{SHELL} or look in /etc/passwd?
	exec bin("bash");

	#XXX when do we unmount/disconnect this thing?

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

	my $joots = $self->list();
	if ( $joots->{$joot_name} ) {
		die "$joot_name already exists.\n";
	}

	#TODO default image (from config?  or uname?)
	if ( !$image_name ) {
		die "missing image name for create";
	}

	my $image = $self->get_image($image_name);

	# download and install it if it's not already installed
	if ( !$image->cached() ) {
		$image->download();
	}

	my $joot_dir = $self->joot_dir($joot_name);
	run( bin("mkdir"), '-p', $joot_dir );
	run( bin("qemu-img"), qw(create -f qcow2 -o), "backing_file=" . $image->path(), "$joot_dir/disk.qcow2" );

	my $conf = {
		image   => $image->url(),
		creator => $ENV{SUDO_USER} || $ENV{USER},
		ctime   => time(),
	};

	my $conf_file = "$joot_dir/$joot_name.conf";
	open my $conf_fh, '>', $conf_file or die "Failed to write to $conf_file: $!\n";
	print $conf_fh JSON::to_json($conf);
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

				$images->{ $image->name() } = $image;
			}
		};
		if ($@) {
			WARN "Failed getting images from $url";
			DEBUG $@;
		}
	}

	return $images;
}

sub list {
	my $self = shift;

	# TODO implement
	return {};
}

sub delete {
	my $self = shift;
	my $joot_name = shift || die "missing joot name to delete\n";

	# TODO implement
	die "delete not implemented";
}

sub rename {
	my $self     = shift;
	my $old_name = shift || die "rename: missing old name\n";
	my $new_name = shift || die "rename: missing new name\n";

	# TODO implement
	die "rename not implemented";

}

# TODO
# make the qcow disk size something bigger than 10GB when it's installed

1;
