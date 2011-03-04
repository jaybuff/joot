package Joot::Util;

use strict;
use warnings;

our ( @EXPORT_OK, %EXPORT_TAGS );

use base 'Exporter';
my @standard = qw( config bin run slurp get_ua
  get_url mkpath rmpath is_mounted get_mounts get_gids proxy_socket drop_root );
@EXPORT_OK = ( @standard, qw( sudo ) );
%EXPORT_TAGS = ( standard => \@standard );

use Cwd ();
use English '-no_match_vars';
use File::Path ();
use IPC::Cmd   ();
use JSON       ();
use Log::Log4perl ':easy';
use LWP::UserAgent ();

# two ways to call config:
# my $cfg = config();
# print "foo setting is " . $cfg->{foo};
# or
# print "foo setting is " . config( "foo", "foo_default" );
# default is optional (will die if setting is missing)
{
    my $config;    # singleton

    sub config {
        my $field   = shift;
        my $default = shift;

        # read in the config file, parse it and store it in the object
        # only do this once
        if ( !$config ) {

            # determine which config file we're going to read in
            my $config_file;
            foreach my $file ( $ENV{JOOT_CONFIG}, "$ENV{HOME}/.joot", "/etc/joot.cfg" ) {
                if ( $file && -r $file ) {
                    $config_file = $file;
                    last;
                }
            }
            if ( !$config_file ) {
                die "couldn't find valid config file (checked \$JOOT_CONFIG, $ENV{HOME}/.joot and /etc/joot.cfg)\n";
            }
            DEBUG( "Reading config file " . $config_file );
            $config = JSON::from_json( slurp($config_file), { relaxed => 1 } );
        }

        # if the user requests a field, send back the value (or the default)
        # otherwise, give them the whole hash reference
        if ( defined $field ) {
            if ( exists $config->{$field} ) {
                if ( wantarray && ref( $config->{$field} ) ne "ARRAY" ) {
                    die "config file setting $field should be an array\n";
                }

                return $config->{$field};
            }
            elsif ( defined $default ) {
                return $default;
            }
            else {
                die "Config file is missing required setting \"$field\"\n";
            }
        }

        return $config;
    }
}

sub get_ua {
    my $ua = LWP::UserAgent->new();
    $ua->timeout(3);
    $ua->env_proxy();    # respect HTTP_PROXY env vars

    return $ua;
}

# returns a list of mounts in reverse sorted order
sub get_mounts {
    my @mounts;

    # lines from /proc/mount look like this:
    # /dev/sdh1 /home/jaybuff/joot/joots/foo/mnt/home/jaybuff ext3 rw,relatime,errors=continue,data=writeback 0 0
    my $mounts = slurp("/proc/mounts");
    foreach my $line ( split "\n", $mounts ) {
        my ($target) = ( split /\s+/x, $line, 3 )[1];
        push @mounts, Cwd::abs_path($target);
    }

    return reverse sort @mounts;
}

sub is_mounted {
    my $target = shift;

    # normalize input
    $target = Cwd::abs_path($target);
    return grep { $_ eq $target } get_mounts();
}

sub bin {
    my $prog = shift;

    # use this search path.  die if $prog isn't in one of these dirs
    my @paths = qw(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin);
    foreach my $path (@paths) {
        if ( -x "$path/$prog" ) {
            return "$path/$prog";
        }
    }

    die "couldn't find $prog in " . join( ":", @paths ) . "\n";
}

sub run {
    my @args = @_;

    if ( get_logger()->level() == $DEBUG ) {
        $IPC::Cmd::VERBOSE = 1;
    }

    my $cmd = join( " ", @args );
    my ( $success, $err, $full_buf, $stdout_buf, $stderr_buf ) = IPC::Cmd::run( command => \@args );

    if ( !$success ) {
        FATAL "Error executing $cmd";
        if ($full_buf) {
            FATAL join( "", @{$full_buf} );
        }
        die "$err\n";
    }

    return join( "", @{$stdout_buf} );
}

sub slurp {
    my $file = shift;
    return do {
        local $/ = undef;
        open my $fh, '<', $file or die "can't read contents of $file: $OS_ERROR\n";
        my $content = <$fh>;
        close $fh;
        $content;
    };
}

sub get_url {
    my $url = shift;

    my $ua = get_ua();

    DEBUG("fetching $url");
    my $response = $ua->get($url);

    if ( !$response->is_success ) {
        die $response->status_line() . "\n";
    }

    return $response->decoded_content();
}

sub mkpath {
    my $dir = shift;

    File::Path::make_path( $dir, { verbose => get_logger()->level() == $DEBUG } );
    return;
}

sub rmpath {
    my $dir = shift;

    File::Path::remove_tree( $dir, { verbose => get_logger()->level() == $DEBUG } );
    return;
}

sub sudo {
    my $cmd  = shift;
    my $argv = shift;

    # escalate privileges to root, unless the user is already root
    if ( $< != 0 ) {

        # preserve these env variables
        my @env_cmd = bin("env");
        foreach my $envvar ( @{ config("pass_thru_env") } ) {
            if ( $ENV{$envvar} ) {
                push @env_cmd, "$envvar=$ENV{$envvar}";
            }
        }
        my @cmd = ( bin("sudo"), @env_cmd, $cmd, @{$argv} );
        DEBUG "exec " . join " ", @cmd;
        exec(@cmd);
    }
}

# set effective/real gid and uid to the uid/gid of the user we're passed
# this is basically setuid/setgid
sub drop_root {
    my $user = shift;

    if ( $user eq "root" ) {
        die "drop_root must be given a user other than 'root' to switch to\n";
    }

    my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
    if ( !defined $uid ) {
        die "Failed to getpwnam( $user ): $OS_ERROR\n";
    }

    $EFFECTIVE_GROUP_ID = join( " ", $gid, get_gids($user) );
    $REAL_GROUP_ID = $gid;

    $EFFECTIVE_USER_ID = $uid;
    $REAL_USER_ID = $uid;

    return;
}

{
    my %gids;

    sub get_gids {
        my $user = shift;

        if ( !%gids ) {
            setgrent();    # rewind the list
            while ( my ( $gid, $members ) = ( getgrent() )[ 2, 3 ] ) {
                foreach my $member ( split /\s+/x, $members ) {
                    push @{ $gids{$member} }, $gid;
                }
            }
        }

        my $gid = ( getpwnam($user) )[3];
        die "Failed to getpwnam: $OS_ERROR\n" if !$gid;

        if ( $gids{$user} ) {
            return ( $gid, @{ $gids{$user} } );
        }
        else {
            return $gid;
        }
    }
}

# warning: the caller is responsible for dealing with the the child (either
# kill it or waitpid)
sub proxy_socket {
    my $src  = shift;
    my $dest = shift;

    my $dir = ( File::Spec->splitpath($dest) )[1];
    mkpath($dir);

    # build the command before we fork because bin() might throw
    my @cmd = ( bin("socat"), "UNIX-CONNECT:$src", "UNIX-LISTEN:$dest,fork" );
    my $pid = fork();
    if ( !defined $pid ) {
        die "failed to fork: $OS_ERROR\n";
    }
    elsif ( $pid == 0 ) {
        DEBUG "exec " . join " ", @cmd;
        exec(@cmd);
    }

    local $SIG{ALRM} = sub { die "socat failed to create socket\n"; };
    alarm(5);
    while (1) {
        if ( -S $dest ) {
            alarm(0);    # cancel alarm
            last;
        }
    }

    return $pid;
}

1;
