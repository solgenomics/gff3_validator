#!/usr/bin/perl

=head1 NAME

validate_gff3.pl

=head1 SYNOPSIS

 validate_gff3.pl -gff3_file <gff3_file> [-ontology_file <ontology_file1> -ontology_file <ontology_file1> ...]
                  -out <out_file_prefix> -config <config_file>
                  [-db_type <db_type>] [-db_name <db_name>] [-username <username>] [-password <password>]
                  [-verbose <0|1|2>] [-silent <0|1>]

=head1 DESCRIPTION

This script analyzes a gff3 file and validates a number of points. It uses the GFF3::Validator module for analysis. For
further information on analysis steps, please refer to validate_gff3.pod.

=head1 USAGE

The script uses a  MySQL or SQLite database to analyze the gff3 file. The gff3 file is parsed and
content relevant to the analysis is loaded into the database. Use of database (as opposed to
performing analysis in memory) makes processing of large files feasible and significatly
increases overall processing speed. At the end of the analysis a
report is generated that lists errors and warnings ordered by line numbers. The report file
can be easily processed using grep and other Unix text processing tools.

The usage of the script follows with descriptions of command-line parameters:

 validate_gff3.pl -gff3_file <gff3_file> [-ontology_file <ontology_file1> -ontology_file <ontology_file1> ...]
                  -out <out_file_prefix> -config <config_file>
                  [-db_type <db_type>] [-db_dir <db_dir>]
                  [-dbname <dbname>] [-username <username>] [-password <password>] 
                  [-verbose <0|1|2>] [-silent <0|1>]

 -gff3_file     : (Required) Name of gff3 file to process.
 -ontology_file : (Optional) Name of ontology file, multiple files can be specified.
                  Command-line ontology files and ontology files provided as directives
                  are merged and used for analysis. If neither is provided or is not accesible,
                  default ontology file is retrieved and used.
 -out           : (Required) Prefix to name log and report files, these become <out>.log and <out>.report
 -config        : (Required) Name of config file (see documentation in validate_gff3.cfg provided in the package
                  for further details).
 -db_type       : (Optional) Type of database ('mysql' or 'sqlite').
                  Defaults to 'mysql'.
 -db_dir        : (Optional) Directory to store temp sqlite database files
                  If not available, retrieved from config file (temp_dir param)
 -dbname        : (Optional) Name of MySQL database/SQLite db file to use for analysis.
                  If not available, retrieved from config file.
                  If db_type is 'sqlite' and no dbname is specified and none available in config file, a temp db is used
 -username      : (Optional) Username for analysis database (must have write privileges).
                  If not available, retrieved from config file.
                  If not available, defaults to "".        
 -password      : (Optional) Password for analysis database.
                  If not available, retrieved from config file.
                  If not available, defaults to "".        
 -verbose       : (Optional) Verbosity of logging.
                  Values:
                  1: Initialization information
                  2: + Progress information
                  3: + Error messages
                  If not available, defaults to 2.        
 -silent        : (Optional) Whether to suppress logging to screen
                  Values:
                  0: Log to screen
                  1: Don't log to screen
                  If not available, defaults to 0.        
 -max_messages  : (Optional) Whether to report all errors/warnings
                  Values:
                  0: Report all messages
                  <number>: Exit and report after <number> messages         
                  If not available, defaults to 0.        

=cut

use strict;

use FindBin;
use File::Spec;
use File::Temp;
use lib "$FindBin::RealBin/lib";

use GFF3::Validator;
use Carp;
use Getopt::Long;

# Usage
my $usage = qq[$FindBin::Script -gff3_file <gff3_file> [-ontology_file <ontology_file1> -ontology_file <ontology_file1> ...]
                  -out <out_file_prefix>
                  [-config <config_file>]
                  [-db_type <db_type>] [-db_dir <db_dir>]
                  [-dbname <dbname>] [-username <username>] [-password <password>] 
                  [-verbose <0|1|2>] [-silent <0|1>]];

# Parse command-line params
my $gff3_file;
my @ontology_files;
my $out;
my $config;
my $db_type;
my $db_dir;
my $dbname;
my $username;
my $password;
my $verbose;
my $silent;
my $max_messages;

my $result = GetOptions ("gff3_file=s"     => \$gff3_file,
                         "ontology_files=s" => \@ontology_files,
                         "out=s"           => \$out,
                         "config=s"        => \$config,
                         "db_type=s"       => \$db_type,
                         "db_dir=s"        => \$db_dir,
                         "dbname=s"        => \$dbname,
                         "username=s"      => \$username,
                         "password=s"      => \$password,        
                         "verbose=s"       => \$verbose,
                         "silent=s"        => \$silent,
                         "max_messages=s"  => \$max_messages,
                         ) or die("Usage: $usage\n");

# Check command-line params
if (!$gff3_file or !$out ) {
    die("Usage: $usage\n");
    }

# Parse config file
$config ||= "$FindBin::RealBin/validate_gff3.cfg";
my $config_obj = Config::General->new(-ConfigFile => $config, -CComments => 0);
my %config = $config_obj->getall;

# Populate defaults from config
$db_type = lc($db_type) || 'mysql';
croak("Unrecognized database type ($db_type)!") unless $db_type =~ /^(mysql|sqlite)$/;

$db_dir ||= $config{temp_dir};
unless( -d $db_dir ) {
  mkdir $db_dir or die "$db_dir does not exist, and can't create it\n";
  chmod 0777, $db_dir or warn "WARNING: could not set global temp dir $db_dir world-writable\n";
}
croak("Cannot determine db dir!") unless $db_dir;

my $datasource;
if ($dbname && $db_type eq 'mysql') {
    $datasource = "DBI:mysql:dbname=$dbname";
    }
elsif ($dbname && $db_type eq 'sqlite') {
    $datasource = "DBI:SQLite:dbname=$dbname";
    }
elsif (!$dbname && $db_type eq 'mysql') {
    $datasource = $config{datasource};
    }
elsif (!$dbname && $db_type eq 'sqlite') {
    my ($temp_fh, $temp_file) = File::Temp::tempfile("validate_gff3_sqlite_XXXXX",
						     DIR     => $db_dir,
						     SUFFIX  => '.db',
						     UNLINK  => 1);

    $datasource = "DBI:SQLite:dbname=$temp_file";
    }
else {
    $datasource = $config{datasource}; # Placeholder
    }    
croak("Cannot determine database name!") unless $datasource;

# Prepare params
my $log_file = "$out.log";
my $report_file = "$out.report";

# Create validator object
my $validator = GFF3::Validator->new(-config         => $config,
                                     -gff3_file      => $gff3_file,
                                     -datasource     => $datasource,
                                     -username       => $username,
                                     -password       => $password,
                                     -verbose        => $verbose,
                                     -silent         => $silent,
                                     -max_messages   => $max_messages,
                                     -log_file       => $log_file,
                                     -report_file    => $report_file,
                                     -ontology_files => \@ontology_files,
                                     -table_id       => "", # Currently do not use table id feature within the command-line version
                                     );

# Create/Reset tables to store the data
$validator->create_tables;

# Load gff3 analysis database
$validator->load_analysis_dbs;

# Validate unique ids
$validator->validate_unique_ids;

# Load ontology(s) into memory
$validator->load_ontology;

# Validate ontology terms
$validator->validate_ontology_terms;

# Validate parentage
$validator->validate_parentage;

# Validate derives_from
$validator->validate_derives_from;

# Dump an error report
$validator->dump_report;

# Cleanup
# $validator->cleanup; # Currently, do not clean up within the command-line version

$validator->log("# [END]");

=head1 SEE ALSO

=head1 AUTHOR

Payan Canaran <canaran@cshl.edu>

=head1 VERSION

$Id: validate_gff3.pl,v 1.1 2007/12/03 14:20:23 canaran Exp $

=head1 CREDITS

- SQLite support adapted from patch contributed by Robert Buels <rmb32@cornell.edu>. 

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2006-2007 Cold Spring Harbor Laboratory

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself. See DISCLAIMER.txt for
disclaimers of warranty.

=cut

1;
