package Joot::Plugin::BindMount;

use strict;
use warnings;

use Cwd ();
use Joot ();
use Joot::Util qw(get_mounts is_mounted bin run mkpath);
use Log::Log4perl ':easy';

sub mount {
    my $joot = shift;
    my $args = shift;
    my @dirs = @_;

    if ( !@dirs && !$args->{'no-automount'} ) {
        return $joot->automount();
    }

    # if user passes in /.//foo and /foo/bar we need to
    # mount /foo then /foo/bar
    my $mnt = $joot->mount_point();
    foreach my $dir ( sort map { Cwd::abs_path($_) } @dirs ) {
        my $target = Cwd::abs_path("$mnt/$dir");

        if ( is_mounted($target) ) {
            DEBUG "$target is already mounted";
            next;
        }

        if ( !-e $dir ) {
            WARN "$dir doesn't exist.  Not trying to mount";
            next;
        }

        mkpath($target);
        run( bin('mount'), '--bind', $dir, $target );

        # can't bind mount readonly in one mount command
        # see http://lwn.net/Articles/281157/
        if ( $args->{'read-only'} ) {
            run( bin('mount'), '-o', 'remount,ro', $target );
        }
    }

    return;
}

# unmount specified dirs or everything if no dirs passed in
sub umount {
    my $joot = shift;
    my $args = shift;
    my @dirs = @_;

    my $mnt = Cwd::abs_path( $joot->mount_point() );

    # if the joot itself isn't mounted, there can't be anything mounted under it
    if ( !is_mounted($mnt) ) {
        DEBUG "joot isn't mounted, nothing to do";
        return;
    }

    if ( !@dirs ) {
        DEBUG "unmounting mounted dirs for this joot";
        foreach my $dir ( grep {/^$mnt/x} get_mounts() ) {
            run( bin("umount"), $dir );
        }

        return;
    }

    # if user passes in /.//foo and /foo/bar we need to
    # umount /foo/bar then /foo
    foreach my $dir ( reverse sort map { Cwd::abs_path($_) } @dirs ) {
        my $target = Cwd::abs_path("$mnt/$dir");
        if ( is_mounted($target) ) {
            run( bin("umount"), $target );
        }
        else {
            DEBUG "$dir isn't mounted in " . $joot->name();
        }
    }

    return;
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
