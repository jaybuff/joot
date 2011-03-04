package Joot::Plugin::MacOSX;

use Joot::Util qw( bin run mkpath is_mounted );
use Log::Log4perl qw(:easy);

sub mount {
    my $joot = shift;
    my $args = shift;
    my @dirs = @_;

    my $image = Joot::Image->new( $joot->get_config()->{image}->{url} );
    my $mnt = $joot->mount_point();

    # only mount if not mounted
    if ( !is_mounted( $mnt ) ) {
        run( bin('hdiutil'), qw(attach -owners on -nobrowse -mountpoint), $mnt, '-shadow', disk( $joot ), $image->path() );
        run( bin('mount'), qw(-t devfs devfs), "$mnt/dev" ); 

        # mount the file-descriptor file system (stdin, stdout, tty, etc)
        run( bin('mount'), qw(-t fdesc -o union stdin), "$mnt/dev" ); 
    }

    return;
}

sub disk {
    my $joot = shift;

    my $joot_dir = $joot->joot_dir();
    return "$joot_dir/disk.shadow";
}

1;
