package Joot::Plugin::Users;

use strict;
use warnings;

use Log::Log4perl qw(:easy);
use Carp;

# confirm the user has an account in the joot
# if the user does not, create it
#    and create of the user's groups that don't exist (die if gid different)
# if the user exists
#    and uid is different, warn the user
sub post_create {
    my $joot = shift;

    my $conf    = $joot->get_config();
    my $creator = $conf->{creator};

    $joot->mount();
    my $jootpw_file = $joot->mount_point() . "/etc/passwd";
    my $pw          = parse_passwd($jootpw_file);
    my $rootpw      = parse_passwd("/etc/passwd");

    if ( !$pw->{$creator} ) {

        # confirm the user's id isn't used by anyone else in the joot
        my $to_add = $rootpw->{$creator} or die "$creator doesn't exist in /etc/passwd\n";
        foreach my $user ( keys %{$pw} ) {

            # the user needs to have the same uid so mounted directories will
            # be owned by the correct user
            if ( $to_add->{uid} == $pw->{$user}->{uid} ) {
                die "UID for user $creator already in use in joot\n";
            }
        }

        my $shadow = parse_shadow("/etc/shadow");

        # confirm the user's group exists and the gid is consistent
        my $joot_group_file = $joot->mount_point() . "/etc/group";
        my $group           = parse_group($joot_group_file);
        my $root_group      = parse_group("/etc/group");
        if ( !exists $group->{ $to_add->{gid} } ) {
            add_line( $joot_group_file, $root_group->{ $to_add->{gid} }->{raw} );
        }
        else {
            if ( $group->{ $to_add->{gid} }->{name} ne $root_group->{ $to_add->{gid} }->{name} ) {
                die "The group id for ${creator}'s primary group is different inside the joot.\n";
            }
        }

        add_line( $jootpw_file,                         $to_add->{raw} );
        add_line( $joot->mount_point() . "/etc/shadow", $shadow->{$creator} );
    }
    else {
        if ( $pw->{$creator}{uid} != $rootpw->{$creator}{uid} ) {
            WARN "The uid of $creator in the joot is different than the uid of $creator in the root\n";
        }
    }

    return;
}

sub parse_group {
    my $file = shift;

    my %group;
    open my $fh, '<', $file or die "can't open $file: $!\n";
    while ( my $line = <$fh> ) {
        my ( $name, $pw, $id, $users ) = split ':', $line;
        $group{$id} = {
            name => $name,
            raw  => $line,
        };
    }

    return \%group;
}

sub parse_passwd {
    my $file = shift;

    my %passwd;
    open my $fh, '<', $file or die "can't open $file: $!\n";
    while ( my $line = <$fh> ) {
        my ( $user, $pass, $uid, $gid ) = split ':', $line;
        $passwd{$user} = {
            raw => $line,
            uid => $uid,
            gid => $gid,
        };
    }

    return \%passwd;
}

sub parse_shadow {
    my $file = shift;

    my %shadow;
    open my $fh, '<', $file or die "can't open $file: $!\n";
    while ( my $line = <$fh> ) {
        my $user = ( split ':', $line )[0];
        $shadow{$user} = $line;
    }

    return \%shadow;
}

sub add_line {
    my $file = shift;
    my $line = shift;

    DEBUG "adding line to $file";
    open my $fh, ">>", $file or die "Failed to open $file: $!\n";
    print $fh $line;
    close $fh;

    return;
}

1;
