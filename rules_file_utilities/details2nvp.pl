#!/usr/bin/perl
#
# (C) Copyright IBM Corporation 2019
# SPDX-License-Identifier: MIT
#
# Author: Roger Powell
# Email: rpowell@us.ibm.com
#
#  This is a utility for changing Netcool/OMNIbus rules files
#  It removes references to "Details" and replaces them with
#  the nvp_add function on the @ExtendedAttr column
#
#  Read the usage function below for basic command usage
#

#
# Change log
#
# 1.1 - First release
# 1.2 - Put /usr/bin/perl in header, fix usage
# 1.3 - Don't replace the file if no changes, add final comment
#        on what was done, and -quiet option if comment unwanted
# 1.4 - Standardize on ".pl" in examples so this works in Windows too
#

# pragmas
use 5.008;		# Backward compatible way to ask for Perl V5.8 or later
use strict;
use warnings;

our $VERSION = "1.4";	# Version of this script

# core Perl modules
use Data::Dumper;
use IO::File;
use File::Temp qw/tempfile/;
use File::Spec::Functions qw/curdir/;

# Read the 'here' document to see what help is
# provided to the user
#
sub usage {
  my $errmsg = shift;
  if ($errmsg) {
    print STDERR "$errmsg\n" ;
    print STDERR "Try -help for usage info\n";
    exit 1;
  }

# Only come here when -help flag specified
print <<EOT;

details2nvp.pl - Utility to convert Netcool/OMNIbus probe rules

Usage: details2nvp.pl <options> rulesfile 

  This converts a rules file, replacing "details" statements with statements
  that add the same data as name-value pairs in the ExtendedAttr column.
  The original file is saved with ".bak" appended to the name.
  
  Options:
                  
    -help           This message
    -version        Print version

    -backup <FILE>  Name of backed-up original (by default it is the old
                     name with .bak appended)
    
    -nobackup       Don't save the original
    
    -quiet          No comment on what was done

EOT

exit;
}

our $opt_help = 0;
our $opt_version = 0;
our $opt_backup = '';
our $opt_nobackup = 0;
our $opt_quiet = 0;

use Getopt::Long;
GetOptions(
  "help" => \$opt_help,
  "version" => \$opt_version,
  "backup=s" => \$opt_backup,
  "nobackup" => \$opt_nobackup,
  "quiet" => \$opt_quiet
) or usage();

if ($opt_help) {
  usage();
}
if ($opt_version) {
  print "Version: $VERSION\n";
  exit 0;
}

unless (@ARGV == 1) {
  usage();
}


# Convenience subroutine
sub fatal {
  print "*** Fatal Error: ", join("\n",@_), "\n";
  exit 1;
}


# Main program
our $changes = 0;
our $filename = $ARGV[0];
our $infile = new IO::File $filename 
  or fatal("Unable to open '$filename':$!");
  
my ($tmpfile, $tmpfilename) = tempfile( "tmprules_XXXX", DIR => curdir());

while (my $line = <$infile>) {
  if ($line =~ /^(\s*)details\(\s*(.*)\s*\)/) {
    $changes++;
    my ($indent, $details) = ($1, $2);
    $line =~ s/details/# details/;
    print $tmpfile $line;
    if ($details eq '$*') {
      print $tmpfile $indent, "\@ExtendedAttr = nvp_add(\$*)\n";
    }
    else {
      my @details = split /,/, $details;
      print $tmpfile $indent, qq{\@ExtendedAttr = nvp_add(\@ExtendedAttr};
      for my $detail (@details) {
        (my $dname = $detail) =~ s<^\$><>;
        print $tmpfile qq{, "$dname", $detail};
      }
      print $tmpfile ")\n";
    }
  }
  else {
    print $tmpfile $line;
  }
}
close $tmpfile;
close $infile;

# Now replace the old file with the new temp file
# but only if changes were made
if ($changes) {
  if ($opt_nobackup) {
    unlink $filename
      or fatal("Unable to delete '$filename' prior to renaming '$tmpfilename' to that name: $!");
    print "$filename changed\n" unless $opt_quiet;    
  }
  else {
    $opt_backup ||= "$filename.bak";
    if (-f $opt_backup) {
      unlink $opt_backup
        or fatal("Unable to delete old backup file '$opt_backup': $!");
    }
    rename $filename, $opt_backup
      or fatal("Unable to rename '$filename' to '$opt_backup': $!");
    print "$filename changed - original backed up to $opt_backup\n" unless $opt_quiet;
  }
  rename $tmpfilename, $filename
    or fatal("Unable to rename '$tmpfilename' to '$filename': $!");
}
else {
  # Just toss the temp copy
  unlink $tmpfilename;
  print "$filename unchanged\n" unless $opt_quiet;
}
