#!/usr/bin/perl

use strict;
use POSIX;

local $| = 1;

my $FRAME_RANGE_PER_JOB = 20;


#############################################
### Handle the arguments                  ###
#############################################

my $launchindex = `curl http://169.254.169.254/latest/meta-data/ami-launch-index`;

print "\nLAUNCH INDEX\n";
print $launchindex . "\n";					### not used

my $userdata = `curl http://169.254.169.254/latest/user-data`;

print "\nUSER-DATA\n";
print $userdata . "\n";

my $arguments = "";
my $ssip = "";

if( $userdata =~ /(.+)\s+([\d\.]+)\s+\[(.+)\]/ ){
	$ssip = $2;
	$arguments = $3;

	print "Script Server IP:\t$ssip\n";
	print "Arguments:\t$arguments\n";
}else{
	print "NO ARGUMENTS !!\n";
	exit(1);
};


my $nfsip = "";
my $filter_script = "";

### USED FOR DEBUGGING 
#$ssip = "192.168.51.150";
#$nfsip = "10.219.1.3";
#$filter_script = "threshold.scm";


if( $arguments =~ /([\d+|\.]+)\s+(\S+)/ ){
	$nfsip = $1;
	$filter_script = $2;

	print "NFS IP:\t$nfsip\n";
	print "FILTER SCRIPT:\t$filter_script\n";
}else{
	print "\n";
	print "ERROR in USER-DATA !!\n";
	exit(1);
};
print "\n";


#############################################
### Get the IP of the instance            ###
#############################################

my $myip = get_my_ip();
print "\n";


#############################################
### Install GIMP                          ###
#############################################

install_gimp();
print "\n";


#########################################
### Create and Mount Storage          ###
#########################################

my $mnt_dir = "/tmp/storage";

mount_nfs_from_collector($nfsip, $mnt_dir);
print "\n";


#########################################
### Read Render Information           ###
#########################################

my $job_dir = $mnt_dir . "/jobs";
my $info_file = $job_dir . "/job.info";
my $frame_range_per_job = $FRAME_RANGE_PER_JOB;

my $inputfile = "";
my $t_frames = 0;
my $outputfile = "";

get_render_job_information($info_file, \$inputfile, \$t_frames);

if( $inputfile eq "" || $t_frames == 0 ){
	print "ERROR!!Invalid Job Information !!\n\n";
	print "INPUT FILE:\t$inputfile\n";
	print "TOTAL FRAMES:\t$t_frames\n";
	exit(1);
};

if( $inputfile =~ /(.+)\.\w+/ ){
#	$outputfile = $1 . "_frame_";
};

print "\n";
print "INPUT FILE:\t$inputfile\n";
print "TOTAL FRAMES:\t$t_frames\n";
#print "OUTPUT FILE:\t$outputfile\n";
print "\n";

#############################################
### Download Filter Script                ###
#############################################

if( !(-e "./$filter_script") ){
	print "\n";
	print("wget http://$ssip/scriptserver/$filter_script\n");
	system("wget http://$ssip/scriptserver/$filter_script");
	print "\n";

	print("wget http://$ssip/scriptserver/invert.scm\n");		### hack
	system("wget http://$ssip/scriptserver/invert.scm");
	print "\n";

	print("wget http://$ssip/scriptserver/mblur.scm\n");		### hack
	system("wget http://$ssip/scriptserver/mblur.scm");
	print "\n";

	print("wget http://$ssip/scriptserver/gblur.scm\n");		### hack
	system("wget http://$ssip/scriptserver/gblur.scm");
	print "\n";

};


#############################################
### Start the Job                         ###
#############################################

print "\n";
print "===============================================";
print " Starting the Filtering Job ";
print "===============================================";
print "\n";
print "\n";

my $start_index = 0;
my $end_index = 0;

my $is_done = 0;

while( get_job_range($job_dir, $frame_range_per_job, \$start_index, \$end_index) == 0 ){

	my $this_job_file = get_job_file_name($start_index, $end_index);

	my $is_taken = 0;
	$is_taken = mark_the_job($job_dir, $this_job_file, $myip);

	if( $is_taken == 0 ){
		#############################################
		### Start gimp for filtering           ###
		#############################################
		start_gimp($filter_script, $mnt_dir, $start_index, $end_index);

		finish_the_job($job_dir, $this_job_file);
	};

	print "\n";
	print "\n";
	print "\n";

	sleep(5);
};


#############################################
### Finished Rendering                    ###
#############################################

print "Finished Rendering\n";

system("halt");

exit(0);



###################### SUBROUTINEs #############################


sub get_my_ip{
	my $ip = "";
	my $temp = `ifconfig | head -n 5 | grep \"inet \"`;
	if( $temp =~ /addr:(\d+\.\d+\.\d+\.\d+)/ ){
		$ip = $1;
	};
	return $ip;
};

sub install_gimp{
	
	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid universe >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid universe >> /etc/apt/sources.list");
	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid-updates universe >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid-updates universe >> /etc/apt/sources.list");

	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid multiverse >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid multiverse >> /etc/apt/sources.list");
	system("echo deb http://us.archive.ubuntu.com/ubuntu/ lucid-updates multiverse >> /etc/apt/sources.list");
	system("echo deb-src http://us.archive.ubuntu.com/ubuntu/ lucid-updates multiverse >> /etc/apt/sources.list");

	system("apt-get update");
	system("apt-get -y --force-yes install gimp wget nfs-common");
	return 0;
};


sub mount_nfs_from_collector{
	my $ip = shift @_;
	my $dir = shift @_;

	if( -e $dir ){
		system("umount $dir");
		sleep(1);
	};

	system("mkdir -p $dir");

	print "\n";
	print "Mounting NFS directory from Collector:\n";
	print("mount $ip:/export/storage $dir\n");
	system("mount $ip:/export/storage $dir");
	print "\n";

	return 0;
};

sub get_render_job_information{

	my $infile = shift @_;
	my $inputfile_ref = shift @_;
	my $t_frames_ref = shift @_;

	my $line;
	open(JOB, "< $infile") or die $!;
	while($line = <JOB>){
		chomp($line);
		if( $line =~ /^Input File:\s+(\S+)/ ){
			$$inputfile_ref = $1;
		}elsif( $line =~ /^Total Frames:\s+(\d+)/ ){
			$$t_frames_ref = $1;
		};
	};
	close(JOB);

	return 0;
};

sub get_job_range{

	my $j_dir = shift @_;
	my $this_frame_range = shift @_;
	my $start_index_ref = shift @_;
	my $end_index_ref = shift @_;

	my @temps = ();
	my @jobs_array = ();

	print "\n";
	print "*** Scanning Job Directory \'$j_dir\' for New Rendering Job ***\n";
	print "\n";

	opendir( JDIR, "$j_dir" ) or die $!;
	@temps = readdir(JDIR);
	closedir(JDIR);

	foreach my $t ( sort @temps ){
		if( $t =~ /^(\S+)_from_(\d+)_to_(\d+)\.job/ ){
			push(@jobs_array, $t);
		};
	};

	my $j_count = @jobs_array;

	my $last_job = $jobs_array[$j_count-1];
	my $last_index = 0;

	print "\n";
	print "Found Last Job:\t$last_job\n";
	print "\n";

	if( $last_job =~ /^(\S+)_from_(\d+)_to_(\d+)\.job/ ){
		$last_index = $3;
	};

	my $this_index = $last_index + 1;

	if( $this_index >= $t_frames ){
		print "ALL JOBS HAVE BEEN ASSIGNED\n\n";
		return 1;
	};

	my $this_last_index = $this_index + $this_frame_range;

	if( $this_last_index > $t_frames ){
		$this_last_index = $t_frames;
	};

	print "Assigning\n";
	print "Start Index:\t$this_index\n";
	print "End Index:\t$this_last_index\n";
	print "\n";

	if( $this_index == 0 || $this_last_index == 0 || $this_index >= $t_frames || $this_last_index > $t_frames ){
		print "ERROR!! in Computing Start Index and End Index!! \n\n";
		exit(1);
	};

	$$start_index_ref = $this_index;
	$$end_index_ref = $this_last_index;

	return 0;
};

sub get_job_file_name{

	my $s_index = shift @_;
	my $e_index = shift @_;

	my $job_file = "render_from_" . sprintf("%08d", $s_index) . "_to_" . sprintf("%08d", $e_index) . ".job";

	print "\n";
	print "New Job File:\t" . $job_file . "\n";
	print "\n";

	return $job_file;
};


sub mark_the_job{

	my $j_dir = shift @_;
	my $j_file = shift @_;
	my $ip = shift @_;	

	if( -e "$j_dir/$j_file" ){
		print "WARNING! This Job \"$j_file\" is Taken!\n\n";
		return 1;
	};

	system("touch $j_dir/$j_file");
	system("echo \"$ip\" >> $j_dir/$j_file");

	my $start_time = `date`;
	chomp($start_time);
	system("echo \"START_TIME: $start_time\" >> $j_dir/$j_file");

	return 0;
};


sub start_gimp{

	my $filter = shift @_;
	my $m_dir = shift @_;
	my $f_start = shift @_;
	my $f_end = shift @_;

	print "\n";
	print "##########";
	print " Starting GIMP ";
	print "##########";
	print "\n";
	print "\n";

	print "FILTER_SCRIPT:\t$filter\n";
	print "MOUNT_DIR:\t$m_dir\n";
	print "FRAME_START:\t$f_start\n";
	print "FRAME_END:\t$f_end\n";
	print "\n";

	my $script = "";
	if( $filter =~ /(\S+)\.scm/ ){
		$script = $1;
	};

	if( !(-e "/root/.gimp-2.6/scripts") ){
		print "mkdir -p /root/.gimp-2.6/scripts\n";
		system("mkdir -p /root/.gimp-2.6/scripts");
		print "\n";
	};

	print "cp ./*.scm /root/.gimp-2.6/scripts/.\n";
	system("cp ./*.scm /root/.gimp-2.6/scripts/.");
	print "\n";
	
	print "mkdir -p ./temp/$f_start\n";
	system("mkdir -p ./temp/$f_start");
	print "\n";

	for(my $i=$f_start; $i<=$f_end; $i++){
		print "cp $m_dir/images/image$i.jpg ./temp/$f_start/.\n";
		system("cp $m_dir/images/image$i.jpg ./temp/$f_start/.");
	};
	print "\n";
	print "\n";

	if( $script eq "threshold"){
		print "cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 170 255)' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 170 255)' -b '(gimp-quit 0)'");
	}elsif( $script eq "softglow" ){
		print "cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 10 0.75 0.85)' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 10 0.75 0.85)' -b '(gimp-quit 0)'");
	}elsif( $script eq "neon" ){

		print "cd ./temp/$f_start;  gimp -i -b '(mblur \"*.jpg\" 2 20 5 320 240 )' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '(mblur \"*.jpg\" 2 20 5 320 240 )' -b '(gimp-quit 0)'");
		sleep(1);
	
		print "cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 15.0 0.0)' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 15.0 0.0)' -b '(gimp-quit 0)'");
		sleep(1);
	}elsif( $script eq "edge" ){

#		print "cd ./temp/$f_start;  gimp -i -b '(mblur \"*.jpg\" 2 20 5 320 240 )' -b '(gimp-quit 0)'\n";
#		system("cd ./temp/$f_start;  gimp -i -b '(mblur \"*.jpg\" 2 20 5 320 240 )' -b '(gimp-quit 0)'");
#		sleep(1);

		print "cd ./temp/$f_start;  gimp -i -b '(gblur \"*.jpg\" 5.0 5.0 1 )' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '(gblur \"*.jpg\" 5.0 5.0 1 )' -b '(gimp-quit 0)'");
		sleep(1);
	
		print "cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 2.0 2 0)' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '($script \"*.jpg\" 2.0 2 0)' -b '(gimp-quit 0)'");
		sleep(1);

#		print "cd ./temp/$f_start;  gimp -i -b '(invert \"*.jpg\")' -b '(gimp-quit 0)'\n";
#		system("cd ./temp/$f_start;  gimp -i -b '(invert \"*.jpg\")' -b '(gimp-quit 0)'");
	}elsif( $script eq "mblur" ){

		print "cd ./temp/$f_start;  gimp -i -b '(mblur \"*.jpg\" 1 5 5 960 540 )' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '(mblur \"*.jpg\" 1 5 5 960 540 )' -b '(gimp-quit 0)'");
		sleep(1);

	}elsif( $script eq "invert" ){
		print "cd ./temp/$f_start;  gimp -i -b '(invert \"*.jpg\")' -b '(gimp-quit 0)'\n";
		system("cd ./temp/$f_start;  gimp -i -b '(invert \"*.jpg\")' -b '(gimp-quit 0)'");
		sleep(1);

	};

	print "\n";
	
	sleep(3);

	print "cp ./temp/$f_start/*.jpg $m_dir/.\n";
	system("cp ./temp/$f_start/*.jpg $m_dir/.");
	print "\n";

	print "\n";
	print "##########";
	print " Finished GIMP ";
	print "##########";
	print "\n";
	print "\n";

	return 0;
};

sub finish_the_job{

	my $j_dir = shift @_;
	my $j_file = shift @_;

	my $end_time = `date`;
	chomp($end_time);
	system("echo \"END_TIME: $end_time\" >> $j_dir/$j_file");

	return 0;
};


1;
