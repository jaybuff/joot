package Joot::Image;

use strict;
use warnings;

use Carp 'croak';
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
        croak $response->status_line;
    }

    $self->{cached} = 1;
    return;
}

sub name {
    my $self = shift;

    my $url = $self->{url};
    my $name;
    if ( $url =~ m#.*/(.*)\.#x ) {
        $name = $1;
    }
    else {
        croak "failed to convert $url to a name\n";
    }

    return $name;
}

sub path {
    my $self = shift;

    my $url = $self->{url};
    my $file;
    if ( $url =~ m#.*/(.*)#x ) {
        $file = $1;
    }
    else {
        croak "failed to convert $url to a file\n";
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
