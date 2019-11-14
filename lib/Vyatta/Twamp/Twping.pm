# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2016-17 Brocade Communications Systems, Inc.
# All rights reserved
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::Twamp::Twping;

use strict;
use warnings;
use Exporter;
use JSON;
use POSIX qw(strftime);

use vars qw(@ISA @EXPORT $VERSION);

@ISA = qw( Exporter );

@EXPORT = qw(twping_output_to_json twping_stats_start_line_match
             twping_stats_end_line_match);

$VERSION = 1.00;

sub settimevalue {
    my($out, $entry, $container, $leaf, $time) = @_;

    if (!($time =~ /^(-|\d+)/)) {
        # Non-number value, such as nan, ignore it
        return;
    }

    # convert to a string, and remove trailing zeros
    my $n = sprintf("%f", $time);
    $n =~ s/(\.\d+?)0+$/$1/;
    $out->{"results"}[$entry]->{$container}->{$leaf} = $n;
}

sub addtimestats {
    my ($out, $entry, $container, $min, $median, $max, $error) = @_;
    settimevalue($out, $entry, $container, "min", $min);
    settimevalue($out, $entry, $container, "median", $median);
    settimevalue($out, $entry, $container, "max", $max);
    settimevalue($out, $entry, $container, "error", $error);
}

# Twping returns times which do not include a timezone.
# Add the timezone to make it ISO8601 compliant, and
# fit in ietf-yang-types date-and-time definition.
sub append_timezone {
    my ($time) = @_;
    my $tz = strftime( "%z", localtime() );

    #timezone needs conversion from [+-]hhmm to [+-]hh:mm
    $tz =~ s/(\d{2})(\d{2})/$1:$2/;

    return $time . $tz;
}

sub twping_stats_start_line_match {
    my ($line) = @_;
    return $line =~ /^--- twping statistics from.+$/;
}

sub twping_stats_end_line_match {
    my ($line) = @_;
    return $line =~ /^\n$/;
}

sub twping_output_to_json {
    my ($twping_output) = @_;

    my $entry = 0;
    my $firstpass = 1;
    my %out;

    # Process the results, line by line, extracting the RPC putput parameters
    my @result = split( /\n/, join( "", $twping_output ) );

    foreach my $line (@result) {
        # Source/destination address and port number
        # The port number is optional. It may not appear in cases, such as when
        # using multiple sessions
        if ($line =~ /^--- twping statistics from \[(\S+[^\]])\]:(\d*)\s+to\s+\[(\S+[^\]])\]:(\d*)/) {
            # Start of a new set of results
            $entry++ unless $firstpass;
            $firstpass = 0;

            $out{"results"}[$entry]->{"source"}->{"address"} = $1;
            $out{"results"}[$entry]->{"source"}->{"port"} = int($2) unless !length($2);
            $out{"results"}[$entry]->{"destination"}->{"address"} = $3;
            $out{"results"}[$entry]->{"destination"}->{"port"} = int($4) unless !length($4);
        }
        if ($line =~ /^SID:\s+(\S+)/) {
            $out{"results"}[$entry]->{"sid"} = $1;
        }
        # Time first test packet was sent
        if ($line =~ /^first:\s+(\S+)/) {
            $out{"results"}[$entry]->{"packets"}->{"time-of-first"} = append_timezone($1);
        }
        # Time last test packet was sent
        if ($line =~ /^last:\s+(\S+)/) {
            $out{"results"}[$entry]->{"packets"}->{"time-of-last"} = append_timezone($1);
        }

        # Packets sent and lost, optionally the send/reflect duplicates
        # which will be ommitted if all packets are lost
        if ($line =~ /^(\d+)\s+sent,\s+(\d+)\s+lost\s+\([0-9]+.[0-9]+%\)(,\s+(\d+)\s+send duplicates,\s+(\d+))?/) {
            $out{"results"}[$entry]->{"packets"}->{"num-pkts-sent"} = int($1);
            $out{"results"}[$entry]->{"packets"}->{"num-pkts-lost"} = int($2);
            $out{"results"}[$entry]->{"packets"}->{"send-duplicates"} = int($4) unless !length($4);
            $out{"results"}[$entry]->{"packets"}->{"reflect-duplicates"} = int($5) unless !length($5);
        }
        if ($line =~ /^round-trip time min\/median\/max\s+=\s+(\S+)\/(\S+)\/(\S+)\s+ms,\s+\(err=(\S+)/) {
            addtimestats(\%out, $entry, "round-trip-time", $1, $2, $3, $4);
        }
        if ($line =~ /^send time min\/median\/max\s+=\s+(\S+)\/(\S+)\/(\S+)\s+ms,\s+\(err=(\S+)/) {
            addtimestats(\%out, $entry, "send-time", $1, $2, $3, $4);
        }
        if ($line =~ /^reflect time min\/median\/max\s+=\s+(\S+)\/(\S+)\/(\S+)\s+ms,\s+\(err=(\S+)/) {
            addtimestats(\%out, $entry, "reflect-time", $1, $2, $3, $4);
        }
        if ($line =~ /^reflector processing time min\/max\s+=\s+(\S+)\/(\S+)/) {
            settimevalue(\%out, $entry, "reflector-processing-time", "min", $1);
            settimevalue(\%out, $entry, "reflector-processing-time", "max", $2);
        }
        if ($line =~ /^two-way jitter\s+=\s+(\S+)\s+ms\s+/) {
            settimevalue(\%out, $entry, "round-trip-time","pdv", $1);
        }
        if ($line =~ /^send jitter\s+=\s+(\S+)\s+ms/) {
            settimevalue(\%out, $entry, "send-time", "pdv", $1);
        }
        if ($line =~ /^reflect jitter\s+=\s+(\S+)\s+ms/) {
            settimevalue(\%out, $entry, "reflect-time", "pdv", $1);
        }

        # Hops traversed by test packets on route to the reflector
        if ($line =~ /^send hops =\s+(\d+)/) {
            # Same number of hops taken by all test packets (consistently)
            $out{"results"}[$entry]->{"send-hops"} = { "diff-num-ttl" => 1, "min" => int($1), "max" => int($1)};
        } elsif ($line =~ /^send hops takes\s+(\d+)\s+values; min hops =\s+(\d+), max hops =\s+(\d+)/) {
            # number of hops were inconsistent
            $out{"results"}[$entry]->{"send-hops"} = { "diff-num-ttl" => int($1), "min" => int($2), "max" => int($3)};
        }

        # Hops traversed by test packets on the return trip from the reflector
        if ($line =~ /^reflect\s+hops\s+=\s+(\d+)/) {
            # Same number of hops taken by all test packets (consistently)
            $out{"results"}[$entry]->{"reflect-hops"} = { "diff-num-ttl" => 1, "min" => int($1), "max" => int($1)};
        } elsif ($line =~ /^reflect hops takes\s+(\d+)\s+values; min hops =\s+(\d+), max hops =\s+(\d+)/) {
            # number of hops travelled by test packets were inconsistent
            $out{"results"}[$entry]->{"reflect-hops"} = { "diff-num-ttl" => int($1), "min" => int($2), "max" => int($3)};
        }
    }

    if (!keys %out) {
        # no useful results found
        return;
    } elsif (!exists($out{"results"}[$entry]->{"packets"}->{"num-pkts-sent"})) {
        # Some error conditions only show minimal output
        # Be explicit that no packets were sent
        $out{"results"}[$entry]->{"packets"}->{"num-pkts-sent"} = 0;
    }

    return encode_json( \%out );
}

1;
