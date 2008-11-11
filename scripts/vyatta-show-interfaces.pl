#!/usr/bin/perl
#
# Module: vyatta-show-interfaces.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: February 2008
# Description: Script to display interface information
# 
# **** End License ****
#

use lib "/opt/vyatta/share/perl5/";
use VyattaConfig;
use Getopt::Long;
use POSIX;
use NetAddr::IP;

use strict;
use warnings;

#
# valid interfaces
#
my %intf_hash = (
    ethernet  => 'eth',
    serial    => 'wan',
    tunnel    => 'tun',
    bridge    => 'br',
    loopback  => 'lo',
    pppoe     => 'pppoe',
    pppoa     => 'pppoa',
    adsl      => 'adsl',
    multilink => 'ml',
    openvpn   => 'vtun',
    wirelessmodem => 'wlm',
    );

#
# valid actions
#
my %action_hash = (
    'show'       => \&run_show_intf,
    'show-brief' => \&run_show_intf_brief,
    'clear'      => \&run_clear_intf,
    'reset'      => \&run_reset_intf,
    );


my $clear_stats_dir = '/var/run/vyatta';
my $clear_file_magic = 'XYZZYX';

my @rx_stat_vars = 
    qw/rx_bytes rx_packets rx_errors rx_dropped rx_over_errors multicast/; 
my @tx_stat_vars = 
    qw/tx_bytes tx_packets tx_errors tx_dropped tx_carrier_errors collisions/;

sub get_intf_type {
    my $intf = shift;

    my $base;
    if ($intf =~ m/([a-zA-Z]+)\d*/) {
	$base = $1;
    } else {
	die "unknown intf type [$intf]\n";
    }
    
    foreach my $intf_type (keys(%intf_hash)) {
	if ($intf_hash{$intf_type} eq $base) {
	    return $intf_type;
	}
    }
    return undef;
}

sub get_intf_description {
    my $intf = shift;

    my $intf_type = get_intf_type($intf);
    if (!defined $intf_type) {
	return "";
    }
    my $config = new VyattaConfig; 
    my $path;
    if ($intf =~ m/([a-zA-Z]+\d+)\.(\d+)/) {
	$path = "interfaces $intf_type $1 vif $2";
    } else {
	$path = "interfaces $intf_type $intf";
    }
    $config->setLevel($path);
    my $description = $config->returnOrigValue("description"); 
    if (defined $description) {
	return $description;
    } else {
	return "";
    }
}

sub get_sysfs_value {
    my ($intf, $name) = @_;

    open (my $statf, '<', "/sys/class/net/$intf/$name")
	or die "Can't open statistics file /sys/class/net/$intf/$name";

    my $value = <$statf>;
    chomp $value if defined $value;
    close $statf;
    return $value;
}

sub get_intf_stats {
    my $intf = shift;
    
    my %stats = ();
    foreach my $var (@rx_stat_vars, @tx_stat_vars) {
	$stats{$var} = get_sysfs_value($intf, "statistics/$var");
    }
    return %stats;
}

sub get_intf_statsfile {
    my $intf = shift;

    return "$clear_stats_dir/$intf.stats";
}

sub get_clear_stats {
   my $intf = shift;

   my %stats = ();
   foreach my $var (@rx_stat_vars, @tx_stat_vars) {
       $stats{$var} = 0;
   }
   my $FILE;
   my $filename = get_intf_statsfile($intf);
   if (!open($FILE, "<", $filename)) {
       return %stats;
   }

   my $magic = <$FILE>; chomp $magic;
   if ($magic ne $clear_file_magic) {
       print "bad magic [$intf]\n";
       return %stats;
   }
   my $timestamp = <$FILE>; chomp $timestamp;
   $stats{'timestamp'} = $timestamp;
   my ($var, $val);
   while (<$FILE>) {
       chop;
       ($var, $val) = split(/,/);
       $stats{$var} = $val;
   }
   close($FILE);
   return %stats;
}

sub get_ipaddr {
    my $intf = shift;
    
    my @addr_list = ();
    my @lines = `ip addr show $intf | grep 'inet' | grep -iv 'fe80'`;
    foreach my $line (@lines) {
	(my $inet, my $addr, my $remainder) = split(' ', $line, 3);
	my $ip = new NetAddr::IP($addr);
	if ($ip->version() == 6) {
	    push @addr_list, $ip->short() . '/' . $ip->masklen();
	} else {
	    push @addr_list, $ip->cidr();
 	}
    }
    chomp  @addr_list;
    return @addr_list;
}

sub get_state_link {
    my $intf = shift;
    my $state;
    my $link = 'down';
    my $flags = get_sysfs_value($intf, 'flags');

    my $hex_flags = hex($flags);
    if ($hex_flags & 0x1) {	  # IFF_UP
	$state = 'up'; 
	my $carrier = get_sysfs_value($intf, 'carrier');
	if ($carrier eq '1') {
	    $link = "up"; 
	}
    } else {
	$state = "admin down";
    }

    return ($state, $link);
}

sub is_valid_intf {
    my ($intf) = @_;

    if (-e "/sys/class/net/$intf") {
	return 1;
    } 
    return 0;
}

sub is_valid_intf_type {
    my $intf_type = shift;
    
    if (defined $intf_hash{$intf_type}) {
	return 1;
    }
    return 0;
}

sub get_intf_for_type {
    my $type = shift;
    my $sysnet = "/sys/class/net";
    my $prefix = $type ? $intf_hash{$type} : '[^.]+';

    opendir (my $dir, $sysnet)	or die "can't open $sysnet";
    my @list = grep { /^$prefix/ && -d "$sysnet/$_" } readdir($dir);
    closedir $dir;

    return @list;
}

# This function assumes 32-bit counters.  
sub get_counter_val {
    my ($clear, $now) = @_;

    return $now if $clear == 0;

    my $value;
    if ($clear > $now) {
	#
	# The counter has rolled.  If the counter has rolled
	# multiple times since the clear value, then this math
	# is meaningless.
	#
	$value = (4294967296 - $clear) + $now;
    } else {
	$value = $now - $clear;
    }
    return $value;
}


#
# The "action" routines
#

sub run_show_intf {
    my @intfs = @_;

    foreach my $intf (@intfs) {
	my %clear = get_clear_stats($intf);
	my $description = get_intf_description($intf);
	my $timestamp = $clear{'timestamp'};
	my $line = `ip addr show $intf | sed 's/^[0-9]*: //'`; chomp $line; 
	print "$line\n";
	if (defined $timestamp and $timestamp ne "") {
	    my $time_str = strftime("%a %b %d %R:%S %Z %Y", 
				    localtime($timestamp));
	    print "    Last clear: $time_str\n";
	}
	if (defined $description and $description ne "") {
	    print "    Description: $description\n";
	}
	print "\n";
	my %stats = get_intf_stats($intf);
	printf("    %10s %10s %10s %10s %10s %10s\n", "RX:  bytes", "packets",
	       "errors", "dropped", "overrun", "mcast");
	printf("    %10u %10u %10u %10d %10u %10u\n", 
	       get_counter_val($clear{'rx_bytes'}, $stats{'rx_bytes'}),
	       get_counter_val($clear{'rx_packets'}, $stats{'rx_packets'}),
	       get_counter_val($clear{'rx_errors'}, $stats{'rx_errors'}),
	       get_counter_val($clear{'rx_dropped'}, $stats{'rx_dropped'}),
	       get_counter_val($clear{'rx_over_errors'}, 
			       $stats{'rx_over_errors'}),
	       get_counter_val($clear{'multicast'}, $stats{'multicast'}));

	printf("    %10s %10s %10s %10s %10s %10s\n", "TX:  bytes", "packets",
	       "errors", "dropped", "carrier", "collisions");
	printf("    %10u %10u %10u %10u %10u %10u\n\n", 
	       get_counter_val($clear{'tx_bytes'}, $stats{'tx_bytes'}),
	       get_counter_val($clear{'tx_packets'}, $stats{'tx_packets'}),
	       get_counter_val($clear{'tx_errors'}, $stats{'tx_errors'}),
	       get_counter_val($clear{'tx_dropped'}, $stats{'tx_dropped'}),
	       get_counter_val($clear{'tx_carrier_errors'}, 
			       $stats{'tx_carrier_errors'}),
	       get_counter_val($clear{'collisions'}, $stats{'collisions'}));
    }
}

sub run_show_intf_brief {
    my @intfs = @_;

    my $format = "%-12s %-18s %-11s %-6s %-29s\n";
    printf($format, "Interface","IP Address","State","Link","Description");
    foreach my $intf (@intfs) {
	my @ip_addr = get_ipaddr($intf);
	my ($state, $link) = get_state_link($intf);
	my $description = get_intf_description($intf);
	$description = substr($description, 0, 29); # make it fit on 1 line
	if (scalar(@ip_addr) == 0) {
	    printf($format, $intf, "-", $state, $link, $description);
	} else {
	    foreach my $ip (@ip_addr) {
		printf($format, $intf, $ip, $state, $link, $description);
	    }
	}
    }
}

sub run_clear_intf {
    my @intfs = @_;

    foreach my $intf (@intfs) {
	my %stats = get_intf_stats($intf);
	my $FILE;
	my $filename = get_intf_statsfile($intf);
	if (!open($FILE, ">", $filename)) {
	    die "Couldn't open $filename [$!]\n";
	}
	print "Clearing $intf\n";
	print $FILE $clear_file_magic, "\n", time(), "\n";
	my ($var, $val);
	while (($var, $val) = each (%stats)) {
	    print $FILE $var, ",", $val, "\n";
	}
	close($FILE);
    }
}

sub run_reset_intf {
    my @intfs = @_;
    
    foreach my $intf (@intfs) {
	my $filename = get_intf_stats($intf);
	system("rm -f $filename");
    }
}

sub alphanum_split {
    my ($str) = @_;
    my @list = split m/(?=(?<=\D)\d|(?<=\d)\D)/, $str;
    return @list;
}

sub natural_order {
    my ($a, $b) = @_;
    my @a = alphanum_split($a);
    my @b = alphanum_split($b);
  
    while (@a && @b) {
	my $a_seg = shift @a;
	my $b_seg = shift @b;
	my $val;
	if (($a_seg =~ /\d/) && ($b_seg =~ /\d/)) {
	    $val = $a_seg <=> $b_seg;
	} else {
	    $val = $a_seg cmp $b_seg;
	}
	if ($val != 0) {
	    return $val;
	}
    }
    return @a <=> @b;
}

sub intf_sort {
    my @a = @_;
    my @new_a = sort { natural_order($a,$b) } @a;
    return @new_a;
}


#
# main
#
my @intf_list = ();
my ($intf_type, $intf, $action);
GetOptions("intf-type=s" => \$intf_type,
	   "intf=s"      => \$intf,
	   "action=s"    => \$action,
);

if (defined $intf) {
    if (!is_valid_intf($intf)) {
	die "Invalid interface [$intf]\n";
    }
    push @intf_list, $intf;
} elsif (defined $intf_type) {
    if (!is_valid_intf_type($intf_type)) {
	die "Invalid interface type [$intf_type]\n";
    }
    @intf_list = get_intf_for_type($intf_type);
} else {
    # get all interfaces
    @intf_list = get_intf_for_type();
}

if (! defined $action) {
    $action = 'show';
} 

@intf_list = intf_sort(@intf_list);

my $func;
if (defined $action_hash{$action}) {
    $func = $action_hash{$action};
} else {
    die "Invalid action [$action]\n";
}

#
# make it so...
#
&$func(@intf_list);

# end of file
