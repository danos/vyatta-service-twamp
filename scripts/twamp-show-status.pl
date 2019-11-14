#!/usr/bin/perl

# Module: twamp-show-status.pl
#
# **** License ****
# Copyright (c) 2014-2016, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010-2013 Vyatta, Inc.
# All Rights Reserved.
#
# Based on dhcpd-show-status.pl by Bob Gilligan, April 2010.
#
# Script to display status about TWAMP server
#
# **** End License ****

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5/";

use Getopt::Long;
use Vyatta::Config;

my $CHVRF = "/usr/sbin/chvrf";

# Determine if TWAMP is running based on the output of ps
sub is_twamp_running_ps {
    my $routing_instance = shift;

    my $ps_output=`ps -C twampd -o args --no-headers`;

    my @output = split(/\n/, $ps_output);

    my $conf_file_match;
    if ($routing_instance eq "default") {
        $conf_file_match = "\/etc\/twamp-server";
    }
    else {
        $conf_file_match = "\/run\/twamp-$routing_instance";
    }

    foreach my $line (@output) {
        if ($line =~ /twampd -c $conf_file_match -R/) {
            return 1;
        }
    }

    return 0;
}

# Determine if TWAMP is running using systemctl
sub is_twamp_running_systemctl {
    my $service = shift;

    system("systemctl", "is-active", "-q", $service);
    return 1 if $? eq 0;

    return 0;
}

#
# Main Section
#

my $routing_instance;
my $use_ps = 0;
GetOptions("routing-instance=s" => \$routing_instance,
           "use-ps" => \$use_ps) or die("Error in arguments");

# Confirm we are in fallback mode if explicitly requested
print "Using 'ps' fallback mode\n" if ($use_ps);

# If we don't have systemd then fallback to ps mode
if (! -X "/bin/systemctl" or ! -d "/run/systemd/system") {
    $use_ps = 1;
}

my $vcTWAMP = new Vyatta::Config();

my $twamp_cfg_tree = "service twamp server";
my $twamp_service = "twamp-server";

if (defined($routing_instance)) {
    die("No routing instance support!\n") unless (-f $CHVRF);

    die("Routing instance '$routing_instance' has not been configured\n")
        unless $vcTWAMP->existsOrig("routing routing-instance $routing_instance");

    $twamp_cfg_tree = "routing routing-instance $routing_instance $twamp_cfg_tree";
    $twamp_service .= "\@$routing_instance";
}
else {
    $routing_instance = "default";
}
$twamp_service .= ".service";

my $exists=$vcTWAMP->existsOrig($twamp_cfg_tree);

my $configured_count=0;
if ($exists) {
    printf("TWAMP Server is configured ");
    $configured_count++;
} else {
    printf("TWAMP Server is not configured ");
}

my $running_count = -1;
if ($use_ps) {
    $running_count = is_twamp_running_ps($routing_instance);
}
else {
    $running_count = is_twamp_running_systemctl($twamp_service);
}

if ($running_count == 0) {
    if ($configured_count == 0) {
        printf("and ");
    } else {
        printf("but ");
    }
    printf("is not running");
} elsif ($running_count > 0) {
    if ($configured_count == 0) {
        printf("but ");
    } else {
        printf("and ");
    }
    printf("is running");
}

if (-f $CHVRF) {
    if ($routing_instance eq "default") {
        printf(" in the default routing instance");
    }
    else {
        printf(" in routing instance '$routing_instance'");
    }
}

if ($running_count < 0) {
    printf(" (running status cannot be determined)");
}

printf("\n");
exit 0;

