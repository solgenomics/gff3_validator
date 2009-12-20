use strict;
use Module::Build;
use File::Find;

my $build = Module::Build->new(
    dist_name          => 'GFF3-Validator-cxgncustom',
    dist_author        => 'Wormbase',
    dist_abstract      => 'script and libraries for validating GFF3 files',
    license            => 'perl',
    create_makefile_pl => 'passthrough',

    # current version of our core libraries distribution
    dist_version => '0.1',

    recursive_test_files => 1,

    script_files => ['validate_gff3.pl'],

    # and now the list of perl module dependencies
    requires => {
        'perl'            => '5.6.1',
        'CGI::Session'    => 0,
        'Config::General' => 0,
        'DBI'             => 0,
        'Digest::SHA1'    => 0,
        'File::Temp'      => 0,
        'FindBin::Real'   => 0,
        'GO::Parser'      => 0,
        'List::Util'      => 0,
        'LWP'             => 0,
        'Tie::IxHash'     => 0,
        'Time::Format'    => 0,
    },
);
$build->create_build_script;

