#!/usr/bin/perl

use strict;

local $| = 1;

my $storagedir = "/export/storage";

my $userdata = `curl http://169.254.169.254/latest/user-data`;

my $ssip = "";
my $arguments = "";

if( $userdata =~ /(.+)\s+([\d\.]+)\s+\[(.+)\]/ ){
	$ssip = $2;
	$arguments = $3;

	print "Script Server IP:\t$ssip\n";
	print "Arguments:\t$arguments\n";
	print "\n";
}else{
	print "NO ARGUMENTS !!\n";
	exit(1);
};


##########################################
### Handle Input Arguments             ###
##########################################

my $inputfile = "";

if( $arguments =~ /(\S+)/ ){
	$inputfile = $1;
}else{
	print "ERROR! Invalid Arguments [ $arguments ] !!\n\n";
	exit(1);
};

my $bucketName = "";
my $outputfile = "";

if( $inputfile =~ /(\S+)\.\w+/ ){
	$bucketName = "bucket_for_" . $1;
	$outputfile = $1 . "_filtered";
};

print "\n";
print "===============================\n";
print "===    Converter Setup      ===\n";
print "===============================\n";
print "\n";
print "Input File:\t$inputfile\n";
print "Bucket Name:\t$bucketName\n";
print "Output File:\t$outputfile\n";
print "\n";
print "\n";


##########################################
### Install Dependencies               ###
##########################################

install_deps();
print "\n";


##########################################
### Get Private IP Space               ###
##########################################

my $nfsip = "";

print "\n";
$nfsip = get_private_ip_space();

print "\n";
print "*** Discovering Private IP Space ***\n";
print "\n";

print "NFS IP PREFIX:\t$nfsip\n";
print "\n";

if( $nfsip eq "" ){
	print "ERROR! Couldn't detect Private IP space !!\n\n";
	exit(1);
};


##########################################
### Setup NFS                          ###
##########################################

print "\n";
print "*** Setting Up NFS ***\n";
print "\n";

setup_nfs_directory($storagedir);
print "\n";
sleep(5);


##########################################
### Create Job Description             ###
##########################################


system("mkdir -p $storagedir/jobs");
open(POST, "> $storagedir/jobs/job.info") or die $!;

print POST "Input File:\t$inputfile\n";

close(POST);



##########################################
### Create Image Directory             ###
##########################################


my $t_frames = generate_images($inputfile, $storagedir);
print "\n";

system("echo \"Total Frames: $t_frames\" >> $storagedir/jobs/job.info");
print "\n";

system("date >> $storagedir/jobs/job.info");
print "\n";



##########################################
### Scan the NFS directory for Images  ###
##########################################

print "\n";
print "=====================================";
print " Scanning NFS Directory for Images ";
print "=====================================";
print "\n";
print "\n";

my @images = ();

my @check_array = ();

my $is_done = 0;
my $f_count = 0;
while ($is_done == 0 ){
	
	opendir( SDIR, "$storagedir" ) or die $!;
	@images = readdir(SDIR);
	closedir(SDIR);

	foreach my $image ( @images ){
		if( $image =~ /^image(\d+)\.(\w+)/ ){
			$check_array[$1] = 1;
		};
	};

	$is_done = 1;
	$f_count = 0;

	print "\n";
	print "Rendered Images\t[ ";
	for( my $i = 1; $i<= $t_frames; $i++ ){
		if( $check_array[$i] ){
			print "Index $i ";
			$f_count++;
		}else{
			$is_done = 0;
		};
	};
	print "]\n";
	print "\n";

	print "Frames: $f_count / $t_frames\n";
	print "\n";

	print "\n";
	if( $is_done == 0 ){
		print "*** Rendering Still in Progress ***\n";
		print "Sleep for 60 sec\n";
		print "\n";
		sleep(60);
	}else{
		print "\n";
		print "Rendering Has Been Completed\n";
		print "\n";
	};
};
print "\n";


##########################################
### Adjust Image Names                 ###
##########################################

fix_image_names($storagedir);
print "\n";


##########################################
### Encode Images to AVI               ###
##########################################

print "\n";
print "Encoding Images to AVI\n";
print "\n";

chdir("$storagedir");
print("mencoder mf://*.jpg -mf w=640:h=480:fps=25:type=jpg -ovc lavc -lavcopts vcodec=mpeg4:mbd=2:trell -oac copy -o " . $outputfile . ".avi\n");
system("mencoder mf://*.jpg -mf w=640:h=480:fps=25:type=jpg -ovc lavc -lavcopts vcodec=mpeg4:mbd=2:trell -oac copy -o " . $outputfile . ".avi");
print "\n";

print "Produced AVI file $outputfile\n";
print "\n";


##########################################
### Moving the Final Output to S3      ###
##########################################


system("wget http://$ssip/scriptserver/eucarc");

### get WALRUS's IP and other credentials info

my $s3_ip;

my $s_line = `cat ./eucarc | grep S3`;

if( $s_line =~ /http:\/\/([\d\.]+)/ ){
	$s3_ip = $1;
};

print "WALRUS's IP\t" . $s3_ip . "\n";

my $S3_URL;
my $EC2_ACCESS_KEY;
my $EC2_SECRET_KEY;

$s_line = `cat ./eucarc | grep S3_URL | grep Walrus`;

if( $s_line =~ /^export S3_URL=(.+)/ ){
	$S3_URL = $1;
};

$s_line = `cat ./eucarc | grep EC2_ACCESS_KEY`;

if( $s_line =~ /^export EC2_ACCESS_KEY=\'(.+)\'/ ){
	$EC2_ACCESS_KEY = $1;
};

$s_line = `cat ./eucarc | grep EC2_SECRET_KEY`;

if( $s_line =~ /^export EC2_SECRET_KEY=\'(.+)\'/ ){
	$EC2_SECRET_KEY = $1;
};

print $S3_URL . "\n";
print $EC2_ACCESS_KEY . "\n";
print $EC2_SECRET_KEY . "\n";

### mod s3curl.pl

if( -e "./s3curl.pl" ){
	system("rm -fr ./s3curl.pl");
};

system("wget http://$ssip/scriptserver/s3curl.pl");

system("chmod 755 ./s3curl.pl");

my $new_str = "\"" . $s3_ip . "\"";

system("sed --in-place 's/my \@endpoints = .*/my \@endpoints = ( " . $new_str . " );/' ./s3curl.pl");

print "MODED s3curl.pl\n\n";


### create a bucket on Walrus

system("./s3curl.pl --id $EC2_ACCESS_KEY --key $EC2_SECRET_KEY --put /dev/null -- -s -v $S3_URL/$bucketName");

system("./s3curl.pl --id $EC2_ACCESS_KEY --key $EC2_SECRET_KEY --put " . $outputfile . ".avi -- -s -v $S3_URL/$bucketName/$outputfile");

print "Stored $outputfile into WALRUS\n";

#system("halt");


exit(0);




################# SUBROUTINEs #####################

sub get_private_ip_space{
	my $pip = "";
	my $temp = `ifconfig | head -n 5 | grep \"inet \"`;
	if( $temp =~ /addr:(\d+\.\d+\.\d+)\.\d+/ ){
		$pip = $1 . ".0";
	};
	return $pip;
};


sub install_deps{

	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid universe >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid universe >> /etc/apt/sources.list");
	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid-updates universe >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid-updates universe >> /etc/apt/sources.list");

	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid multiverse >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid multiverse >> /etc/apt/sources.list");
	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid-updates multiverse >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid-updates multiverse >> /etc/apt/sources.list");

	system("apt-get update");
	system("apt-get -y --force-yes install nfs-kernel-server mencoder wget libdigest-hmac-perl");
	system("apt-get -y --force-yes install ffmpeg");

	return 0;
};


sub setup_nfs_directory{
	
	my $s_dir = shift @_;

	system("mkdir -p $s_dir");

	system("echo \"$s_dir $nfsip/24(rw,no_root_squash,nohide,insecure,no_subtree_check,async)\" >> /etc/exports");

	system("/etc/init.d/nfs-kernel-server restart");

	return 0;
};

sub generate_images{
	my $infile = shift @_;
	my $s_dir = shift @_;

	system("mkdir -p $s_dir/images");
	system("wget http://$ssip/scriptserver/$infile");
	system("mv ./$infile $s_dir/images/.");
	system("cd $s_dir/images/.; ffmpeg -i $infile image%d.jpg");
	my $f_count = `ls $s_dir/images/*.jpg | wc -l`;
	chomp($f_count);
	
	return $f_count;
};

sub fix_image_names{
	my $s_dir = shift @_;

	opendir( SDIR, "$s_dir" ) or die $!;
	my @images = readdir(SDIR);
	closedir(SDIR);

	foreach my $image ( @images ){
		if( $image =~ /^image(\d+)\.(\w+)/ ){
		#	print $image ." -> ";
			my $new = "image" . sprintf("%08d", $1) . ".jpg";
		#	print $new . "\n";
			system("mv -f $s_dir/$image $s_dir/$new");
		};
	};
};



1;


