#!/usr/bin/perl
# Module: twampd-config.pl
#
# **** License ****
#
# Copyright (c) 2017-2018, 2021 AT&T Intellectual Property.  All rights reserved.
# Copyright (c) 2014-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# Script to setup TWAMP server
#
# **** End License ****

use strict;
use warnings;

use File::Path qw(remove_tree);
use Getopt::Long;
use Readonly;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;

my $routing_instance;
GetOptions("routing-instance=s" => \$routing_instance) or die("Error in arguments");

# We should never be passed anything which fails this check so if
# we are let's fail hard and fast.
#
# Since we use this value as part of real paths it would be unsafe
# to allow path separators to be part of the routing instance name
if (defined($routing_instance) and $routing_instance =~ m/[\/]+/) {
	die("Routing instance name cannot contain path separators!\n");
}

# Set the correct service file and base of the TWAMP config tree
my $twamp_conf_base_tree = "service twamp server";
my $twamp_service = "twamp-server";
my $base_run_dir = "/var/run/twamp";
if (defined($routing_instance)) {
	$twamp_conf_base_tree = "routing routing-instance $routing_instance $twamp_conf_base_tree";
	$twamp_service .= "\@$routing_instance";
	$base_run_dir .= "-$routing_instance";
}
else {
	$routing_instance = "default" unless defined($routing_instance);
}
Readonly my $TWAMP_CONF_TREE_BASE => $twamp_conf_base_tree;
Readonly my $TWAMP_SERVICE => "$twamp_service";

Readonly my $PERSISTENT_CONF_DIR => "/etc/twamp-server";
Readonly my $CONF_FILE           => "twamp-server.conf";
Readonly my $LIMITS_FILE         => "twamp-server.limits";
Readonly my $PFS_FILE            => "twamp-server.pfs";

Readonly my $RUN_DIR  => $base_run_dir;
Readonly my $CONF_DIR => "$RUN_DIR/config";
Readonly my $DATA_DIR => "/var/lib/twamp/$routing_instance";
Readonly my $STATE_DIR => "$RUN_DIR";

Readonly my	$TWAMPD_CONF => "$CONF_DIR/$CONF_FILE";
Readonly my	$TWAMPD_LIMITS => "$CONF_DIR/$LIMITS_FILE";
Readonly my	$TWAMPD_PFS => "$CONF_DIR/$PFS_FILE";
Readonly my	$HEADER => "# Generated by $0 on ".localtime(time)." #\n\n";

# CLI config defaults #
# These are overridden by any defaults specified in the data model
Readonly my	$DEFAULT_MAX_CONTROL_SESSIONS => 16;
Readonly my	$DEFAULT_MAX_TEST_SESSIONS => 8;
Readonly my	$DEFAULT_SERVER_INACTIVITY_TIMEOUT => 900;
Readonly my	$DEFAULT_TEST_INACTIVITY_TIMEOUT => 900;
Readonly my	$DEFAULT_PORT => 862;
Readonly my	$DEFAULT_DSCP => 0;

# Non-exposed config defaults #
Readonly my	$USER => "twamp";
Readonly my	$GROUP => "twamp";

my $vyattaConfig = new Vyatta::Config();
my $disabled = 1;
my $conf_output = "";
my $limit_output = "";

# Append the non-exposed options to the config output #
sub confAppendUnexposedDefaults {
	$conf_output .= "user ".$USER."\n";
	$conf_output .= "group ".$GROUP."\n\n";

	$conf_output .= "datadir ".$DATA_DIR."\n";
	$conf_output .= "runstatedir ".$STATE_DIR."\n\n";
	# This should correlate with the value in the init script
	$conf_output .= "dieby 5\n\n";
}

# Append the configured authentication mode to the config output #
sub confAppendAuthMode {
	my $mode = "";
	if (! $vyattaConfig->exists("mode no-unauthenticated")) {
		$mode .= "O";
	}
	if (! $vyattaConfig->exists("mode no-mixed")) {
		$mode .= "M";
	}
	if (! $vyattaConfig->exists("mode no-authenticated")) {
		$mode .= "A";
	}
	if (! $vyattaConfig->exists("mode no-encrypted")) {
		$mode .= "E";
	}
	
	$conf_output .= "authmode $mode\n\n";
}

# Append dataplane offload mode to the config output
sub confAppendOffloadMode {
	if ($vyattaConfig->exists("no-offload")) {
		$conf_output .= "nooffload\n\n";
	}
}

# Append the value of a Vyatta config key and its corresponding
# TWAMP config keyword to the config output
#
# Args
# 	0	Vyatta config key
#	1	TWAMP config file keyword
#	2	Default value, if key is not defined in Vyatta config
#	3	Optional value to prepend to the value in the output
sub confAppendKeyValue {
	my $cliKeyword = $_[0];
	my $confKeyword = $_[1];
	my $default = $_[2];
	my $preVal = (! defined $_[3]) ? "" : $_[3];
	
	my $val = $vyattaConfig->returnValue($cliKeyword);
	if (! defined $val) {
		$val = $default;
	}
	$conf_output .= "$confKeyword $preVal$val\n\n";
}

# Generate the TWAMP limits configuration #
sub limitsAppend {
	my $maxTestSessions = $vyattaConfig->returnValue('maximum-sessions-per-connection');
	if (! defined $maxTestSessions) {
		$maxTestSessions = $DEFAULT_MAX_TEST_SESSIONS;
	}
	
	# Open limit class
	$limit_output .= "limit open with bandwidth=0, disk=0, allow_open_mode=on, test_sessions=$maxTestSessions\n";
	
	# If a client list is set then create a new default class
	# that rejects connections and assign the clients to the open class
	my @clients = $vyattaConfig->returnValues("client-list");
	if (scalar(@clients) > 0) {
		$limit_output .= "limit noaccess with parent=open, bandwidth=1, disk=1, allow_open_mode=off\n";
		$limit_output .= "assign default noaccess\n";
		foreach my $client (@clients) {
			$limit_output .= "assign net $client open\n\n";
		}
	}
	# All connections are allowed if no clients are set
	else {
		$limit_output .= "assign default open\n\n";
	}
}

# Generate the TWAMPD_PFS file for authenication and encryption modes #
sub pfsGen {
	# If a pfs file already exists then remove it, otherwise aespasswd will complain
	if (-e $TWAMPD_PFS && ! unlink $TWAMPD_PFS) {
		print STDERR "($0) Failed to delete ".$TWAMPD_PFS."\n";
		exit(1);
	}
	
	# Nothing to do if no users are configured
	my @users = $vyattaConfig->listNodes("user");
	if (scalar(@users) == 0) {
		return;
	}

	# aespasswd and pfstore do not create compatible passphrases.
	# In earlier releases aespasswd was used as a workaround as pfstore
	# was not available. pfstore is now used unless the legacy method is
	# requested.
	my $pfsManBin = $vyattaConfig->exists("use-legacy-authentication") ?
						"aespasswd" : "pfstore";

	# Store passphrase for each defined user using the manager
	my $owampdPfsCreated = 0;
	my @pfsManArgs = ("-n", "-f"); # -n create new store, -f store file
	foreach my $user (@users) {
		if ($user =~ m/\S*\s+\S*/) {
			print "Warning: Cannot configure user '$user' as whitespace is not allowed\n";
			next;
		}

		my @args = ($pfsManBin, @pfsManArgs, $TWAMPD_PFS, $user);

		my $pfsManIn;
		my $pid = open($pfsManIn, "|-") // die("Fork failure: $!\n");
		if ($pid) {
			# Parent
			# Print passphrase to STDIN of the passphrase mananger
			print $pfsManIn $vyattaConfig->returnValue("user $user password");
			close $pfsManIn or die("Failure storing password for user '$user'\n");
			waitpid($pid, 0);
		}
		else {
			# Child
			# We don't want to output the passphrase prompt so redirect STDERR
			close STDERR;
			open(STDERR, ">", "/dev/null");

			# setsid forces the manager to accept the passphrase on STDIN
			if (! exec("setsid", @args)) {
				# Print error to STDOUT since STDERR was redirected
				print "Failure running $pfsManBin: $!\n";
				exit(1);
			}
		}

		# Remove new file arg now the pfs file has been created
		if (! $owampdPfsCreated) {
			$owampdPfsCreated = 1;
			@pfsManArgs = ("-f");
		}
	}
	
	# Change ownership to twamp user and group (TWAMPD_PFS is rw for owner only)
	my $twampUid = getpwnam($USER);
	my $twampGid = getgrnam($GROUP);
	chown($twampUid, $twampGid, $TWAMPD_PFS);

	if ($routing_instance eq "default") {
		symlink($TWAMPD_PFS, "$PERSISTENT_CONF_DIR/$PFS_FILE") or
			die("Failed to create $PERSISTENT_CONF_DIR/$PFS_FILE symlink: $!\n");
	}
}

# Write data to file
#
# Args
#	0	Data to write
#	1	File to write to
sub writeFile {
	my $out = $_[0];
	my $file = $_[1];
	
	my $fh;
	if (! open($fh, ">", $file)) {
		print STDERR "($0) Failed to open $file\n";
		exit(1);
	}
	print $fh $out;
	close $fh;
}

# Remove old config file or symlinks from the persistent configuration directory
sub remove_persistent_config {
	if ($routing_instance eq "default") {
		my @links = ("$PERSISTENT_CONF_DIR/$CONF_FILE",
					 "$PERSISTENT_CONF_DIR/$LIMITS_FILE",
					 "$PERSISTENT_CONF_DIR/$PFS_FILE");

		foreach my $file (@links) {
			if (-l $file || -e $file) {
				unlink($file) or print "Warning: Failed to delete $file: $!\n";
			}
		}
	}
}

if ($vyattaConfig->exists($TWAMP_CONF_TREE_BASE)) {
	# Create run directory
	if (! -d "$RUN_DIR" && ! mkdir "$RUN_DIR") {
		die("Failed to create $RUN_DIR: $!\n");
	}

	# Create config directory
	if (! -d "$CONF_DIR") {
		mkdir("$CONF_DIR") or die("Failed to create $CONF_DIR: $!\n");
	}

	$disabled = 0;
	$vyattaConfig->setLevel($TWAMP_CONF_TREE_BASE);
	
	# TWAMPD_CONF #
	$conf_output .= $HEADER;
	confAppendUnexposedDefaults();
	confAppendAuthMode();
	confAppendOffloadMode();
	confAppendKeyValue("port", "srcnode", $DEFAULT_PORT, ":");
	confAppendKeyValue("maximum-connections", "maxcontrolsessions", $DEFAULT_MAX_CONTROL_SESSIONS);
	confAppendKeyValue("server-inactivity-timeout", "controltimeout", $DEFAULT_SERVER_INACTIVITY_TIMEOUT);
	confAppendKeyValue("test-inactivity-timeout", "testtimeout", $DEFAULT_TEST_INACTIVITY_TIMEOUT);
	confAppendKeyValue("dscp-value", "controldscpvalue", $DEFAULT_DSCP);
	
	# TWAMPD_LIMITS #
	$limit_output .= $HEADER;
	limitsAppend();

	remove_persistent_config();

	# TWAMPD_PFS #
	pfsGen();

	# Write config out to disk #
	writeFile($conf_output, $TWAMPD_CONF);
	writeFile($limit_output, $TWAMPD_LIMITS);

	# Create symlinks from the default instance config directory to the persistent
	# config directory.
	if ($routing_instance eq "default") {
		symlink($TWAMPD_CONF, "$PERSISTENT_CONF_DIR/$CONF_FILE") or
			die("Failed to create $PERSISTENT_CONF_DIR/$CONF_FILE symlink: $!\n");

		symlink($TWAMPD_LIMITS, "$PERSISTENT_CONF_DIR/$LIMITS_FILE") or
			die("Failed to create $PERSISTENT_CONF_DIR/$LIMITS_FILE symlink: $!\n");
	}
}

# Restart or stop the twampd service #
my $initAction = ($disabled) ? "stop" : "restart";
system "service", $TWAMP_SERVICE, $initAction;
my $rc = $?;

# To ensure that TWAMP can be reconfigured many times in succession
# we must inhibit systemd's rate limiting feature, otherwise the service
# may not start the next time we request it to
if (-X "/bin/systemctl" and -d "/run/systemd/system") {
	system "systemctl", "is-active", "-q", $TWAMP_SERVICE;
	system "systemctl", "reset-failed", $TWAMP_SERVICE if $? eq 0;
}

if ($disabled) {
	# Delete config directory
	if (-d "$CONF_DIR" && ! remove_tree "$CONF_DIR") {
		print STDERR "Failed to delete $CONF_DIR: $!\n";
	}

	# Delete the run directory
	if (-d "$RUN_DIR" && ! remove_tree "$RUN_DIR") {
		print STDERR "Failed to delete $RUN_DIR: $!\n";
	}

	# Remove symlinks for the default instance
	remove_persistent_config();
}

exit $rc;
