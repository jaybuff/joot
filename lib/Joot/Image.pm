package Joot::Image;

use strict;
use warnings;

use Log::Log4perl ':easy';
use LWP::UserAgent ();
use Joot::Util     ();

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $url   = shift;

	my $self = bless { url => $url, }, $class;
	my $path = $self->path();
	if ( -e $path ) {
		$self->{cached} = 1;
	}

	return $self;
}

sub download {
	my $self = shift;

	if ( $self->cached() ) {
		WARN "tried to install an image that is already installed";
		return;
	}

	my $file      = $self->path();
	my $image_url = $self->url();
	DEBUG "saving $image_url to $file";

	my $ua = Joot::Util::get_ua();

	my $url = $self->url();
	if ( $LWP::UserAgent::VERSION >= 5.815 ) {
		$ua->show_progress(1);
	}
	else {
		print "Downloading $url...";
	}

	DEBUG("saving $url to $file");
	my $response = $ua->get( $url, ":content_file" => $file );

	if ( !$response->is_success ) {
		die $response->status_line;
	}

	$self->{cached} = 1;
}

sub name {
	my $self = shift;
	my $url  = $self->{url};
	$url =~ m#.*/(.*)\.#;
	my $name = $1;
	if ( !$name ) {
		die "failed to convert $url to a name\n";
	}

	return $name;
}

sub path {
	my $self = shift;

	my $url = $self->{url};
	$url =~ m#.*/(.*)#;
	my $file = $1;
	if ( !$file ) {
		die "failed to convert $url to a file\n";
	}

	my $joot_home = Joot::Util::config("joot_home");
	return "$joot_home/images/$file";
}

sub cached {
	return shift->{cached} || 0;
}

sub url {
	return shift->{url};
}

1;
