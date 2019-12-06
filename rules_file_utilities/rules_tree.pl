#!/usr/bin/perl
#
# This is a utility for displaying Netcool/OMNIbus rules file "trees"
#
# (C) Copyright IBM Corporation 2019
# SPDX-License-Identifier: MIT
#
# Author: Roger Powell
# Email: rpowell@us.ibm.com
#
#  This is a tool to output the entire list of included files
#  given a "top level" OMNIbus probe rules file
#
#  Read the usage function below for basic command usage
#

#
# Change log
#
# 1.1 -  Initial release
# 1.2 -  Use Cwd to avoid problems with curdir using "."
# 1.3 -  $NC_RULES_HOME might be symlinked
# 1.4 -  Account for $NC_RULES_HOME in table paths
# 1.5 -  Support other environmental variables
#         Add -contents option
# 1.6 -  Show help if no args
# 1.7 -  Add -prepend option
# 1.8 -  Add -nowarning option for unreadable includes
#         (Useful for front-ending a mass edit of paths)
# 1.9 -  Add -incCommented for searching a tree like
#         the NcKL with a lot of commented-out includes
# 1.10 - Add -setroot to support a rules tree with absolute
#        paths that has been copied to a subdirectory
#


# pragmas
use 5.008;		# Backward compatible way to ask for Perl V5.8 or later
use strict;
use warnings;

our $VERSION = "1.10";	# Version of this script

# core Perl modules
use IO::File;
use File::Spec::Functions qw/file_name_is_absolute abs2rel rel2abs/;
use Cwd;

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
print <<'EOT';

rules_tree.pl - Utility to display Netcool/OMNIbus probe rules "trees"

Usage: rules_tree <options> Rulesfile1 [ Rulesfile2 ... ]

  Probe rules files can "include" other probe rules files.  These nested
  trees can make it difficult to do operations like "grep" for a particular
  item in all the files.
  
  Options:
                  
    -help           This message
    -version        Print version
    
    -showtree       Show the entire tree structure, indenting for sub-files
                     (shows a file multiple times if it occurs)
		     
    -showtables     List externally referenced tables too
    
    -print0         Use nulls to separate output.  Useful for input to the
                    xargs command (with -0) when file names contain spaces
		    or newlines

    -contents       Show the actual content of the rules files with the
                    "includes" expanded in place
    
    -prepend        Used with -contents, each line of output is prepended
                    with the file name.  This makes it easy to do things
                    like "grepping" to find which file or files may contain
                    references to an ObjectServer column variable.

    -nowarning      Do not emit a warning message when a referenced include
                    file cannot be read.  This is handy when doing a mass
                    fixup of include paths.

    -incCommented   Follow includes even though they are commented out.
                    This is useful with -contents and -prepend to search
                    the entire NcKL.

    -setroot PATH   Set a directory to serve as the root of the tree.  This
                    is useful when processing a rules tree that has include
                    statements that use absolute paths.

  Examples:
  
    # tar up a rules file and all subfiles it includes (including lookup tables)
    $ rules_tree.pl -showtables FILE | tar cf ARCHIVE -T -

    # Find which files in tree have a reference to the @Location column
    $ rules_tree.pl -contents -prepend | grep @Location 
    
    # Convert all files in tree to use name-value pairs in ExtendedAttr
    # instead of details
    $ rules_tree.pl -print0 FILE | xargs -0 -l details2nvp.pl

EOT
  

exit;
}

our $opt_help = 0;
our $opt_version = 0;
our $opt_showtree = 0;
our $opt_showtables = 0;
our $opt_print0 = 0;
our $opt_contents = 0;
our $opt_prepend = 0;
our $opt_nowarning = 0;
our $opt_incCommented = 0;
our $opt_setroot = "";

use Getopt::Long;
GetOptions(
  "help" => \$opt_help,
  "version" => \$opt_version,
  "showtree" => \$opt_showtree,
  "showtables" => \$opt_showtables,
  "print0" => \$opt_print0,
  "contents" => \$opt_contents,
  "prepend" => \$opt_prepend,
  "nowarning" => \$opt_nowarning,
  "incCommented" => \$opt_incCommented,
  "setroot=s" => \$opt_setroot,
) or usage();

if ($opt_help) {
  usage();
}
if ($opt_version) {
  print "Version: $VERSION\n";
  exit 0;
}

# Consistency check
if ($opt_contents && ($opt_showtree || $opt_print0 || $opt_showtables)) {
  usage("Use of -contents inconsistent with other options");
}
if ($opt_prepend && !$opt_contents) {
  usage("The -prepend option only makes sense when -contents used");
}

# If -setroot used, check for valid path
if ($opt_setroot) {
  fatal("Option -setroot '$opt_setroot' is not a valid directory")
    unless -d $opt_setroot;
}

# Show help if (after checking other args) no files specified
unless (@ARGV) {
  usage();
}

# Globals
our %filenames_seen = ();
our $display_absolute_names;
our $starting_dir = cwd();
our $output_separator = $opt_print0 ? chr(0) : "\n";
our $indent_increment = $opt_print0 ? "" : "   ";
our %translated_envvars = ();

# Convenience subroutines
sub fatal {
  print "*** Fatal Error: ", join("\n",@_), "\n";
  exit 1;
}

sub warning {
  print "*** Warning: ", join("\n",@_), "\n";
}



## Main program

# Special case:
# If NC_RULES_HOME not set in environment, assume for the moment that it
# is the working directory - this allows descending trees that have been
# wholly copied to other systems
$ENV{NC_RULES_HOME} ||= cwd();


# Loop over all the files on the command line
for my $filename (@ARGV) {
  # Set flag for this whole tree.  Use absolute or relative
  # display based on whether the file name on the command
  # line was absolute or relative
  $display_absolute_names = file_name_is_absolute($filename);
  process_file($filename, "");
}

# Recursive subroutine to process a file
sub process_file {
  my ($filename, $indent) = @_;  

  # Internally, we deal with absolute names but print out
  # based on whether the supplied name was abs or rel
  $filename = rel2abs($filename);
  my $printed_filename = $filename;
  $printed_filename = abs2rel($filename, $starting_dir) unless $display_absolute_names;
 
  # Only process a given file once, unless we are doing the "tree" output
  return if (exists $filenames_seen{$filename} && !$opt_showtree && !$opt_contents);
  $filenames_seen{$filename} = 1;
  
  # Time to print this filename out
  print $indent, $printed_filename, $output_separator unless $opt_contents;
  $indent = "$indent_increment$indent" if $opt_showtree;
    
  # Open the file and scan it for includes (and maybe external tables)
  my $fh = new IO::File $filename;
  unless ($fh) {
    warning("Unable to open '$filename': $!") unless $opt_nowarning;
    return;
  }
  # Adjust the regular expressions we use based on whether we are
  # going to follow commented out stuff too
  my $iRE = $opt_incCommented ? qr/^\s*#?\s*include\s+"(.*)"/ : qr/^\s*include\s+"(.*)"/;
  my $tRE = $opt_incCommented ? qr/^\s*#?\s*table\s+\S+\s*=\s*"(.*)"/ : qr/^\s*table\s+\S+\s*=\s*"(.*)"/;

  while (my $line = <$fh>) {
    if ($line =~ $iRE) {
      if (my $includename = expand_envvars( $1, $filename)) {
        process_file( $includename, $indent);
      }
    }
    elsif ($opt_showtables and $line =~ $tRE) {
      my $tablename = expand_envvars( $1, $filename);
      $tablename = rel2abs($tablename);
      unless (exists $filenames_seen{$tablename} && !$opt_showtree) {
        $filenames_seen{$tablename} = 1;
        $tablename = abs2rel($tablename, $starting_dir) unless $display_absolute_names;
        print $indent, $tablename, $output_separator;
      }
    }
    elsif ($opt_contents) {
      print $printed_filename, ": " if $opt_prepend;
      print "$line";
    }
  }
  $fh->close;
}

# Subroutine to expand environmental variables in paths
# Return a blank path if there were errors
#
# Now also handles the -setroot option for absolute paths
#
sub expand_envvars {
  my ($path, $current_filename) = @_;
  
  # Handle the case of absolute paths with -setroot
  if (file_name_is_absolute($path) and $opt_setroot) {
    $path =~ s<^.><$opt_setroot/>;
  }

  # At most only one ENV variable in a path  
  elsif ($path =~ /\$(\w+)/) {
    my $envvar = $1;
    
    # Look up env var unless it's already cached
    unless ($translated_envvars{$envvar}) {
      my $dir = $ENV{$envvar}
        or do {
              warning("Environmental variable '$envvar' (referenced in $current_filename) is not set");
              return ""; 
              };
      chdir $dir
        or do {
              warning("Environmental variable '$envvar' (referenced in $current_filename) set to '$dir'",
                  "This does not seem to be a legal directory");
              return ""; 
              };
      $translated_envvars{$envvar} = cwd();  # expunges symbolic links
      chdir $starting_dir;  
    }
    $path =~ s<\$$envvar><$translated_envvars{$envvar}>;
  }
  return $path;
}
