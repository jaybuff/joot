package Joot::Plugin::Users;

use strict;
use warnings;

use Log::Log4perl qw(:easy);
use Carp;

# confirm the user has an account in the joot
# if the user does not, create it
package Joot::Plugin::SudoUsers;

use strict;
use warnings;

use Log::Log4perl qw(:easy);

sub post_create {
    my $joot = shift;

    my $conf    = $joot->get_config();
    my $creator = $conf->{creator};

    $joot->mount();
    my $sudoers_file = $joot->mount_point() . "/etc/sudoers";
    if ( !-e $sudoers_file ) {
        # handle the case where sudo isn't installed in the root
        return;
    }

    # if the user isn't listed in /etc/sudoers add them with this line:
    # jaybuff ALL=(ALL) ALL
    open my $readfh, '<', $sudoers_file or die "Couldn't open $sudoers_file: $!";
    if ( !grep /^$creator\s/, <$readfh> ) {
        DEBUG "adding $creator to /etc/sudoers inside joot";
        open my $writefh, '>>', $sudoers_file or die "Couldn't open $sudoers_file: $!";
        print $writefh "$creator ALL=(ALL) ALL";
    }

    return;
}

1;
