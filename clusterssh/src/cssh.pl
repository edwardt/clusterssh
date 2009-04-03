# - perl *-
# $Id$
#
# Script:
#   $RCSfile$
#
# Usage:
#   cssh [options] [hostnames] [...]
#
# Options:
#   see pod documentation
#
# Parameters:
#   hosts to open connection to
#
# Purpose:
#   Concurrently administer multiple remote servers
#
# Dependencies:
#   Perl 5.6.0
#   Tk 800.022
#
# Limitations:
#
# Enhancements:
#
# Notes:
#
# License:
#   This code is distributed under the terms of the GPL (GNU General Pulic
#   License).
#
#   Copyright (C)
#
#   This program is free software; you can redistribute it and/or modify it
#   under the terms of the GNU General Public License as published by the
#   Free Software Foundation; either version 2 of the License, or any later
#   version.
#
#   This program is distributed in the hope that it will be useful, but
#   WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
#   Public License for more details.
#
#   You should have received a copy of the GNU General Public License along
#   with this program; if not, write to the Free Software Foundation, Inc.,
#   59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
#   Please see the full text of the licenses is in the file COPYING and also at
#     http://www.opensource.org/licenses/gpl-license.php
#
############################################################################
my $VERSION = '$Revision$ ($Date$)';

# Now tidy it up, but in such as way cvs doesn't kill the tidy up stuff
$VERSION =~ s/\$Revision: //;
$VERSION =~ s/\$Date: //;
$VERSION =~ s/ \$//g;

### all use statements ###
use strict;
use warnings;

use 5.006_000;
use Pod::Usage;
use Getopt::Std;
use POSIX qw/:sys_wait_h strftime mkfifo/;
use File::Temp qw/:POSIX/;
use Fcntl;
use Tk 800.022;
use Tk::Xlib;
use Tk::ROText;
require Tk::Dialog;
require Tk::LabEntry;
use X11::Protocol;
use X11::Protocol::Constants qw/ Shift Mod5 ShiftMask /;
use vars qw/ %keysymtocode %keycodetosym /;
use X11::Keysyms '%keysymtocode', 'MISCELLANY', 'XKB_KEYS', '3270', 'LATIN1',
    'LATIN2', 'LATIN3', 'LATIN4', 'KATAKANA', 'ARABIC', 'CYRILLIC', 'GREEK',
    'TECHNICAL', 'SPECIAL', 'PUBLISHING', 'APL', 'HEBREW', 'THAI', 'KOREAN';
use File::Basename;
use Net::hostent;

### all global variables ###
my $scriptname = $0;
$scriptname =~ s!.*/!!;    # get the script name, minus the path

my $options = 'dDv?hHuqQgGist:T:c:l:o:e:C:p:';    # Command line options list
my %options;
my %config;
my $debug = 0;
my %clusters;    # hash for resolving cluster names
my %windows;     # hash for all window definitions
my %menus;       # hash for all menu definitions
my @servers;     # array of servers provided on cmdline
my %servers;     # hash of server cx info
my $helper_script = "";
my $xdisplay;
my %keyboardmap;
my $sysconfigdir = "/etc";
my %ssh_hostnames;

# Fudge to get X11::Keysyms working
%keysymtocode = %main::keysymtocode;
$keysymtocode{unknown_sym} = 0xFFFFFF;    # put in a default "unknown" entry
$keysymtocode{EuroSign}
    = 0x20AC;    # Euro sigyn - missing from X11::Protocol::Keysyms

# and also map it the other way
%keycodetosym = reverse %keysymtocode;

# Set up UTF-8 on STDOUT
binmode STDOUT, ":utf8";

#use bytes;

### all sub-routines ###

# Pick a color based on a string.
sub pick_color {
    my ($string)   = @_;
    my @components = qw(AA BB CC EE);
    my $color      = 0;
    for ( my $i = 0; $i < length($string); $i++ ) {
        $color += ord( substr( $string, $i, 1 ) );
    }

    srand($color);
    my $ans = '\\#';
    $ans .= $components[ int( 4 * rand() ) ];
    $ans .= $components[ int( 4 * rand() ) ];
    $ans .= $components[ int( 4 * rand() ) ];
    return $ans;
}

# close a specific host session
sub terminate_host($) {
    my $svr = shift;
    logmsg( 2, "Killing session for $svr" );
    if ( !$servers{$svr} ) {
        logmsg( 2, "Session for $svr not found" );
        return;
    }

    logmsg( 2, "Killing process $servers{$svr}{pid}" );
    kill( 9, $servers{$svr}{pid} ) if kill( 0, $servers{$svr}{pid} );
    delete( $servers{$svr} );
}

# catch_all exit routine that should always be used
sub exit_prog() {
    logmsg( 3, "Exiting via normal routine" );

    # for each of the client windows, send a kill

    # to make sure we catch all children, even when they havnt
    # finished starting or received teh kill signal, do it like this
    while (%servers) {
        foreach my $svr ( keys(%servers) ) {
            terminate_host($svr);
        }
    }
    exit 0;
}

# output function according to debug level
# $1 = log level (0 to 3)
# $2 .. $n = list to pass to print
sub logmsg($@) {
    my $level = shift;

    if ( $level <= $debug ) {
        print( strftime( "%H:%M:%S: ", localtime ) ) if ( $debug > 1 );
        print @_, $/;
    }
}

# set some application defaults
sub load_config_defaults() {
    $config{terminal}           = "xterm";
    $config{terminal_args}      = "";
    $config{terminal_title_opt} = "-T";
    $config{terminal_colorize}  = 1;
    $config{terminal_bg_style}  = 'dark';
    $config{terminal_allow_send_events}
        = "-xrm '*.VT100.allowSendEvents:true'";
    $config{terminal_font}           = "6x13";
    $config{terminal_size}           = "80x24";
    $config{use_hotkeys}             = "yes";
    $config{key_quit}                = "Control-q";
    $config{key_addhost}             = "Control-plus";
    $config{key_clientname}          = "Alt-n";
    $config{key_history}             = "Alt-h";
    $config{key_retilehosts}         = "Alt-r";
    $config{key_paste}               = "Control-v";
    $config{mouse_paste}             = "Button-2";
    $config{auto_quit}               = "yes";
    $config{window_tiling}           = "yes";
    $config{window_tiling_direction} = "right";
    $config{console_position}        = "";

    $config{screen_reserve_top}    = 0;
    $config{screen_reserve_bottom} = 40;
    $config{screen_reserve_left}   = 0;
    $config{screen_reserve_right}  = 0;

    $config{terminal_reserve_top}    = 0;
    $config{terminal_reserve_bottom} = 0;
    $config{terminal_reserve_left}   = 0;
    $config{terminal_reserve_right}  = 0;

    $config{terminal_decoration_height} = 10;
    $config{terminal_decoration_width}  = 8;

    ( $config{comms} = basename($0) ) =~ s/^.//;
    $config{comms} =~ s/.pl$//;    # for when testing directly out of cvs
    $config{method} = $config{comms};

    $config{title} = "C" . uc( $config{comms} );

    $config{comms} = "telnet" if ( $config{comms} eq "tel" );

    $config{ $config{comms} } = $config{comms};

    $config{ssh_args} = " -x -o ConnectTimeout=10"
        if ( $config{ $config{comms} } =~ /ssh$/ );
    $config{ssh_args} = $options{o} if ( $options{o} );
    $config{rsh_args} = "";

    $config{telnet_args} = "";

    $config{extra_cluster_file} = "";

    $config{unmap_on_redraw} = "no";    # Debian #329440

    $config{show_history}   = 0;
    $config{history_width}  = 40;
    $config{history_height} = 10;
}

# load in config file settings
sub parse_config_file($) {
    my $config_file = shift;
    logmsg( 2, "Reading in from config file $config_file" );
    return if ( !-e $config_file || !-r $config_file );

    open( CFG, $config_file ) or die("Couldnt open $config_file: $!");
    while (<CFG>) {
        next if ( /^\s*$/ || /^#/ );    # ignore blank lines & commented lines
        s/#.*//;                        # remove comments from remaining lines
        s/\s*$//;                       # remove trailing whitespace
        chomp();

        next unless m/\s*(\S+)\s*=\s*(.*)\s*/;
        my ( $key, $value ) = ( $1, $2 );
        $config{$key} = $value;
        logmsg( 3, "$key=$value" );
    }
    close(CFG);

    # tidy up entries, just in case
    $config{terminal_font} =~ s/['"]//g;
}

sub find_binary($) {
    my $binary = shift;

    logmsg( 2, "Looking for $binary" );
    my $path;
    if ( !-x $binary ) {

       # search the users $PATH and then a few other places to find the binary
       # just in case $PATH isnt set up right
        foreach (
            split( /:/, $ENV{PATH} ), qw!
            /bin
            /sbin
            /usr/sbin
            /usr/bin
            /usr/local/bin
            /usr/local/sbin
            /opt/local/bin
            /opt/local/sbin
            !
            )
        {
            logmsg( 3, "Looking in $_" );

            if ( -x $_ . '/' . $binary ) {
                $path = $_ . '/' . $binary;
                logmsg( 2, "Found at $path" );
                last;
            }
        }
    }
    else {
        logmsg( 2, "Already configured OK" );
        $path = $binary;
    }
    if ( !$path || !-f $path || !-x $path ) {
        warn(
            "Terminal binary not found ($binary) - please amend \$PATH or the cssh config file\n"
        );
        die unless ( $options{u} );
    }

    chomp($path);
    return $path;
}

# make sure our config is sane (i.e. binaries found) and get some extra bits
sub check_config() {

    # check we have xterm on our path
    logmsg( 2, "Checking path to xterm" );
    $config{terminal} = find_binary( $config{terminal} );

    # check we have comms method on our path
    logmsg( 2, "Checking path to $config{comms}" );
    $config{ $config{comms} } = find_binary( $config{ $config{comms} } );

    # make sure comms in an accepted value
    die
        "FATAL: Only ssh, rsh and telnet protocols are currently supported (comms=$config{comms})\n"
        if ( $config{comms} !~ /^(:?[rs]sh|telnet)$/ );

    # Set any extra config options given on command line
    $config{title} = $options{T} if ( $options{T} );

    $config{auto_quit} = "yes" if $options{q};
    $config{auto_quit} = "no"  if $options{Q};

    # backwards compatibility & tidyup
    if ( $config{always_tile} ) {
        if ( !$config{window_tiling} ) {
            if ( $config{always_tile} eq "never" ) {
                $config{window_tiling} = "no";
            }
            else {
                $config{window_tiling} = "yes";
            }
        }
        delete( $config{always_tile} );
    }
    $config{window_tiling} = "yes" if $options{g};
    $config{window_tiling} = "no"  if $options{G};

    $config{user}          = $options{l} if ( $options{l} );
    $config{terminal_args} = $options{t} if ( $options{t} );

    if ( $config{terminal_args} =~ /-class (\w+)/ ) {
        $config{terminal_allow_send_events}
            = "-xrm '$1.VT100.allowSendEvents:true'";
    }

    $config{internal_previous_state} = "";    # set to default
    get_font_size();

    $config{extra_cluster_file} =~ s/\s+//g;

    $config{show_history} = 1 if $options{s};
}

sub load_configfile() {
    parse_config_file( $sysconfigdir . '/csshrc' );
    parse_config_file( $ENV{HOME} . '/.csshrc' );
    if ( $options{C} && -r $options{C} ) {
        parse_config_file( $options{C} );
    }
    check_config();
}

# dump out the config to STDOUT
sub dump_config {
    my $noexit = shift;

    logmsg( 3, "Dumping config to STDOUT" );

    print("# Configuration dump produced by 'cssh -u'\n");

    foreach ( sort( keys(%config) ) ) {
        next
            if ( $_ =~ /^internal/ && $debug == 0 )
            ;    # do not output internal vars
        print "$_=$config{$_}\n";
    }
    exit_prog if ( !$noexit );
}

sub check_ssh_hostnames {
    return unless ( $config{method} eq "ssh" );

    my $ssh_config = "$ENV{HOME}/.ssh/config";

    if ( -r $ssh_config && open( SSHCFG, "<", $ssh_config ) ) {
        while (<SSHCFG>) {
            next unless (m/^\s*host\s+([\w\.-]+)/i);
            $ssh_hostnames{$1} = 1;
        }
        close(SSHCFG);
    }

    if ( $debug > 1 ) {
        if (%ssh_hostnames) {
            logmsg( 2, "Parsed these ssh config hosts:" );
            logmsg( 2, "- $_" ) foreach ( sort( keys(%ssh_hostnames) ) );
        }
        else {
            logmsg( 2, "No hostnames parsed from user ssh config file" );
        }
    }
}

sub evaluate_commands {
    my ( $return, $user, $port, $host );

    # break apart the given host string to check for user or port configs
    print "{e}=$options{e}\n";
    $user = $1 if ( $options{e} =~ s/^(.*)@// );
    $port = $1 if ( $options{e} =~ s/:(\w+)$// );
    $host = $options{e};

    $user = $user ? "-l $user" : "";
    if ( $config{comms} eq "telnet" ) {
        $port = $port ? " $port" : "";
    }
    else {
        $port = $port ? "-p $port" : "";
    }

    print STDERR "Testing terminal - running command:\n";

    my $terminal_command
        = "$config{terminal} $config{terminal_allow_send_events} -e \"$^X\" \"-e\" 'print \"Working\\n\" ; sleep 5'";

    print STDERR $terminal_command, $/;

    system($terminal_command);
    print STDERR "\nTesting comms - running command:\n";

    my $comms_command = $config{ $config{comms} } . " "
        . $config{ $config{comms} . "_args" };

    if ( $config{comms} eq "telnet" ) {
        $comms_command .= " $host $port";
    }
    else {
        $comms_command .= " $user $port $host echo Working";
    }

    print STDERR $comms_command, $/;

    system($comms_command);

    exit_prog;
}

sub load_keyboard_map() {

    # load up the keyboard map to convert keysyms to keyboardmap
    my $min      = $xdisplay->{min_keycode};
    my $count    = $xdisplay->{max_keycode} - $min;
    my @keyboard = $xdisplay->GetKeyboardMapping( $min, $count );

    # @keyboard arry
    #  0 = plain key
    #  1 = with shift
    #  2 = with Alt-GR
    #  3 = with shift + AltGr
    #  4 = same as 2 - control/alt?
    #  5 = same as 3 - shift-control-alt?

    logmsg( 1, "Loading keymaps and keycodes" );

    foreach ( 0 .. $#keyboard ) {
        if ( defined $keyboard[$_][0] ) {
            if ( defined( $keycodetosym{ $keyboard[$_][0] } ) ) {
                $keyboardmap{ $keycodetosym{ $keyboard[$_][0] } }
                    = 'n' . ( $_ + $min );
            }
            else {
                logmsg( 2, "Unknown keycode ", $keyboard[$_][0] )
                    if ( $keyboard[$_][0] != 0 );
            }
        }
        if ( defined $keyboard[$_][1] ) {
            if ( defined( $keycodetosym{ $keyboard[$_][1] } ) ) {
                $keyboardmap{ $keycodetosym{ $keyboard[$_][1] } }
                    = 's' . ( $_ + $min );
            }
            else {
                logmsg( 2, "Unknown keycode ", $keyboard[$_][1] )
                    if ( $keyboard[$_][1] != 0 );
            }
        }
        if ( defined $keyboard[$_][2] ) {
            if ( defined( $keycodetosym{ $keyboard[$_][2] } ) ) {
                $keyboardmap{ $keycodetosym{ $keyboard[$_][2] } }
                    = 'a' . ( $_ + $min );
            }
            else {
                logmsg( 2, "Unknown keycode ", $keyboard[$_][2] )
                    if ( $keyboard[$_][2] != 0 );
            }
        }
        if ( defined $keyboard[$_][3] ) {
            if ( defined( $keycodetosym{ $keyboard[$_][3] } ) ) {
                $keyboardmap{ $keycodetosym{ $keyboard[$_][3] } }
                    = 'sa' . ( $_ + $min );
            }
            else {
                logmsg( 2, "Unknown keycode ", $keyboard[$_][3] )
                    if ( $keyboard[$_][3] != 0 );
            }
        }

        # dont know these two key combs yet...
        #$keyboardmap{ $keycodetosym { $keyboard[$_][4] } } = $_ + $min;
        #$keyboardmap{ $keycodetosym { $keyboard[$_][5] } } = $_ + $min;
    }

    #	print "$_ => $keyboardmap{$_}\n" foreach(sort(keys(%keyboardmap)));
    #	print "keysymtocode: $keysymtocode{o}\n";
    #	die;
}

sub get_keycode_state($) {
    my $keysym = shift;
    $keyboardmap{$keysym} =~ m/^(\D+)(\d+)$/;
    my ( $state, $code ) = ( $1, $2 );

    logmsg( 2, "keyboardmap=:", $keyboardmap{$keysym}, ":" );
    logmsg( 2, "state=$state, code=$code" );

SWITCH: for ($state) {
        /^n$/ && do {
            $state = 0;
            last SWITCH;
        };
        /^s$/ && do {
            $state = Shift();
            last SWITCH;
        };
        /^a$/ && do {
            $state = Mod5();
            last SWITCH;
        };
        /^sa$/ && do {
            $state = Shift() + Mod5();
            last SWITCH;
        };

        die("Should never reach here");
    }

    logmsg( 2, "returning state=:$state: code=:$code:" );

    return ( $state, $code );
}

# read in all cluster definitions
sub get_clusters() {

    # first, read in global file
    my $cluster_file = '/etc/clusters';

    logmsg( 3, "Logging for $cluster_file" );

    if ( -f $cluster_file ) {
        logmsg( 2, "Loading clusters in from $cluster_file" );
        open( CLUSTERS, $cluster_file ) || die("Couldnt read $cluster_file");
        while (<CLUSTERS>) {
            next
                if ( /^\s*$/ || /^#/ ); # ignore blank lines & commented lines
            chomp();
            my @line = split(/\s/);

        #s/^([\w-]+)\s*//;               # remote first word and stick into $1

            logmsg(
                3,
                "cluster $line[0] = ",
                join( " ", @line[ 1 .. $#line ] )
            );
            $clusters{ $line[0] } = join( " ", @line[ 1 .. $#line ] )
                ;                       # Now bung in rest of line
        }
        close(CLUSTERS);
    }

    # Now get any definitions out of %config
    logmsg( 2, "Looking for csshrc" );
    if ( $config{clusters} ) {
        logmsg( 2, "Loading clusters in from csshrc" );

        foreach ( split( /\s+/, $config{clusters} ) ) {
            if ( !$config{$_} ) {
                warn(
                    "WARNING: missing cluster definition in .csshrc file ($_)"
                );
            }
            else {
                logmsg( 3, "cluster $_ = $config{$_}" );
                $clusters{$_} = $config{$_};
            }
        }
    }

    # and any clusters defined within the config file or on the command line
    if ( $config{extra_cluster_file} || $options{c} ) {

        # check for multiple entries and push it through glob to catch ~'s
        foreach my $item ( split( /,/, $config{extra_cluster_file} ),
            $options{c} )
        {
            next unless ($item);

            # cater for people using '$HOME'
            $item =~ s/\$HOME/$ENV{HOME}/;
            foreach my $file ( glob($item) ) {
                if ( !-r $file ) {
                    warn("Unable to read cluster file '$file': $!\n");
                    next;
                }
                logmsg( 2, "Loading clusters in from '$file'" );

                open( CLUSTERS, $file ) || die("Couldnt read '$file': $!\n");
                while (<CLUSTERS>) {
                    next if ( /^\s*$/ || /^#/ );
                    chomp;

                    my @line = split(/\s/);
                    logmsg(
                        3,
                        "cluster $line[0] = ",
                        join( " ", @line[ 1 .. $#line ] )
                    );
                    $clusters{ $line[0] } = join( " ", @line[ 1 .. $#line ] )
                        ;    # Now bung in rest of line
                }
            }

        }
    }

    logmsg( 2, "Finished loading clusters" );
}

sub resolve_names(@) {
    logmsg( 2, "Resolving cluster names: started" );
    my @servers = @_;

    foreach (@servers) {
        logmsg( 3, "Found server $_" );

        if ( $clusters{$_} ) {
            push( @servers, split( / /, $clusters{$_} ) );
            $_ = "";
        }
    }

    my @cleanarray;

    # now clean the array up
    foreach (@servers) {
        push( @cleanarray, $_ ) if ( $_ !~ /^$/ );
    }

    foreach (@cleanarray) {
        logmsg( 3, "leaving with $_" );
    }
    logmsg( 2, "Resolving cluster names: completed" );
    return (@cleanarray);
}

sub change_main_window_title() {
    my $number = keys(%servers);
    $windows{main_window}->title( $config{title} . " [$number]" );
}

sub show_history() {
    if ( $config{show_history} ) {
        $windows{history}->packForget();
        $config{show_history} = 0;
    }
    else {
        $windows{history}->pack(
            -fill   => "x",
            -expand => 1,
        );
        $config{show_history} = 1;
    }
}

sub update_display_text($) {
    my $char = shift;

    return if ( !$config{show_history} );

    logmsg( 2, "Dropping :$char: into display" );

SWITCH: {
        foreach ($char) {
            /^Return$/ && do {
                $windows{history}->insert( 'end', "\n" );
                last SWITCH;
            };

            /^BackSpace$/ && do {
                $windows{history}->delete('end - 2 chars');
                last SWITCH;
            };

            /^(:?Shift|Control|Alt)_(:?R|L)$/ && do {
                last SWITCH;
            };

            length($char) > 1 && do {
                $windows{history}
                    ->insert( 'end', chr( $keysymtocode{$char} ) )
                    if ( $keysymtocode{$char} );
                last SWITCH;
            };

            do {
                $windows{history}->insert( 'end', $char );
                last SWITCH;
            };
        }
    }
}

sub send_text($@) {
    my $svr = shift;
    my $text = join( "", @_ );

    #logmsg( 2, "Sending to $svr text:$text:" );

    logmsg( 2, "servers{$svr}{wid}=$servers{$svr}{wid}" );

    foreach my $char ( split( //, $text ) ) {
        next if ( !defined($char) );
        my $ord = ord($char);
        $ord = 65293 if ( $ord == 10 );    # convert 'Return' to sym

        if ( !defined( $keycodetosym{$ord} ) ) {
            warn("Unknown character in xmodmap keytable: $char ($ord)\n");
            next;
        }
        my $keysym  = $keycodetosym{$ord};
        my $keycode = $keysymtocode{$keysym};

        logmsg( 2, "Looking for char :$char: with ord :$ord:" );
        logmsg( 2, "Looking for keycode :$keycode:" );
        logmsg( 2, "Looking for keysym  :$keysym:" );
        logmsg( 2, "Looking for keyboardmap :", $keyboardmap{$keysym}, ":" );
        my ( $state, $code ) = get_keycode_state($keysym);
        logmsg( 2, "Got state :$state: code :$code:" );

        for my $event (qw/KeyPress KeyRelease/) {
            logmsg( 2, "sending event=$event code=:$code: state=:$state:" );
            $xdisplay->SendEvent(
                $servers{$svr}{wid},
                0,
                $xdisplay->pack_event_mask($event),
                $xdisplay->pack_event(
                    'name'        => $event,
                    'detail'      => $code,
                    'state'       => $state,
                    'time'        => time(),
                    'event'       => $servers{$svr}{wid},
                    'root'        => $xdisplay->root(),
                    'same_screen' => 1,
                ),
            );
        }
    }
    $xdisplay->flush();
}

sub send_clientname() {
    foreach my $svr ( keys(%servers) ) {
        send_text( $svr, $servers{$svr}{realname} )
            if ( $servers{$svr}{active} == 1 );
    }
}

sub send_resizemove($$$$$) {
    my ( $win, $x_pos, $y_pos, $x_siz, $y_siz ) = @_;

    logmsg( 3,
        "Moving window $win to x:$x_pos y:$y_pos (size x:$x_siz y:$y_siz)" );

    #logmsg( 2, "resize move normal: ", $xdisplay->atom('WM_NORMAL_HINTS') );
    #logmsg( 2, "resize move size:   ", $xdisplay->atom('WM_SIZE_HINTS') );

    # set the window to have "user" set size & position, rather than "program"
    $xdisplay->req(
        'ChangeProperty',
        $win,
        $xdisplay->atom('WM_NORMAL_HINTS'),
        $xdisplay->atom('WM_SIZE_HINTS'),
        32,
        'Replace',

        # dark magic - create data struct on fly - to set required flags
        pack( "L" . "x[i]" x 17, 3 ),
    );

    $xdisplay->req(
        'ConfigureWindow',
        $win,
        'x'      => $x_pos,
        'y'      => $y_pos,
        'width'  => $x_siz,
        'height' => $y_siz,
    );

    #$xdisplay->flush(); # dont flush here, but after all tiling worked out
}

sub setup_helper_script() {
    logmsg( 2, "Setting up helper script" );
    my $defaultport = ( defined $options{p} ) ? $options{p} : "";
    $helper_script = <<"	HERE";
		my \$pipe=shift;
		my \$svr=shift;
		my \$user=shift;
		my \$port=shift;
		my \$command="$config{$config{comms}} $config{$config{comms}."_args"} ";
		open(PIPE, ">", \$pipe) or die("Failed to open pipe: \$!\\n");
		print PIPE "\$\$:\$ENV{WINDOWID}" 
			or die("Failed to write to pipe: $!\\n");
		close(PIPE) or die("Failed to close pipe: $!\\n");
		if(\$svr =~ m/==\$/)
		{
			\$svr =~ s/==\$//;
			warn("\\nWARNING: failed to resolve IP address for \$svr.\\n\\n"
			);
			sleep 5;
		}
		if(\$user) {
			unless("$config{comms}" eq "telnet") {
				\$user = \$user ? "-l \$user " : "";
				\$command .= \$user;
			}
		}
		if($config{comms} eq "telnet") {
			\$port = \$port ? "\$port" : "$defaultport";
			\$command .= "\$svr \$port";
		} else {
      if ((\$port) || ("$defaultport" ne "")) {
			  \$port = \$port ? "-p \$port" : "-p $defaultport";
			  \$command .= "\$port \$svr";
      } else {
			  \$command .= "\$svr";
      }
		}
		\$command .= " || sleep 5";
#		warn("Running:\$command\\n"); # for debug purposes
		exec(\$command);
	HERE

    #	eval $helper_script || die ($@); # for debug purposes
    logmsg( 2, $helper_script );
    logmsg( 2, "Helper script done" );
}

sub check_host($) {
    my $host = shift;
    if ( $host =~ m/^(\d{1,3}\.?){4}$/ ) {
        logmsg( 2, "Not resolving IP address '$host'" );
        return 1;
    }
    if ( $config{method} eq "ssh" ) {
        logmsg( 1, "Attempting name resolution via user ssh config file" );
        if ( $ssh_hostnames{$host} ) {
            return 1;
        }
        else {
            logmsg( 1,
                "Failed to check host (falling back to gethostbyname): $!" );
            return gethostbyname($host);
        }
    }
    else {
        return gethostbyname($host);
    }
}

sub open_client_windows(@) {
    foreach (@_) {
        next unless ($_);

        my $username = "";
        $username = $config{user} if ( $config{user} );

        my $port_nb;

        # split off any provided hostname and port
        if ( $_ =~ s/^(.*)@// ) {
            $username = $1;
        }
        if ( $_ =~ s/:(\w+)$// ) {
            $port_nb = $1;
        }

        my $count  = 1;
        my $server = $_;

        while ( defined( $servers{$server} ) ) {
            $server = $_ . " " . $count++;
        }

        # see if we can find the hostname - if not, drop it
        my $gethost = check_host($_);
        if ( !$gethost ) {
            my $text = "WARNING: '$_' unknown";

            if (%ssh_hostnames) {
                $text
                    .= " (unable to resolve and not in user ssh config file)";
            }

            warn( $text, $/ );

       #next;  # Debian bug 499935 - ignore warnings about hostname resolution
        }

        my $color = '';
        if ( $config{terminal_colorize} ) {
            my $c = pick_color($server);
            if ( $config{terminal_bg_style} eq 'dark' ) {
                $color = "-bg \\#000000 -fg $c";
            }
            else {
                $color = "-fg \\#000000 -bg $c";
            }
        }

        $servers{$server}{realname} = $_;
        $servers{$server}{username} = $username;
        $servers{$server}{port_nb}  = $port_nb || '';

        logmsg( 2, "Working on server $server for $_" );

        $servers{$server}{pipenm} = tmpnam();

        logmsg( 2, "Set temp name to: $servers{$server}{pipenm}" );
        mkfifo( $servers{$server}{pipenm}, 0600 )
            or die("Cannot create pipe: $!");

       # NOTE: the pid is re-fetched from the xterm window (via helper_script)
       # later as it changes and we need an accurate PID as it is widely used
        $servers{$server}{pid} = fork();
        if ( !defined( $servers{$server}{pid} ) ) {
            die("Could not fork: $!");
        }

        if ( $servers{$server}{pid} == 0 ) {

          # this is the child
          # Since this is the child, we can mark any server unresolved without
          # affecting the main program
            $servers{$server}{realname} .= "==" if ( !$gethost );
            my $exec
                = "$config{terminal} $color $config{terminal_args} $config{terminal_allow_send_events} $config{terminal_title_opt} '$config{title}:$server' -font $config{terminal_font} -e \"$^X\" \"-e\" '$helper_script' '$servers{$server}{pipenm}' '$servers{$server}{realname}' '$servers{$server}{username}' '$servers{$server}{port_nb}'";
            logmsg( 2, "Terminal exec line:\n$exec\n" );
            exec($exec) == 0 or warn("Failed: $!");
        }
    }

    # Now all the windows are open, get all their window id's
    foreach my $server ( keys(%servers) ) {
        next if ( defined( $servers{$server}{active} ) );

        # sleep for a moment to give system time to come up
        select( undef, undef, undef, 0.1 );

        # block on open so we get the text when it comes in
        unless (
            sysopen(
                $servers{$server}{pipehl}, $servers{$server}{pipenm},
                O_RDONLY
            )
            )
        {
            warn(
                "Cannot open pipe for reading when talking to $server: $!\n");
        }
        else {

            # NOTE: read both the xterm pid and the window ID here
            # get PID here as it changes from the fork above, and we need the
            # correct PID
            logmsg( 2, "Performing sysread" );
            my $piperead;
            sysread( $servers{$server}{pipehl}, $piperead, 100 );
            ( $servers{$server}{pid}, $servers{$server}{wid} )
                = split( /:/, $piperead, 2 );
            warn("Cannot determ pid of '$server' window\n")
                unless $servers{$server}{pid};
            warn("Cannot determ window ID of '$server' window\n")
                unless $servers{$server}{wid};
            logmsg( 2, "Done and closing pipe" );

            close( $servers{$server}{pipehl} );
        }
        delete( $servers{$server}{pipehl} );

        unlink( $servers{$server}{pipenm} );
        delete( $servers{$server}{pipenm} );

        $servers{$server}{active} = 1;    # mark as active
        $config{internal_activate_autoquit}
            = 1;                          # activate auto_quit if in use
    }
    logmsg( 2, "All client windows opened" );
    $config{internal_total} = int( keys(%servers) );
}

sub get_font_size() {
    logmsg( 2, "Fetching font size" );

    # get atom name<->number relations
    my $quad_width = $xdisplay->atom("QUAD_WIDTH");
    my $pixel_size = $xdisplay->atom("PIXEL_SIZE");

    my $font = $xdisplay->new_rsrc;
    $xdisplay->OpenFont( $font, $config{terminal_font} );

    my %font_info;

    eval { (%font_info) = $xdisplay->QueryFont($font); }
        || die( "Fatal: Unrecognised font used ($config{terminal_font}).\n"
            . "Please amend \$HOME/.csshrc with a valid font (see man page).\n"
        );

    $config{internal_font_width}  = $font_info{properties}{$quad_width};
    $config{internal_font_height} = $font_info{properties}{$pixel_size};

    if ( !$config{internal_font_width} || !$config{internal_font_height} ) {
        die(      "Fatal: Unrecognised font used ($config{terminal_font}).\n"
                . "Please amend \$HOME/.csshrc with a valid font (see man page).\n"
        );
    }

    logmsg( 2, "Done with font size" );
}

sub show_console() {
    logmsg( 2, "Sending console to front" );

    $config{internal_previous_state} = "mid-change";

    # fudge the counter to drop a redraw event;
    $config{internal_map_count} -= 4;

    $xdisplay->flush();
    $windows{main_window}->update();

    select( undef, undef, undef, 0.2 );    #sleep for a mo
    $windows{main_window}->withdraw;

    # Sleep for a moment to give WM time to bring console back
    select( undef, undef, undef, 0.5 );
    $windows{main_window}->deiconify;
    $windows{main_window}->raise;
    $windows{main_window}->focus( -force );
    $windows{text_entry}->focus( -force );

    $config{internal_previous_state} = "normal";

    # fvwm seems to need this (Debian #329440)
    $windows{main_window}->MapWindow;
}

# leave function def open here so we can be flexible in how it called
sub retile_hosts {
    my $force = shift || "";
    logmsg( 2, "Retiling windows" );

    if ( $config{window_tiling} ne "yes" && !$force ) {
        logmsg( 3,
            "Not meant to be tiling; just reshow windows as they were" );

        foreach my $server ( reverse( keys(%servers) ) ) {
            $xdisplay->req( 'MapWindow', $servers{$server}{wid} );
        }
        $xdisplay->flush();
        show_console();
        return;
    }

    # ALL SIZES SHOULD BE IN PIXELS for consistency

    logmsg( 2, "Count is currently $config{internal_total}" );

    if ( $config{internal_total} == 0 ) {

        # If nothing to tile, done bother doing anything, just show console
        show_console();
        return;
    }

    # work out terminal pixel size from terminal size & font size
    # does not include any title bars or scroll bars - purely text area
    $config{internal_terminal_cols}
        = ( $config{terminal_size} =~ /(\d+)x.*/ )[0];
    $config{internal_terminal_width}
        = ( $config{internal_terminal_cols} * $config{internal_font_width} )
        + $config{terminal_decoration_width};

    $config{internal_terminal_rows}
        = ( $config{terminal_size} =~ /.*x(\d+)/ )[0];
    $config{internal_terminal_height}
        = ( $config{internal_terminal_rows} * $config{internal_font_height} )
        + $config{terminal_decoration_height};

    # fetch screen size
    $config{internal_screen_height} = $xdisplay->{height_in_pixels};
    $config{internal_screen_width}  = $xdisplay->{width_in_pixels};

    # Now, work out how many columns of terminals we can fit on screen
    $config{internal_columns} = int(
        (         $config{internal_screen_width} 
                - $config{screen_reserve_left}
                - $config{screen_reserve_right}
        ) / (
            $config{internal_terminal_width} 
                + $config{terminal_reserve_left}
                + $config{terminal_reserve_right}
        )
    );

    # Work out the number of rows we need to use to fit everything on screen
    $config{internal_rows} = int(
        ( $config{internal_total} / $config{internal_columns} ) + 0.999 );

    logmsg( 2, "Screen Columns: ", $config{internal_columns} );
    logmsg( 2, "Screen Rows: ",    $config{internal_rows} );

    # Now adjust the height of the terminal to either the max given,
    # or to get everything on screen
    {
        my $height = int(
            (   (         $config{internal_screen_height}
                        - $config{screen_reserve_top}
                        - $config{screen_reserve_bottom}
                ) - (
                    $config{internal_rows} * (
                              $config{terminal_reserve_top}
                            + $config{terminal_reserve_bottom}
                    )
                )
            ) / $config{internal_rows}
        );

        logmsg( 2, "Terminal height=$height" );

        $config{internal_terminal_height} = (
              $height > $config{internal_terminal_height}
            ? $config{internal_terminal_height}
            : $height
        );
    }

    #dump_config("noexit") if($debug > 1);

    # now we have the info, plot first window position
    my @hosts;
    my ( $current_x, $current_y, $current_row, $current_col ) = 0;
    if ( $config{window_tiling_direction} =~ /right/i ) {
        logmsg( 2, "Tiling top left going bot right" );
        @hosts = sort( keys(%servers) );
        $current_x
            = $config{screen_reserve_left} + $config{terminal_reserve_left};
        $current_y
            = $config{screen_reserve_top} + $config{terminal_reserve_top};
        $current_row = 0;
        $current_col = 0;
    }
    else {
        logmsg( 2, "Tiling bot right going top left" );
        @hosts = reverse( sort( keys(%servers) ) );
        $current_x
            = $config{screen_reserve_right} 
            - $config{internal_screen_width}
            - $config{terminal_reserve_right}
            - $config{internal_terminal_width};
        $current_y
            = $config{screen_reserve_bottom} 
            - $config{internal_screen_height}
            - $config{terminal_reserve_bottom}
            - $config{internal_terminal_height};

        $current_row = $config{internal_rows} - 1;
        $current_col = $config{internal_columns} - 1;
    }

    # Unmap windows (hide them)
    # Move windows to new locatation
    # Remap all windows in correct order
    foreach my $server (@hosts) {
        logmsg( 3,
            "x:$current_x y:$current_y, r:$current_row c:$current_col" );

        $xdisplay->req( 'UnmapWindow', $servers{$server}{wid} );

        if ( $config{unmap_on_redraw} =~ /yes/i ) {
            $xdisplay->req( 'UnmapWindow', $servers{$server}{wid} );
        }

        logmsg( 2, "Moving $server window" );
        send_resizemove(
            $servers{$server}{wid},
            $current_x, $current_y,
            $config{internal_terminal_width},
            $config{internal_terminal_height}
        );

        $xdisplay->flush();
        select( undef, undef, undef, 0.1 );    # sleep for a moment for the WM

        if ( $config{window_tiling_direction} =~ /right/i ) {

            # starting top left, and move right and down
            $current_x
                += $config{terminal_reserve_left}
                + $config{terminal_reserve_right}
                + $config{internal_terminal_width};

            $current_col += 1;
            if ( $current_col == $config{internal_columns} ) {
                $current_y
                    += $config{terminal_reserve_top}
                    + $config{terminal_reserve_bottom}
                    + $config{internal_terminal_height};
                $current_x = $config{screen_reserve_left}
                    + $config{terminal_reserve_left};
                $current_row++;
                $current_col = 0;
            }
        }
        else {

            # starting bottom right, and move left and up

            $current_col -= 1;
            if ( $current_col < 0 ) {
                $current_row--;
                $current_col = $config{internal_columns};
            }
        }
    }

    # Now remap in right order to get overlaps correct
    if ( $config{window_tiling_direction} =~ /right/i ) {
        foreach my $server ( reverse(@hosts) ) {
            logmsg( 2, "Setting focus on $server" );
            $xdisplay->req( 'MapWindow', $servers{$server}{wid} );

            # flush every time and wait a moment (The WMs are so slow...)
            $xdisplay->flush();
            select( undef, undef, undef, 0.1 );    # sleep for a mo
        }
    }
    else {
        foreach my $server (@hosts) {
            logmsg( 2, "Setting focus on $server" );
            $xdisplay->req( 'MapWindow', $servers{$server}{wid} );

            # flush every time and wait a moment (The WMs are so slow...)
            $xdisplay->flush();
            select( undef, undef, undef, 0.1 );    # sleep for a mo
        }
    }

    # and as a last item, set focus back onto the console
    show_console();
}

sub capture_terminal() {
    logmsg( 0, "Stub for capturing a terminal window" );

    return if ( $debug < 6 );

    # should never see this - all experimental anyhow

    foreach my $server ( keys(%servers) ) {
        foreach my $data ( keys( %{ $servers{$server} } ) ) {
            print "server $server key $data is $servers{$server}{$data}\n";
        }
    }

    #return;

    my %atoms;

    for my $atom ( $xdisplay->req( 'ListProperties', $servers{loki}{wid} ) ) {
        $atoms{ $xdisplay->atom_name($atom) }
            = $xdisplay->req( 'GetProperty', $servers{loki}{wid},
            $atom, "AnyPropertyType", 0, 200, 0 );

        print $xdisplay->atom_name($atom), " ($atom) => ";
        print "join here\n";
        print join(
            "\n",
            $xdisplay->req(
                'GetProperty', $servers{loki}{wid},
                $atom, "AnyPropertyType", 0, 200, 0
            )
            ),
            "\n";
    }

    print "list by number\n";
    for my $atom ( 1 .. 90 ) {
        print "$atom: ", $xdisplay->req( 'GetAtomName', $atom ), "\n";
        print join(
            "\n",
            $xdisplay->req(
                'GetProperty', $servers{loki}{wid},
                $atom, "AnyPropertyType", 0, 200, 0
            )
            ),
            "\n";
    }
    print "\n";

    print "size hints\n";
    print join(
        "\n",
        $xdisplay->req(
            'GetProperty', $servers{loki}{wid},
            42, "AnyPropertyType", 0, 200, 0
        )
        ),
        "\n";

    print "atom list by name\n";
    foreach ( keys(%atoms) ) {
        print "atom :$_: = $atoms{$_}\n";
    }

    print "geom\n";
    print join " ", $xdisplay->req( 'GetGeometry', $servers{loki}{wid} ), $/;
    print "attrib\n";
    print join " ",
        $xdisplay->req( 'GetWindowAttributes', $servers{loki}{wid} ),
        $/;
}

sub toggle_active_state() {
    logmsg( 2, "Toggling active state of all hosts" );

    foreach my $svr ( sort( keys(%servers) ) ) {
        $servers{$svr}{active} = not $servers{$svr}{active};
    }
}

sub close_inactive_sessions() {
    logmsg( 2, "Closing all inactive sessions" );

    foreach my $svr ( sort( keys(%servers) ) ) {
        terminate_host($svr) if ( !$servers{$svr}{active} );
    }
    build_hosts_menu();
}

sub add_host_by_name() {
    logmsg( 2, "Adding host to menu here" );

    $windows{host_entry}->focus();
    my $answer = $windows{addhost}->Show();

    if ( $answer ne "Add" ) {
        $menus{host_entry} = "";
        return;
    }

    logmsg( 2, "host=$menus{host_entry}" );

    open_client_windows(
        resolve_names( split( /\s+/, $menus{host_entry} ) ) );

    build_hosts_menu();
    $menus{host_entry} = "";

    # retile, or bring console to front
    if ( $config{window_tiling} eq "yes" ) {
        retile_hosts();
    }
    else {
        show_console();
    }
}

sub build_hosts_menu() {
    logmsg( 2, "Building hosts menu" );

    # first, empty the hosts menu from the 4th entry on
    my $menu = $menus{bar}->entrycget( 'Hosts', -menu );
    $menu->delete( 6, 'end' );

    logmsg( 3, "Menu deleted" );

    # add back the seperator
    $menus{hosts}->separator;

    logmsg( 3, "Parsing list" );
    foreach my $svr ( sort( keys(%servers) ) ) {
        logmsg( 3, "Checking $svr and restoring active value" );
        $menus{hosts}->checkbutton(
            -label    => $svr,
            -variable => \$servers{$svr}{active},
        );
    }
    logmsg( 3, "Changing window title" );
    change_main_window_title();
    logmsg( 2, "Done" );
}

sub setup_repeat() {
    $config{internal_count} = 0;

    # if this is too fast then we end up with queued invocations
    # with no time to run anything else
    $windows{main_window}->repeat(
        500,
        sub {
            $config{internal_count} = 0
                if ( $config{internal_count} > 60000 );    # reset if too high
            $config{internal_count}++;
            my $build_menu = 0;
            logmsg( 4, "Running repeat (count=$config{internal_count})" );

     #logmsg( 4, "Number of servers in hash is: ", scalar( keys(%servers) ) );

            foreach my $svr ( keys(%servers) ) {
                if ( defined( $servers{$svr}{pid} ) ) {
                    if ( !kill( 0, $servers{$svr}{pid} ) ) {
                        $build_menu = 1;
                        delete( $servers{$svr} );
                        logmsg( 0, "$svr session closed" );
                    }
                }
                else {
                    warn("Lost pid of $svr; deleting\n");
                    delete( $servers{$svr} );
                }
            }

            # get current number of clients
            $config{internal_total} = int( keys(%servers) );

            #logmsg( 4, "Number after tidy is: ", $config{internal_total} );

            # get current number of clients
            $config{internal_total} = int( keys(%servers) );

            #logmsg( 4, "Number after tidy is: ", $config{internal_total} );

            # If there are no hosts in the list and we are set to autoquit
            if (   $config{internal_total} == 0
                && $config{auto_quit} =~ /yes/i )
            {

                # and some clients were actually opened...
                if ( $config{internal_activate_autoquit} ) {
                    logmsg( 2, "Autoquitting" );
                    exit_prog;
                }
            }

            # rebuild host menu if something has changed
            build_hosts_menu() if ($build_menu);

            # clean out text area, anyhow
            $menus{entrytext} = "";

            #logmsg( 4, "repeat completed" );
        }
    );
    logmsg( 2, "Repeat setup" );
}

sub write_default_user_config() {
    return if ( !$ENV{HOME} || -e "$ENV{HOME}/.csshrc" );

    if ( open( CONFIG, ">", "$ENV{HOME}/.csshrc" ) ) {
        foreach ( sort( keys(%config) ) ) {

            # do not output internal vars
            next if ( $_ =~ /^internal/ );
            print CONFIG "$_=$config{$_}\n";
        }
        close(CONFIG);
    }
    else {
        logmsg( 1, "Unable to write default $ENV{HOME}/.csshrc file" );
    }
}

### Window and menu definitions ###

sub create_windows() {
    logmsg( 2, "create_windows: started" );
    $windows{main_window} = MainWindow->new( -title => "ClusterSSH" );
    $windows{main_window}->withdraw;    # leave withdrawn until needed

    if ( defined( $config{console_position} )
        && $config{console_position} =~ /[+-]\d+[+-]\d+/ )
    {
        $windows{main_window}->geometry( $config{console_position} );
    }

    $menus{entrytext}    = "";
    $windows{text_entry} = $windows{main_window}->Entry(
        -textvariable      => \$menus{entrytext},
        -insertborderwidth => 4,
        -width             => 25,
        )->pack(
        -fill   => "x",
        -expand => 1,
        );

    $windows{history} = $windows{main_window}->Scrolled(
        "ROText",
        -insertborderwidth => 4,
        -width             => $config{history_width},
        -height            => $config{history_height},
        -state             => 'normal',
        -takefocus         => 0,
    );
    $windows{history}->bindtags(undef);

    if ( $config{show_history} ) {
        $windows{history}->pack(
            -fill   => "x",
            -expand => 1,
        );
    }

    $windows{main_window}->bind( '<Destroy>' => \&exit_prog );

    # remove all Paste events so we set them up cleanly
    $windows{main_window}->eventDelete('<<Paste>>');

    # Set up paste events from scratch
    if ( $config{key_paste} && $config{key_paste} ne "null" ) {
        $windows{main_window}
            ->eventAdd( '<<Paste>>' => '<' . $config{key_paste} . '>' );
    }

    if ( $config{mouse_paste} && $config{mouse_paste} ne "null" ) {
        $windows{main_window}
            ->eventAdd( '<<Paste>>' => '<' . $config{mouse_paste} . '>' );
    }

    $windows{main_window}->bind(
        '<<Paste>>' => sub {
            logmsg( 2, "PASTE EVENT" );

            $menus{entrytext} = "";
            my $paste_text = '';

            # SelectionGet is fatal if no selection is given
            Tk::catch { $paste_text = $windows{main_window}->SelectionGet };

            if ( !length($paste_text) ) {
                warn("Got empty paste event\n");
                return;
            }

            logmsg( 2, "Got text :", $paste_text, ":" );

            update_display_text($paste_text);

            # now sent it on
            foreach my $svr ( keys(%servers) ) {
                send_text( $svr, $paste_text )
                    if ( $servers{$svr}{active} == 1 );
            }
        }
    );

    $windows{help} = $windows{main_window}->Dialog(
        -popover    => $windows{main_window},
        -overanchor => "c",
        -popanchor  => "c",
        -font       => [
            -family => "interface system",
            -size   => 10,
        ],
        -text =>
            "Cluster Administrator Console using SSH\n\nVersion: $VERSION.\n\n"
            . "Bug/Suggestions to http://clusterssh.sf.net/",
    );

    $windows{manpage} = $windows{main_window}->DialogBox(
        -popanchor  => "c",
        -overanchor => "c",
        -title      => "Cssh Documentation",
        -buttons    => ['Close'],
    );

    my $manpage = `pod2text -l -q=\"\" $0`;
    $windows{mantext}
        = $windows{manpage}->Scrolled( "Text", )->pack( -fill => 'both' );
    $windows{mantext}->insert( 'end', $manpage );
    $windows{mantext}->configure( -state => 'disabled' );

    $windows{addhost} = $windows{main_window}->DialogBox(
        -popover        => $windows{main_window},
        -popanchor      => 'n',
        -title          => "Add Host(s) or Cluster(s)",
        -buttons        => [ 'Add', 'Cancel' ],
        -default_button => 'Add',
    );

    $windows{host_entry} = $windows{addhost}->add(
        'LabEntry',
        -textvariable => \$menus{host_entry},
        -width        => 20,
        -label        => 'Host',
        -labelPack    => [ -side => 'left', ],
    )->pack( -side => 'left' );
    logmsg( 2, "create_windows: completed" );
}

sub capture_map_events() {

    # pick up on console minimise/maximise events so we can do all windows
    $windows{main_window}->bind(
        '<Map>' => sub {
            logmsg( 3, "Entering MAP" );

            my $state = $windows{main_window}->state();
            logmsg( 3,
                "state=$state previous=$config{internal_previous_state}" );
            logmsg( 3, "Entering MAP" );

            if ( $config{internal_previous_state} eq $state ) {
                logmsg( 3, "repeating the same" );
            }

            if ( $config{internal_previous_state} eq "mid-change" ) {
                logmsg( 3, "dropping out as mid-change" );
                return;
            }

            logmsg( 3,
                "state=$state previous=$config{internal_previous_state}" );

            if ( $config{internal_previous_state} eq "iconic" ) {
                logmsg( 3, "running retile" );

                retile_hosts();

                logmsg( 3, "done with retile" );
            }

            if ( $config{internal_previous_state} ne $state ) {
                logmsg( 3, "resetting prev_state" );
                $config{internal_previous_state} = $state;
            }
        }
    );

    $windows{main_window}->bind(
        '<Unmap>' => sub {
            logmsg( 3, "Entering UNMAP" );

            my $state = $windows{main_window}->state();
            logmsg( 3,
                "state=$state previous=$config{internal_previous_state}" );

            if ( $config{internal_previous_state} eq $state ) {
                logmsg( 3, "repeating the same" );
            }

            if ( $config{internal_previous_state} eq "mid-change" ) {
                logmsg( 3, "dropping out as mid-change" );
                return;
            }

            if ( $config{internal_previous_state} eq "normal" ) {
                logmsg( 3, "withdrawing all windows" );
                foreach my $server ( reverse( keys(%servers) ) ) {
                    $xdisplay->req( 'UnmapWindow', $servers{$server}{wid} );
                    if ( $config{unmap_on_redraw} =~ /yes/i ) {
                        $xdisplay->req( 'UnmapWindow',
                            $servers{$server}{wid} );
                    }
                }
                $xdisplay->flush();
            }

            if ( $config{internal_previous_state} ne $state ) {
                logmsg( 3, "resetting prev_state" );
                $config{internal_previous_state} = $state;
            }
        }
    );
}

# for all key event, event hotkeys so there is only 1 key binding
sub key_event {
    my $event     = $Tk::event->T;
    my $keycode   = $Tk::event->k;
    my $keysymdec = $Tk::event->N;
    my $keysym    = $Tk::event->K;
    my $state     = $Tk::event->s || 0;

    $menus{entrytext} = "";

    logmsg( 3, "=========" );
    logmsg( 3, "event    =$event" );
    logmsg( 3, "keysym   =$keysym (state=$state)" );
    logmsg( 3, "keysymdec=$keysymdec" );
    logmsg( 3, "keycode  =$keycode" );
    logmsg( 3, "state    =$state" );
    logmsg( 3, "codetosym=$keycodetosym{$keysymdec}" )
        if ( $keycodetosym{$keysymdec} );
    logmsg( 3, "symtocode=$keysymtocode{$keysym}" );
    logmsg( 3, "keyboard =$keyboardmap{ $keysym }" )
        if ( $keyboardmap{$keysym} );

    #warn("debug stop point here");
    if ( $config{use_hotkeys} eq "yes" ) {
        my $combo = $Tk::event->s . $Tk::event->K;

        $combo =~ s/Mod\d-//;

        logmsg( 3, "combo=$combo" );

        foreach my $hotkey ( grep( /key_/, keys(%config) ) ) {
            my $key = $config{$hotkey};
            next if ( $key eq "null" );    # ignore disabled keys

            logmsg( 3, "key=:$key:" );
            logmsg( 3, "combo=$combo" );
            if ( $combo =~ /^$key$/ ) {
                if ( $event eq "KeyRelease" ) {
                    logmsg( 2, "Received hotkey: $hotkey" );
                    send_clientname()     if ( $hotkey eq "key_clientname" );
                    add_host_by_name()    if ( $hotkey eq "key_addhost" );
                    retile_hosts("force") if ( $hotkey eq "key_retilehosts" );
                    show_history()        if ( $hotkey eq "key_history" );
                    exit_prog()           if ( $hotkey eq "key_quit" );
                }
                return;
            }
        }
    }

    # look for a <Control>-d and no hosts, so quit
    exit_prog() if ( $state =~ /Control/ && $keysym eq "d" and !%servers );

    update_display_text( $keycodetosym{$keysymdec} )
        if ( $event eq "KeyPress" && $keycodetosym{$keysymdec} );

    # for all servers
    foreach ( keys(%servers) ) {

        # if active
        if ( $servers{$_}{active} == 1 ) {
            logmsg( 3,
                "Sending event $event with code $keycode (state=$state) to window $servers{$_}{wid}"
            );

            $xdisplay->SendEvent(
                $servers{$_}{wid},
                0,
                $xdisplay->pack_event_mask($event),
                $xdisplay->pack_event(
                    'name'        => $event,
                    'detail'      => $keycode,
                    'state'       => $state,
                    'time'        => time(),
                    'event'       => $servers{$_}{wid},
                    'root'        => $xdisplay->root(),
                    'same_screen' => 1,
                )
            ) || warn("Error returned from SendEvent: $!");
        }
    }
    $xdisplay->flush();
}

sub create_menubar() {
    logmsg( 2, "create_menubar: started" );
    $menus{bar} = $windows{main_window}->Menu;
    $windows{main_window}->configure( -menu => $menus{bar} );

    $menus{file} = $menus{bar}->cascade(
        -label     => 'File',
        -menuitems => [
            [   "command",
                "Show History",
                -command     => \&show_history,
                -accelerator => $config{key_history},
            ],
            [   "command",
                "Exit",
                -command     => \&exit_prog,
                -accelerator => $config{key_quit},
            ]
        ],
        -tearoff => 0,
    );

    $menus{hosts} = $menus{bar}->cascade(
        -label     => 'Hosts',
        -tearoff   => 1,
        -menuitems => [
            [   "command",
                "Retile Windows",
                -command     => \&retile_hosts,
                -accelerator => $config{key_retilehosts},
            ],

#         [ "command", "Capture Terminal",    -command => \&capture_terminal, ],
            [   "command",
                "Toggle active state",
                -command => \&toggle_active_state,
            ],
            [   "command",
                "Close inactive sessions",
                -command => \&close_inactive_sessions,
            ],
            [   "command",
                "Add Host(s) or Cluster(s)",
                -command     => \&add_host_by_name,
                -accelerator => $config{key_addhost},
            ],
            '',
        ],
    );

    $menus{send} = $menus{bar}->cascade(
        -label     => 'Send',
        -menuitems => [
            [   "command",
                "Hostname",
                -command     => \&send_clientname,
                -accelerator => $config{key_clientname},
            ],
        ],
        -tearoff => 1,
    );

    $menus{help} = $menus{bar}->cascade(
        -label     => 'Help',
        -menuitems => [
            [ 'command', "About", -command => sub { $windows{help}->Show } ],
            [   'command', "Documentation",
                -command => sub { $windows{manpage}->Show }
            ],
        ],
        -tearoff => 0,
    );

    #$windows{main_window}->bind(
    #'<Key>' => \&key_event,
    #);
    $windows{main_window}->bind( '<KeyPress>'   => \&key_event, );
    $windows{main_window}->bind( '<KeyRelease>' => \&key_event, );
    logmsg( 2, "create_menubar: completed" );
}

### main ###

# Note: getopts returned "" if it finds any options it doesnt recognise
# so use this to print out basic help
pod2usage( -verbose => 1 ) unless ( getopts( $options, \%options ) );
pod2usage( -verbose => 1 ) if ( $options{'?'} || $options{h} );
pod2usage( -verbose => 2 ) if ( $options{H} );

if ( $options{v} ) {
    print "Version: $VERSION\n";
    exit 0;
}

# only get xdisplay if we got past usage and help stuff
$xdisplay = X11::Protocol->new();

if ( !$xdisplay ) {
    die("Failed to get X connection\n");
}

# catch and reap any zombies
sub REAPER {
    my $kid;
    do {
        $kid = waitpid( -1, WNOHANG );
        logmsg( 2, "REAPER currently returns: $kid" );
    } until ( $kid == -1 || $kid == 0 );
}
$SIG{CHLD} = \&REAPER;

$debug += 1 if ( $options{d} );
$debug += 2 if ( $options{D} );

#warn("forcing high debug\n"); $debug +=4;

logmsg( 2, "VERSION: $VERSION" );

load_config_defaults();
load_configfile();
dump_config() if ( $options{u} );

check_ssh_hostnames();

evaluate_commands() if ( $options{e} );

load_keyboard_map();

get_clusters();

@servers = resolve_names(@ARGV);

create_windows();
create_menubar();

change_main_window_title();

logmsg( 2, "Capture map events" );
capture_map_events();

setup_helper_script();
open_client_windows(@servers);

# Check here if we are tiling windows.  Here instead of in func so
# can be tiled from console window if wanted
if ( $config{window_tiling} eq "yes" ) {
    retile_hosts();
}
else {
    show_console();
}

build_hosts_menu();

logmsg( 2, "Sleeping for a mo" );
select( undef, undef, undef, 0.5 );

logmsg( 2, "Sorting focus on console" );
$windows{text_entry}->focus();

logmsg( 2, "Marking main window as user positioned" );
$windows{main_window}->positionfrom('user')
    ;    # user puts it somewhere, leave it there

logmsg( 2, "Setting up repeat" );
setup_repeat();

logmsg( 2, "Writing default user configuration" );
write_default_user_config();

# Start event loop
logmsg( 2, "Starting MainLoop" );
MainLoop();

# make sure we leave program in an expected way
exit_prog();

# man/perldoc/pod page
__END__

=pod

=head1 NAME

cssh, crsh, ctel - Cluster administration tool

=head1 SYNOPSIS

S<< cssh [options] [[user@]<server>|<tag>] [...] >>
S<< crsh [options] [[user@]<server>|<tag>] [...] >>
S<< cssh [options] [[user@]<server>[:port]|<tag>] [...] >>
S<< crsh [options] [[user@]<server>[:port]|<tag>] [...] >>
S<< ctel [options] [<server>|<tag>] [...] >>
S<< ctel [options] [<server>|<tag>] [...] >>

=head1 DESCRIPTION

The command opens an administration console and an xterm to all specified 
hosts.  Any text typed into the administration console is replicated to 
all windows.  All windows may also be typed into directly.

This tool is intended for (but not limited to) cluster administration where
the same configuration or commands must be run on each node within the
cluster.  Performing these commands all at once via this tool ensures all
nodes are kept in sync.

Connections are opened via ssh so a correctly installed and configured
ssh installation is required.  If, however, the program is called by "crsh"
then the rsh protocol is used (and the communications channel is insecure),
or by "ctel" then telnet is used.

Extra caution should be taken when editing system files such as
/etc/inet/hosts as lines may not necessarily be in the same order.  Assuming
line 5 is the same across all servers and modifying that is dangerous.
Better to search for the specific line to be changed and double-check before
changes are committed.

=head2 Further Notes

=over

=item *

The dotted line on any sub-menu is a tear-off, i.e. click on it
and the sub-menu is turned into its own window.

=item *

Unchecking a hostname on the Hosts sub-menu will unplug the host from the
cluster control window, so any text typed into the console is not sent to
that host.  Re-selecting it will plug it back in.

=item *

If the code is called as crsh instead of cssh (i.e. a symlink called
crsh points to the cssh file or the file is renamed) rsh is used as the
communications protocol instead of ssh.

=item *

If the code is called as ctel instead of cssh (i.e. a symlink called
ctel points to the cssh file or the file is renamed) telnet is used as the
communications protocol instead of ssh.

=item *

When using cssh on a large number of systems to connect back to a single
system (e.g. you issue a command to the cluster to scp a file from a given
location) and when these connections require authentication (i.e. you are
going to authenticate with a password), the sshd daemon at that location 
may refuse connects after the number specified by MaxStartups in 
sshd_config is exceeded.  (If this value is not set, it defaults to 10.)
This is expected behavior; sshd uses this mechanism to prevent DoS attacks
from unauthenticated sources.  Please tune sshd_config and reload the SSH
daemon, or consider using the ~/.ssh/authorized_keys mechanism for 
authentication if you encounter this problem.

=item *

If client windows fail to open, try running:

C<< cssh -e {single host name} >>

This will test the mechanisms used to open windows to hosts.  This could 
be due to either the C<-xrm> terminal option which enables C<AllowSendEvents> 
(some terminal do not require this option, other terminals have another 
method for enabling it - see your terminal documention) or the 
C<ConnectTimeout> ssh option (see the configuration option C<-o> or file 
C<csshrc> below to resolve this).

=back

=head1 OPTIONS

Some of these options may also be defined within the configuration file. 
Default options are shown as appropriate.

=over

=item -c <file>

Use supplied file as additional cluster file (see also L<"FILES">)

=item -C <file>

Use supplied file as additional configuration file (see also L<"FILES">)

=item -d 

Enable basic debugging mode (can be combined with -D)

=item -D 

Enable extended debugging mode (can be combined with -d)

=item -e [user@]<hostname>[:port]

Display and evaluate the terminal and connection arguments so display any
potential errors.  The <hostname> is required to aid the evaluation.  

=item -g|-G 

Enable|Disable window tiling (overriding the config file)

=item -h|-?

Show basic help text, and exit

=item -H

Show full help test (the man page), and exit

=item -i

THIS OPTION IS DEPRECATED.  It has been left in so current systems continue 
to function as expected.

=item -l $LOGNAME

Specify the default username to use for connections (if different from the
currently logged in user).  B<NOTE:> will be overridden by <user>@<host>

=item -o "-x -o ConnectTimeout=10" - for ssh connections

=item -o ""                        - for rsh connections

Specify arguments to be passed to ssh or rsh when making the connection.  

B<NOTE:> any "generic" change to the method (i.e. specifying the ssh port to use)
should be done in the medium's own config file (see L<ssh_config> and 
F<$HOME/.ssh/config>).

=item -p <port>

Specify an alternate port for connections.

=item -q|-Q

Enable|Disable automatically quiting after the last client window has closed
(overriding the config file)

=item -s

IN BETA: Show history within console window.  This code is still being 
worked upon, but may help some users.

=item -t ""

Specify arguments to be passed to terminals being used

=item -T "CSSH"

Specify the initial part of the title used in the console and client windows

=item -u

Output the current configuration in the same format used by the 
F<$HOME/.csshrc> file.

=item -v

Show version information and exit

=back

=head1 ARGUMENTS

The following arguments are support:

=over

=item [user@]<hostname>[:port] ...

Open an xterm to the given hostname and connect to the administration
console.  An optional port number can be used if sshd is not listening
on standard port (e.g not listening on port 22) and ssh_config cannot be used.

=item <tag> ...

Open a series of xterms defined by <tag> within either /etc/clusters or
F<$HOME/.csshrc> (see L<"FILES">).

=back

=head1 KEY SHORTCUTS

The following key shortcuts are available within the console window, and all
of them may be changed via the configuration files.

=over

=item Control-q

Quit the program and close all connections and windows

=item Control-+

Open the 'Add Host(s) or Cluster(s)' dialogue box.  Mutiple host or cluster names 
can be entered, separated by spaces.

=item Alt-n

Paste in the correct client name to all clients, i.e.

C<< scp /etc/hosts server:files/<Alt-n>.hosts >>

would replace the <Alt-n> with the client's name in all the client windows

=item Alt-r

Retile all the client windows

=back

=head1 EXAMPLES

=over

=item Open up a session to 3 servers

S<$ cssh server1 server2 server3>

=item Open up a session to a cluster of servers identified by the tag 'farm1' 
and give the controlling window a specific title, where the cluster is defined 
in one of the default configuration files

S<$ cssh -T 'Web Farm Cluster 1' farm1>

=item Connect to different servers using different login names.  NOTE: this can 
also be achieved by setting up appropriate options in the F<.ssh/config> file.
Do not close cssh when last terminal exits.

S<$ cssh -Q user1@server1 admin@server2>

=item Open up a cluster defined in a non-default configuration file

S<$ cssh -c $HOME/cssh.config db_cluster>

=item Use telnet on port 2022 instead of ssh

S<$ ctel -p 2022 server1 server2 >

=item Use rsh instead of ssh

S<$ crsh server1 server2 >

=back

=head1 FILES

=over

=item /etc/clusters

This file contains a list of tags to server names mappings.  When any name
is used on the command line it is checked to see if it is a tag.
If it is a tag, then the tag is replaced with the list of servers.  The 
formated is as follows:

S<< <tag> [user@]<server> [user@]<server> [...] >>

  i.e.

  # List of servers in live
  live admin1@server1 admin2@server2 server3 server4 

All comments (marked by a #) and blank lines are ignored.  Tags may be 
nested, but be aware of recursive tags which are not checked for.

Clusters may also be specified either directly (see C<clusters> configuration
options) or indirectly (see C<extra_cluster_file> configuration option) 
in the users F<$HOME/.csshrc> file.

=item F</etc/csshrc> & F<$HOME/.csshrc>

This file contains configuration overrides - the defaults are as marked.
Default options are overwritten first by the global file, and then by the
user file.

B<NOTE:> values for entries do not need to be quoted unless it is required 
for passing arguments, i.e.

  terminal_allow_send_events="-xrm '*.VT100.allowSendEvents:true'"

should be written as 

  terminal_allow_send_events=-xrm '*.VT100.allowSendEvents:true'

=over

=item always_tile = yes

Setting to anything other than C<yes> does not perform window tiling (see also -G).

=item auto_quit = yes

Automatically quit after the last client window closes.  Set to anything
other than "yes" to disable.  Can be overridden by C<-Q> on the command line.

=item clusters = <blank>

Define a number of cluster tags in addition to (or to replace) tags defined
in the F</etc/clusters> file.  The format is:

 clusters = <tag1> <tag2> <tag3>
 <tag1> = host1 host2 host3
 <tag2> = user@host4 user@host5 host6
 <tag3> = <tag1> <tag2>

As with the F</etc/clusters> file, be sure not to create recursivly nested tags.

=item comms = ssh

Sets the default communication method (initially taken from the name of 
program, but can be overridden here).

=item console_position = <null>

Set the initial position of the console - if empty then let the window manager 
decide.  Format is '+<x>+<y>', i.e. '+0+0' is top left hand corner of the screen,
'+0-70' is bottom left hand side of screen (more or less).

=item extra_cluster_file = <null>

Define an extra cluster file in the format of F</etc/clusters>.  Multiple
files can be specified, seperated by commas.  Both ~ and $HOME are acceptable
as a to reference the users home directory, i.e.

 extra_cluster_file = ~/clusters, $HOME/clus

=item ignore_host_errors

THIS OPTION IS DEPRECATED.  It has been left in so current systems continue 
to function as expected.

=item key_addhost = Control-plus

Default key sequence to open AddHost menu.  See below notes on shortcuts.

=item key_clientname = Alt-n

Default key sequence to send cssh client names to client.  See below notes 
on shortcuts.

=item key_paste = Control-v

Default key sequence to paste text into the console window.  See below notes
on shortcuts.

=item key_quit = Control-q

Default key sequence to quit the program (will terminate all open windows).  
See below notes on shortcuts.

=item key_retilehosts = Alt-r

Default key sequence to retile host windows.  See below notes on shortcuts.

=item mouse_paste = Button-2 (middle mouse button)

Default key sequence to paste text into the console window using the mouse.  
See below notes on shortcuts.

=item rsh_args = <blank>

=item ssh_args = "-x -o ConnectTimeout=10" 

Sets any arguments to be used with the communication method (defaults to ssh
arguments).  

B<NOTE:> The given defaults are based on OpenSSH, not commercial ssh software.

B<NOTE:> Any "generic" change to the method (i.e. specifying the ssh port to use)
should be done in the medium's own config file (see L<ssh_config> and 
F<$HOME/.ssh/config>).

=item screen_reserve_top = 25

=item screen_reserve_bottom = 30

=item screen_reserve_left = 0

=item screen_reserve_right = 0

Number of pixels from the screen side to reserve when calculating screen 
geometry for tiling.  Setting this to something like 50 will help keep cssh 
from positioning windows over your window manager's menu bar if it draws one 
at that side of the screen.

=item rsh = /path/to/rsh

=item ssh = /path/to/ssh

Depending on the value of comms, set the path of the communication binary.

=item terminal = /path/to/terminal

Path to the x-windows terminal used for the client.

=item terminal_args = <blank>

Arguments to use when opening terminal windows.  Otherwise takes defaults
from F<$HOME/.Xdefaults> or $<$HOME/.Xresources> file.

=item terminal_font = 6x13

Font to use in the terminal windows.  Use standard X font notation.

=item terminal_reserve_top = 0

=item terminal_reserve_bottom = 0

=item terminal_reserve_left = 0

=item terminal_reserve_right = 0

Number of pixels from the terminal side to reserve when calculating screen 
geometry for tiling.  Setting these will help keep cssh from positioning 
windows over your scroll and title bars

=item terminal_colorize = 1

If set to 1 (the default), then "-bg" and "-fg" arguments will be added
to the terminal invocation command-line.  The terminal will be colored
in a pseudo-random way based on the host name; while the color of a terminal
is not easily predicted, it will always be the same color for a given host
name.  After a while, you will recognize hosts by their characteristic
terminal color.

=item terminal_bg_style = dark

If set to dark, the the terminal background will be set to black and
the foreground to the pseudo-random color.  If set to light, then the
foreground will be black and the background the pseudo-random color.  If
terminal_colorize is zero, then this option has no effect.

=item terminal_size = 80x24

Initial size of terminals to use (note: the number of lines (24) will be 
decreased when resizing terminals for tiling, not the number of characters (80))

=item terminal_title_opt = -T

Option used with C<terminal> to set the title of the window

=item terminal_allow_send_events = -xrm '*.VT100.allowSendEvents:true'

Option required by the terminal to allow XSendEvents to be received

=item title = cssh

Title of windows to use for both the console and terminals.

=item unmap_on_redraw = no

Tell Tk to use the UnmapWindow request before redrawing terminal windows.
This defaults to "no" as it causes some problems with the FVWM window 
manager.  If you are experiencing problems with redraws, you can set it to
"yes" to allow the window to be unmapped before it is repositioned.

=item use_hotkeys = yes

Setting to anything other than C<yes> will disable all hotkeys.

=item user = $LOGNAME

Sets the default user for running commands on clients.

=item window_tiling = yes

Perform window tiling (set to C<no> to disable)

=item window_tiling_direction = right

Direction to tile windows, where "right" means starting top left and moving
right and then down, and anything else means starting bottom right and moving 
left and then up

=back

B<NOTE:> The key shortcut modifiers must be in the form "Control", "Alt", or 
"Shift", i.e. with the first letter capitalised and the rest lower case.  Keys
may also be disabled individually by setting to the word "null".

=back

=head1 AUTHOR

Duncan Ferguson

=head1 CREDITS

clusterssh is distributed under the GNU public license.  See the file
F<LICENSE> for details.

A web site for comments, requests, bug reports and bug fixes/patches is
available at L<http://clusterssh.sourceforge.net/>

=head1 KNOWN BUGS

Swapping virtual desktops can can a redraw of all the terminal windows.  This
is due to a lack of distinction within Tk between switching desktops and 
minimising/maximising windows.  Until Tk can tell the difference between the 
two events, there is no fix (apart from rewriting everything directly in X)

=head1 REPORTING BUGS

=over 2

=item *

If you have issues running cssh, first try:

C<< cssh -e [user@]<hostname>[:port] >>

This performs two tests to confirm cssh is able to work properly with the
settings provided within the F<.csshrc> file (or internal defaults).

	1. test the terminal window works with the options provided

	2. test ssh works to a host with the configured arguments

Configuration options to watch for in ssh are

	- Doesnt understand "-o ConnectTimeout=10" - remove the option 
	  in the F<.csshrc> file

	- OpenSSH-3.8 using untrusted ssh tunnels - use "-Y" instead of "-X"
	  or use "ForwardX11Trusted yes' in ssh_config (if you change the
	  default ssh options from -x to -X)

=item *

If you require support, please run the following commands
and post it on the web site in the support/problems forum:

C<< perl -V >>

C<< perl -MTk -e 'print $Tk::VERSION,$/' >>

C<< perl -MX11::Protocol -e 'print $X11::Protocol::VERSION,$/' >>

C<< cat /etc/csshrc $HOME/.csshrc >>

=item *

Use the debug switches (-d, -D, or -dD) will turn on debugging output.  
However, please only use this option with one host at a time, 
i.e. "cssh -d <host>" due to the amount of output produced (in both main 
and child windows).

=back

=head1 SEE ALSO

L<http://clusterssh.sourceforge.net/>,
L<ssh>,
L<Tk::overview>,
L<X11::Protocol>,
L<perl>

=cut
