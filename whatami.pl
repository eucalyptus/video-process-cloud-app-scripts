#!/usr/bin/perl

use strict;

my $userdata = `curl http://169.254.169.254/latest/user-data`;

print "\nUSER-DATA\n";
print $userdata . "\n";

my $scriptname;
my $ssip;

if( $userdata =~ /(.+)\s+([\d\.]+)\s+\[(.+)\]/ ){
	$scriptname = $1;
	$ssip = $2;
}else{
	print "ERROR IN USERDATA !!\n";
	exit(1);
};

system("apt-get -y install wget");
system("wget http://$ssip/scriptserver/$scriptname");
system("chmod 755 $scriptname");
system("./$scriptname");

exit(0);

