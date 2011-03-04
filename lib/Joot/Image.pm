package Joot::Image;

use strict;
use warnings;

use Cwd        ();
use File::Copy ();
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

    # handle local files specially
    if ( $image_url =~ m#^file://(.*)# ) {
        my $path = $1;
        if ( $self->compressed() ) {
            INFO "$image_url is local, copying (and uncompressing) rather than downloading";
            File::Copy::copy( $path, $file );
            $self->uncompress();
        }
        else {
            INFO "$image_url is local, creating symlink rather than downloading";
            link $path, $file;
        }

        $self->{cached} = 1;
        return;
    }

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

    $self->uncompress();

    $self->{cached} = 1;
    return;
}

sub uncompress {
    my $self = shift;

    my $file = $self->path("save_ext");
    if ( $file =~ /\.bz2$/xi ) {
        run( bin('bunzip2'), $file );
    }
    elsif ( $file =~ /\.gz$/xi ) {
        run( bin('gunzip'), $file );
    }

    return;
}

sub compressed {
    my $self = shift;

    if ( $self->url() =~ /\.(bz2|gz)$/xi ) {
        return 1;
    }

    return;
}

sub name {
    my $self = shift;

    my $url = $self->{url};
    my $name;
    if ( $url =~ m#.*/(.*)\.(qcow2?|sparseimage)(\.(bz2|gz))?$#xi ) {
        $name = $1;
    }
    else {
        die "failed to convert $url to a name\n";
    }

    return $name;
}

# the path of where the image lives or will live on the file system when
# we cache it
sub path {
    my $self     = shift;
    my $save_ext = shift;    # by default we wont save the extension

    my $url = $self->url();
    my $file;
    if ( $url =~ m#.*/(.*)#x ) {
        $file = $1;
    }
    else {
        die "failed to convert $url to a file\n";
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
