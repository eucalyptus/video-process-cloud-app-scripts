#!/usr/bin/perl -w

# This software code is made available "AS IS" without warranties of any
# kind.  You may copy, display, modify and redistribute the software
# code either by itself or as incorporated into your code; provided that
# you do not remove any proprietary notices.  Your use of this software
# code is at your own risk and you waive any claim against Amazon
# Digital Services, Inc. or its affiliates with respect to your use of
# this software code. (c) 2006 Amazon Digital Services, Inc. or its
# affiliates.

use strict;
use POSIX;

# you might need to use CPAN to get these modules.
# run perl -MCPAN -e "install <module>" to get them.

use Digest::HMAC_SHA1;
use FindBin;
use MIME::Base64 qw(encode_base64);
use Getopt::Long qw(GetOptions);

use constant STAT_MODE => 2;
use constant STAT_UID => 4;

# begin customizing here
my @endpoints = ( 's3.amazonaws.com' );

my $CURL = "curl";

# stop customizing here

my $cmdLineSecretKey;
my %awsSecretAccessKeys = ();
my $keyFriendlyName;
my $keyId;
my $secretKey;
my $contentType = "";
my $acl;
my $fileToPut;
my $createBucket;
my $doDelete;
my $doHead;
my $debug = 0;

my $DOTFILENAME=".s3curl";
my $EXECFILE=$FindBin::Bin;
my $LOCALDOTFILE = $EXECFILE . "/" . $DOTFILENAME;
my $HOMEDOTFILE = $ENV{HOME} . "/" . $DOTFILENAME;
my $DOTFILE = -f $LOCALDOTFILE? $LOCALDOTFILE : $HOMEDOTFILE;

if (-f $DOTFILE) {
    open(CONFIG, $DOTFILE) || die "can't open $DOTFILE: $!"; 

    my @stats = stat(*CONFIG);

    if (($stats[STAT_UID] != $<) || $stats[STAT_MODE] & 066) {
        die "I refuse to read your credentials from $DOTFILE as this file is " .
            "readable by, writable by or owned by someone else. Try " .
            "chmod 600 $DOTFILE";
    }

    my @lines = <CONFIG>;
    close CONFIG;
    eval("@lines");
    die "Failed to eval() file $DOTFILE:\n$@\n" if ($@);
} 

GetOptions(
    'id=s' => \$keyId,
    'key=s' => \$cmdLineSecretKey,
    'contentType=s' => \$contentType,
    'acl=s' => \$acl,
    'put=s' => \$fileToPut,
    'delete' => \$doDelete,
    'createBucket:s' => \$createBucket,
    'head' => \$doHead,
    'debug' => \$debug
);

die "Usage $0 --id AWSAccessKeyId (or friendly name) [--key SecretAccessKey (unsafe)] [--contentType text/plain] [--acl public-read] [--put index.html | --createBucket [Location constraint e.g. \"EU\"]| --head] -- [curl-options]" 
  unless defined $keyId;

if ($cmdLineSecretKey) {

    print STDERR <<END_WARNING;
WARNING: It isn't safe to put your AWS secret access key on the
command line!  The recommended key management system is to store
your AWS secret access keys in a file owned by, and only readable
by you.

For example:

\%awsSecretAccessKeys = (
    # personal account
    personal => {
        id => '1ME55KNV6SBTR7EXG0R2',
        key => 'zyMrlZUKeG9UcYpwzlPko/+Ciu0K2co0duRM3fhi',
    },

    # corporate account
    company => {
        id => '1ATXQ3HHA59CYF1CVS02',
        key => 'WQY4SrSS95pJUT95V6zWea01gBKBCL6PI0cdxeH8',
    },
);

\$ chmod 600 $DOTFILE

Will sleep and continue despite this problem.
Please set up $DOTFILE for future requests.
END_WARNING

    sleep 5;

    $secretKey = $cmdLineSecretKey;
} else {
    my $keyinfo = $awsSecretAccessKeys{$keyId};
    die "I don't know about key with friendly name $keyId. " .
        "Do you need to set it up in $DOTFILE?"
        unless defined $keyinfo;

    $keyId = $keyinfo->{id};
    $secretKey = $keyinfo->{key};
}

my $method = "";
if (defined $fileToPut or defined $createBucket) {
    $method = "PUT";
} elsif (defined $doDelete) {
    $method = "DELETE";
} elsif (defined $doHead) {
    $method = "HEAD";
} else {
    $method = "GET";
}

my $contentMD5 = "";
my $resource;

# try to understand curl args
for my $arg (@ARGV) {
    # resource name
    if ($arg =~ /https?:\/\/([^\/:]+)(?::(\d+))?([^?]*)(?:\?(\S+))?/) {
        my $host = $1;
        my $port = defined $2 ? $2 : "";
        my $requestURI = $3;
        my $query = defined $4 ? $4 : "";
        debug("Found the url: host=$host; port=$port; uri=$requestURI; query=$query;");
        if (length $requestURI) {
            $resource = $requestURI;
        } else {
            $resource = "/";
        }
        for my $attribute ("acl", "torrent", "location", "logging") {
            if ($arg =~ /[?&]$attribute(=|&|$)/) {
                $resource = "$resource?$attribute";
                last;
            }
        }
        # handle virtual hosted requests
        getResourceToSign($host, \$resource);
    }
    if ($arg =~ /\-X/) {
        $method = "DELETE"; # cheesy
    }
}

die "Couldn't find resource by digging through your curl command line args!"
    unless defined $resource;


my $httpDate = POSIX::strftime("%a, %d %b %Y %H:%M:%S +0000", gmtime );
my $aclHeaderToSign = defined $acl ? "x-amz-acl:$acl\n" : "";
my $stringToSign = "$method\n$contentMD5\n$contentType\n$httpDate\n$aclHeaderToSign$resource";

debug("StringToSign='" . $stringToSign . "'");
my $hmac = Digest::HMAC_SHA1->new($secretKey);
$hmac->add($stringToSign);
my $signature = encode_base64($hmac->digest, "");


my @args = ();
push @args, ("-H", "Date: $httpDate");
push @args, ("-H", "Authorization: AWS $keyId:$signature");
push @args, ("-H", "x-amz-acl: $acl") if (defined $acl);
push @args, ("-L");
push @args, ("-H", "content-type: $contentType") if (defined $contentType);
push @args, ("-H", "Content-MD5: $contentMD5") if (length $contentMD5);
push @args, ("-T", $fileToPut) if (defined $fileToPut);
push @args, ("-X", "DELETE") if (defined $doDelete);
push @args, ("-I") if (defined $doHead);

# createBucket is a special kind of put from stdin. Reason being, curl mangles the Request-URI
# to include the local filename when you use -T and it decides there is no remote filename (bucket PUT)
if (defined $createBucket) {
    my $data="";
    if (length($createBucket)>0) {
        $data="<CreateBucketConfiguration><LocationConstraint>$createBucket</LocationConstraint></CreateBucketConfiguration>";
    }
    push @args, ("--data-binary", $data);
    push @args, ("-X", "PUT");
}
   

push @args, @ARGV;

debug("exec $CURL " . join (" ", @args));
exec($CURL, @args)  or die "can't exec program: $!";

sub debug {
    my ($str) = @_;
    $str =~ s/\n/\\n/g;
    print STDERR "s3curl: $str\n" if ($debug);
}

sub getResourceToSign {
    my ($host, $resourceToSignRef) = @_;
    for my $ep (@endpoints) {
        if ($host =~ /(.*)\.$ep/) { # vanity subdomain case
            my $vanityBucket = $1;
            $$resourceToSignRef = "/$vanityBucket".$$resourceToSignRef;
            debug("vanity endpoint signing case");
            return;
        }
        elsif ($host eq $ep) { 
            debug("ordinary endpoint signing case");
            return;
        }
    }
    # cname case
    $$resourceToSignRef = "/$host".$$resourceToSignRef;
    debug("cname endpoint signing case");
}


