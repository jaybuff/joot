package Joot::Image;

use strict;
use warnings;

use Carp 'croak';
use Cwd ();
use Log::Log4perl ':easy';
use LWP::UserAgent ();
use Joot::Util qw( run bin );

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $url   = shift;
    my $args  = shift;
    $args->{url} = $url;

    my $self = bless $args, $class;
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

    my $file      = $self->path("save_ext");
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

    # uncompressed if necessary
    if ( $image_url =~ /\.bz2$/xi ) {
        run( bin('bunzip2'), $file );
    }
    elsif ( $image_url =~ /\.gz$/xi ) {
        run( bin('gunzip'), $file );
    }

    $self->{cached} = 1;
    return;
}

sub name {
    my $self = shift;

    my $url = $self->{url};
    my $name;
    if ( $url =~ m#.*/(.*)\.qcow2?(\.(bz2|gz))?$#xi ) {
        $name = $1;
    }
    else {
        croak "failed to convert $url to a name\n";
    }

    return $name;
}

# the path of where the image lives or will live on the file system when
# we cache it
sub path {
    my $self     = shift;
    my $save_ext = shift;    # by default we wont save the extension

    my $url = $self->{url};
    my $file;
    if ( $url =~ m#.*/(.*)#x ) {
        $file = $1;
    }
    else {
        croak "failed to convert $url to a file\n";
    }

    # we'll remove the .bz2 or .gz when we uncompress it
    if ( !$save_ext ) {
        $file =~ s/\.(gz|bz2)$//xi;
    }

    my $joot_home = Joot::Util::config("joot_home");
    return Cwd::abs_path("$joot_home/images/$file");
}

sub cached {
    return shift->{cached} || 0;
}

sub url {
    return shift->{url};
}

sub root_partition {
    return shift->{root_partition} || undef;
}

sub config {
    my $self = shift;

    return {
        url            => $self->url(),
        root_partition => $self->root_partition(),
    };
}

1;
