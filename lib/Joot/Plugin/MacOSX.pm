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
        my $out = run( bin('hdiutil'), qw(attach -owners on -nobrowse -nomount -shadow), disk( $joot ), $image->path() );
        my ($device) = ($out =~ m#^(/dev/disk\d+)#);

        DEBUG "matched device $device";

        # TODO put this partition in the config for the image
        # for now this is okay, because all images built in the standard way use the second part
        $device .= "s2";

        # hdiutil detach deletes $mnt for some annoying reason
        mkpath( $mnt );
        run( bin('mount'), qw(-o nodev -t hfs), $device, $mnt );

        # mount the /dev fs
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
