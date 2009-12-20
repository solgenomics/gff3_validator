package GFF3::Online;

=head1 NAME

GFF3::Online

=head1 SYNOPSIS

 # Create validator object
 my $validator = GFF3::Validator->new(-config         => $config,
                                      -gff3_file      => $gff3_file,
                                      -datasource     => $datasource,
                                      -username       => $username,
                                      -password       => $password,
                                      -verbose        => $verbose,
                                      -silent         => $silent,
                                      -log_file       => $log_file,
                                      -report_file    => $report_file,
                                      -ontology_files => \@ontology_files,
                                      );

 # Create/Reset tables to store the data
 $validator->create_tables;

=head1 DESCRIPTION

...

=cut

=head1 USAGE

This module is not used directly. Please see documentation for validate_gff3.pl for usage.

=cut

use lib "/home/canaran/canaran/gff3_validator/lib";
use strict;
use GFF3::Validator;
use Config::General;
use Tie::IxHash;
use Data::Dumper;
use FindBin::Real;
use CGI qw/:standard/;
use CGI::Session;
use File::Temp;
use Time::Format qw(%time);

=head1 METHODS

=head2 Constructor

=head3 new

The following parameters can be provided to the constructor:

 Parameter        Description                                             Default
 ---------        -----------                                             -------
 -config          Config file                                             n/a

=cut

sub new {
    my ($class, %params) = @_;

    # Create and bless object
    my %obj = {};
    my $self = bless \%obj, $class;

    # First read config file, parse and store it
    my $config = $params{-config} or croak("A config must be specified!");
    tie my %config, "Tie::IxHash";
    %config = Config::General::ParseConfig(-ConfigFile      => $config, 
                                           -Tie             => "Tie::IxHash",
                                           -BackslashEscape => 1
                                           );
    $self->{config} = \%config;

    # Clean temp dirs
    $self->_clean_temp_dirs;

    # Enable uploads and limit post size
    $CGI::POST_MAX = $self->config("gff3_file_size_limit"); # Max post size is provided in bytes in the config file
    $CGI::DISABLE_UPLOADS = 0;

    # Create CGI object and store it
    my $cgi = CGI->new;

    $self->{cgi} = $cgi;

    my $internal_css = $self->_internal_css;

    # Start HTML
    print $cgi->header;
    print $cgi->start_html(-title=>'GFF3 Validator',
                           -style=>{-src  => $self->config("css"),
                                    -code => $internal_css},
                           -head=>$cgi->meta({-http_equiv => 'CACHE-CONTROL',
                                              -content    => 'NO-CACHE'}),
                           );

    # Check CGI errors (POST_MAX errors)
    if ($cgi->cgi_error) {
        $self->error($cgi->cgi_error);
        }

    # Read session id if provided
    my $session_id = $cgi->param("session_id");

    # Read session_dir
    my $session_dir = $self->config("session_dir");

    # Error if the provided session does not exist eanymore
#    if ($session_id and ! -e "$session_dir/cgisess_$session_id") {
#        $self->error("This session ($session_id) does not exist, please re-run your analysis!");
#        }

    # Create Session object and store it
    my $session = CGI::Session->new("driver:file", $session_id, {Directory => $session_dir})
                  or $self->error(CGI::Session->errstr);
    $self->{session} = $session;

    return $self;
    }

=head2 Get/Set Methods

=head3 config

 Function  : Gets config value
 Arguments : $key
 Returns   : $value
 Notes     :

=cut

sub config {
	my ($self, $key) = @_;

    $self->error("Unknown config key ($key)!") unless exists $self->{config}->{$key};

    return $self->{config}->{$key};
	}

=head3 session

 Function  : Gets Session object
 Arguments : None
 Returns   : $session
 Notes     :

=cut

sub session {
	my ($self) = @_;

    my $value = $self->{session};

    return $value;
	}

=head3 javascript

 Function  : Gets/sets javascript
 Arguments : [$value]
 Returns   : $value
 Notes     :

=cut

sub javascript {
	my ($self, $value) = @_;

    if (defined $value) {
        $self->{javascript} = $value;
        }

    $value = $self->{javascript};

    return $value;
	}

=head3 cgi

 Function  : Gets CGI object
 Arguments : None
 Returns   : $cgi
 Notes     :

=cut

sub cgi {
	my ($self) = @_;

    my $value = $self->{cgi};

    return $value;
	}

=head3 display

 Function  : Reads CGI params, processes files and
             generates necessary displays
 Arguments : None
 Returns   : 1
 Notes     :

=cut

sub display {
    my ($self) = @_;

    # Read CGI and Session objects
    my $cgi = $self->cgi;
    my $session = $self->session;

    # Is Javascript on?
    my $javascript = $cgi->param("javascript") eq "on" ? 1 : 0;
    $self->javascript($javascript);

    # If an error occurred, exit with an error (typically due to an attempt to upload a large file)
    if ($cgi->cgi_error) {
        $self->error($cgi->cgi_error);
        }

    # Perform proessing and display based on page type
    my $submit_upload = $cgi->param('submit_upload');
    my $submit_url = $cgi->param('submit_url');    
    my $page_type = $cgi->param('page_type');    
    
    if ($submit_upload) {
        my $uploaded_file = $cgi->param("uploaded_file") or $self->error("File to upload must be specified!");

        print $self->progress_list if $javascript;

        my $gff3_file = $self->process_uploaded_file;
        print $self->set_progress_step("step1");
        my $report_file = $self->process_gff3_file($gff3_file);

        $session->param("uploaded_file", "$uploaded_file"); # Must stringfy uploaded file, note the double quotes
        $self->_store_report_file_info($report_file);

        $self->display_report(1);
        }

    elsif ($submit_url) {
        my $submitted_url = $cgi->param("submitted_url") or $self->error("A URL must be specified!");

        if ($submitted_url !~ /^[^:]+:/) {
            $self->error("Absolute URL path must be specified!");
            }

        print $self->progress_list if $javascript;

        my $gff3_file = $self->process_submitted_url;
        print $self->set_progress_step("step1");
        my $report_file = $self->process_gff3_file($gff3_file);

        $session->param("submitted_url", $submitted_url);
        $self->_store_report_file_info($report_file);

        $self->display_report(1);
        }

    elsif ($page_type eq "display_report") {
        my $page_number = $cgi->param("page_number") or $self->error("A page_number must be specified!");

        $self->display_report($page_number);
        }

    elsif ($page_type eq 'error') {
        $self->error;
        }
    
    else {
        print $self->html_info;
        }

    return 1;
    }

=head3 progress_list

 Function  : Generates HTML segment for the progress list
 Arguments : None
 Returns   : $html
 Notes     :

=cut

sub progress_list {
    my ($self) = @_;

    my $cgi = $self->cgi;

    my $uploaded_file = $cgi->param("uploaded_file");
    my $submitted_url = $cgi->param("submitted_url");

    my $img_unchecked_box = $self->config("img_unchecked_box");

    my $data_acquisition_info;

    if ($uploaded_file) {
        $data_acquisition_info = qq[GFF3 File ($uploaded_file) is to be uploaded by user.];
        }

    elsif ($submitted_url) {
        $data_acquisition_info = qq[GFF3 File is to be downloaded from external URL ($submitted_url).];
        }

    my $footer = $self->_generate_footer;

    my $html =<<END_HTML;
<center><h1>Validating GFF3 File</h1></center>

<TABLE id="progress_tracker" class="box" width="75%" align="center">

<TR>
<TD align="left">

$data_acquisition_info

<P>

Processing ...

<P>
<p><img id="step1"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;1.  Acquiring GFF3 file for validation
<p><img id="step2"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;2.  Setting up database for analysis
<p><img id="step3"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;3.  Validating syntax and loading to database
<p><img id="step4"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;4.  Validating unique ids
<p><img id="step5"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;5.  Acquiring and loading ontology file(s)
<p><img id="step6"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;6.  Validating ontology terms
<p><img id="step7"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;7.  Validating part_of relationships
<p><img id="step8"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;8.  Validating derives_from relationships
<p><img id="step9"  src="$img_unchecked_box" width="25" height="25"/>&nbsp;9.  Generating error report
<p><img id="step10" src="$img_unchecked_box" width="25" height="25"/>&nbsp;10. Performing cleanup
</TD>
</TR>
<TR>
<TD align="left">
</TD>
</TABLE>

<P>
$footer

END_HTML

    return $html;
    }

=head3 set_progress_step

 Function  : Returns out DOM code to set a step as complete
 Arguments : $id
 Returns   : $html
 Notes     :

=cut

sub set_progress_step {
    my ($self, $id) = @_;

    my $img_checked_box = $self->config("img_checked_box");

    my $html;

    $html .= qq[<script type="text/javascript">\n];
    $html .= qq[<!--\n];
    $html .= qq[document.getElementById("$id").src="$img_checked_box"\n];
    $html .= qq[-->\n];
    $html .= qq[</script>\n];

    return $html;
    }

=head3 redirect_to_results

 Function  : Returns out DOM code to redirect to results
 Arguments : None
 Returns   : $html
 Notes     :

=cut

sub redirect {
    my ($self, $type) = @_;

    my $cgi = $self->cgi;
    my $script_url = $cgi->url;

    my $session = $self->session;
    my $session_id = $session->id;

    my $url;

    if ($type eq "display_report") {
        $url = qq[$script_url?session_id=$session_id\&page_type=display_report\&page_number=1\&submit=Submit];
        }

    elsif ($type eq "error") {
        $url =  qq[$script_url?session_id=$session_id\&page_type=error\&submit=Submit];
        }

    else {
        $self->error("Unrecognized redirect type ($type)!");
        }

    my $html;

    $html .= qq[<script type="text/javascript">\n];
    $html .= qq[<!--\n];
    $html .= qq[window.location="$url"\n];
    $html .= qq[-->\n];
    $html .= qq[</script>\n];

    return $html;
    }

=head3 html_info

 Function  : Generates HTML segment for the initial form
 Arguments : None
 Returns   : $html
 Notes     :

=cut

sub html_info {
    my ($self) = @_;

    my $cgi = $self->cgi;
    my $session = $self->session;

    my $gff3_file_size_limit_mbyte = sprintf '%.2f', $self->config("gff3_file_size_limit") / (1024 * 1024);
    my $gff3_file_line_limit = $self->config("gff3_file_length_limit");

    my $ontology_files = $self->config("ontology_files");
    my $ontology_options;
    foreach my $key (keys %$ontology_files) {
        my $display = $ontology_files->{$key}->{display};
        my $selected = $display =~ /\(default\)$/ ? qq[selected="1"] : qq[];
        $ontology_options .= qq[<option $selected value="$key">$display</option>\n];
        }

    my $session_id = $session->id;

    my $script_url = $cgi->url;

    my $link_to_instructions = $self->config("url_instructions") ? 
                                    qq[Description of the validation process is provided <a href="].
                                    $self->config("url_instructions") . qq[">here</a>.<p>]
                                                                          : qq[];
    
    my $download_software_package = $self->config("url_software_package") ? 
                                    qq[For running this application locally, please download the software package <a href="].
                                    $self->config("url_software_package") . qq[">here</a>. Please note that the version of the software package may be different than
                                                                               the software version available online.<p>]
                                                                          : qq[];

    my $footer = $self->_generate_footer;

    my $html =<<END_HTML;
<center><h1>GFF3 Validator</h1></center>

<TABLE class="box" width="75%" align="center">

<TR>
<TD width="75%" align="left">

This script validates a given GFF3 file. 

$link_to_instructions

A GFF3 file can be provided as (i) a file upload or (ii) a URL from which the file can be downloaded from.<P>

For the installation on this site, the size of the GFF3 file that can be processed is limited to <b>$gff3_file_size_limit_mbyte MB</b>
and <b>$gff3_file_line_limit lines</b>.<P>

$download_software_package

<P>

<form enctype="multipart/form-data" action="$script_url" method="POST">

<P>
Please upload your GFF3 file through this form:
<input type="file" name="uploaded_file" size="30">
<input type="submit" name="submit_upload" value="Submit Query">

<P>
Alternatively, please provide a URL to your GFF3 file through this form:
<input type="text" name="submitted_url" size="30">
<input type="submit" name="submit_url" value="Submit Query">

<P>
Specify ontology file:
<select name="ontology_key">
$ontology_options
</select>

<P>
<input type="checkbox" name="implement_max_messages"> Check here to terminate validation after 
<input type="text" name="max_messages" value="100" size="4"> errors.

<input type="hidden" name="session_id" value="$session_id"/></input>
<input id="javascript_detector" type="hidden" name="javascript" value="off"/></input>

</FORM>

<P>
<TABLE id="javascript_warning" border="0">
<TR>
<TD>
<A style="color:red; font-style:italic">
You currently do not have Javascript support. Progress reporting requires Javascript. You may proceed with this setup. However,
you will not be able to view real-time progress during validation.
</A>
</TD>
</TR>
</TABLE

<P>
</TD>
</TR>

<TR>
<TD width="75%" align="left">
</TD>
</TR>
</TABLE>

<P>
$footer

<script type="text/javascript">
<!--
document.getElementById("javascript_detector").value="on"
document.getElementById("javascript_warning").deleteRow(0)
-->
</script>

END_HTML

    return $html;
    }

=head3 process_gff3_file

 Function  : Validates a gff3 file after it has been uploaded/downloaded
 Arguments : $gff3_file
 Returns   : $html
 Notes     :

=cut

sub process_gff3_file {
    my ($self, $gff3_file) = @_;

    my $cgi = $self->cgi;

    # Determine max_messages
    my $max_messages = $cgi->param("implement_max_messages") ? $cgi->param("max_messages") : 0;
    
    my $uploaded_file = $cgi->param("uploaded_file");
    my $submitted_url = $cgi->param("submitted_url");

    if (!$gff3_file) {
        $self->error("Cannot retrieve GFF3 file!");
        }

    my $ontology_key = $cgi->param("ontology_key");
    my $ontology_files = $self->config("ontology_files");
    my $ontology_file = $ontology_files->{$ontology_key}->{file}
        or $self->error("Cannot determine ontology to use (key: $ontology_key)!"); 

    # Check file size
    my $gff3_file_size = -s $gff3_file;
    if ($gff3_file_size == 0) {
        $self->error("Cannot process file, empty file!");
        }

    my $gff3_file_size_limit = $self->config("gff3_file_size_limit");
    my $gff3_file_size_limit_mbyte = sprintf '%.2f', $gff3_file_size_limit / (1024 * 1024);
    if ($gff3_file_size > $gff3_file_size_limit) {
        $self->error("Cannot process file, size is limited to $gff3_file_size_limit_mbyte Mb!");
        }

    # Check file length
    my $gff3_file_length_limit = $self->config("gff3_file_length_limit");
    my ($gff3_file_length) = `wc -l $gff3_file` =~ /^(\d+)/;
    if ($gff3_file_length > $gff3_file_length_limit) {
        $self->error("Cannot process file, # of line is limited to $gff3_file_length_limit lines!");
        }

    # Report file
    my $log_file = "${gff3_file}.log";
    my $report_file = "${gff3_file}.report";

    # Determine command line config file
    my $command_line_config = $self->config("command_line_config") ? $self->config("command_line_config")
                                                                   : $ENV{DOCUMENT_ROOT}."/../conf/validate_gff3.cfg";
    # Create validator object
    my $validator;
    eval {
        $validator = GFF3::Validator->new(-config         => $command_line_config,
                                          -gff3_file      => $gff3_file,
                                          -verbose        => 3,
                                          -silent         => 1,
                                          -log_file       => $log_file,
                                          -report_file    => $report_file,
                                          -ontology_files => [$ontology_file],
                                          -max_messages   => $max_messages,
                                          );
        };
    $self->error("Cannot create validator object: $@") if $@;

    # Proceess file
    eval {
        # Create/Reset tables to store the data
        $validator->create_tables;
        print $self->set_progress_step("step2");

        # Load gff3 analysis database
        $validator->load_analysis_dbs;
        print $self->set_progress_step("step3");

        # Validate unique ids
        $validator->validate_unique_ids;
        print $self->set_progress_step("step4");

        # Load ontology(s) into memory
        $validator->load_ontology;
        print $self->set_progress_step("step5");

        # Validate ontology terms
        $validator->validate_ontology_terms;
        print $self->set_progress_step("step6");

        # Validate parentage
        $validator->validate_parentage;
        print $self->set_progress_step("step7");

        # Validate derives_from
        $validator->validate_derives_from;
        print $self->set_progress_step("step8");

        # Dump an error report
        my $valid_gff3 = $validator->dump_report;
        $self->session->param("valid_gff3", $valid_gff3);
        print $self->set_progress_step("step9");

        # Cleanup
        $validator->cleanup;
        print $self->set_progress_step("step10");
        };
        $self->error("Cannot process file: $@") if $@;

    sleep 1;

    print $self->redirect("display_report");

    return $report_file;
    }

=head3 process_uploaded_file

 Function  : Handles a file upload by user,
             stores file in a temp file
 Arguments : None
 Returns   : $gff3_file
 Notes     :

=cut

sub process_uploaded_file {
    my ($self) = @_;

    my $cgi = $self->cgi;

    my $gff3_file_line_limit = $self->config("gff3_file_length_limit");

    my ($gff3_fh, $gff3_file) = File::Temp::tempfile("XXXX",
                                                     DIR     => $self->config("temp_dir"),
                                                     SUFFIX  => '.gff3',
                                                     );

    my $uploaded_fh = $cgi->upload("uploaded_file");

    # Check for errors (redundant)
    if ($cgi->cgi_error) {
        $self->error($cgi->cgi_error);
        }

    # Check for errors (redundant)
    if (!$uploaded_fh) {
        $self->error($cgi->cgi_error);
        }

    # Check for line size
    my $line_counter;
    while (<$uploaded_fh>) {
        $line_counter++;
        if ($line_counter > $gff3_file_line_limit) {
            $self->error("GFF3 file length limit for upload is exceeded!");
            }
        print $gff3_fh $_;
        }

    return $gff3_file;
    }

=head3 process_submitted_url

 Function  : Handles a file download,
             stores file in a temp file
 Arguments : None
 Returns   : $gff3_file
 Notes     :

=cut

sub process_submitted_url {
    my ($self) = @_;

    my $cgi = $self->cgi;

    my $submitted_url = $cgi->param("submitted_url") or $self->error("A URL must be specified!");

    my $gff3_file_size_limit = $self->config("gff3_file_size_limit");
    my $download_agent_timeout_sec = $self->config("download_agent_timeout_sec");

    my $ua = LWP::UserAgent->new;
    $ua->timeout($download_agent_timeout_sec);
    $ua->max_size($gff3_file_size_limit);

    my $response = $ua->get($submitted_url);

    # Check for errors
    if ($response->is_error) {
        $self->error($response->status_line);
        }

    # Check for client-aborted
    if ($response->header("Client-Aborted")) {
        $self->error("Allowed GFF3 file size exceeded!");
        }

    my ($gff3_fh, $gff3_file) = File::Temp::tempfile("XXXX",
                                                     DIR     => $self->config("temp_dir"),
                                                     SUFFIX  => '.gff3',
                                                     );
    print $gff3_fh $response->content;

    return $gff3_file;
    }

=head3 _store_report_file_info

 Function  : Stores information about the report file to the session
 Arguments : $report_file
 Returns   : 1
 Notes     : This is a private method.

=cut

sub _store_report_file_info {
    my ($self, $report_file) = @_;

    my $session = $self->session;

    my $page_size = $self->config("page_size");

    my ($file_length) = `wc -l $report_file` =~ /^(\d+)/;
    my $total_page_number = int($file_length/$page_size) + ($file_length%$page_size ? 1 : 0);

    $session->param("report_file", $report_file);
    $session->param("file_length", $file_length);
    $session->param("total_page_number", $total_page_number);

    return 1;
    }

=head3 display_report

 Function  : Paginates and displays report file
 Arguments : $report_file
 Returns   : 1
 Notes     :

=cut

sub display_report {
    my ($self, $page_number) = @_;

    my $session = $self->session;

    my $img_valid_gff3 = $self->config("img_valid_gff3");
    my $valid_gff3 = $session->param("valid_gff3");

    my $img_invalid_gff3 = $self->config("img_invalid_gff3");
    
    my $cgi = $self->cgi;
    my $script_url = $cgi->url;

    my $report_file = $session->param("report_file");
    my $file_length = $session->param("file_length");
    my $total_page_number = $session->param("total_page_number");

    my $uploaded_file = $session->param("uploaded_file");
    my $submitted_url = $session->param("submitted_url");

#    if (defined $uploaded_file && defined $submitted_url) {
#        $self->error("Both uploaded_file ($uploaded_file) and submitted_url ($submitted_url) are defined!");
#        }

    if (!$uploaded_file && !$submitted_url) {
        $self->error("Neither uploaded_file or submitted_url are defined!");
        }

    my $data_acquisition_info;

    if ($uploaded_file) {
        $data_acquisition_info = qq[GFF3 File ($uploaded_file) has been uploaded by user.];
        }

    elsif ($submitted_url) {
        $data_acquisition_info = qq[GFF3 File has been downloaded from external URL ($submitted_url).];
        }

    $page_number = 1 if $page_number < 1;
    $page_number = $total_page_number if $page_number > $total_page_number;

    my $valid_gff3_image;

    if ($page_number == 1 && $valid_gff3) {
        $valid_gff3_image = qq[<img src="$img_valid_gff3"></img>];
        }

    if ($page_number == 1 && !$valid_gff3) {
        $valid_gff3_image = qq[<img src="$img_invalid_gff3"></img>];
        }

    my $navigation_bar = $self->_generate_navigation_bar($page_number);
    my $footer = $self->_generate_footer;

    my $page_size = $self->config("page_size");

    my $head = $page_number * $page_size;
    my $content = `head -$head $report_file | tail -$page_size`;

    my $html =<<END_HTML;
<center><h1>GFF3 Validator</h1></center>

<TABLE class="box" width="75%" align="center">

<TR>
<TD align="left">

$data_acquisition_info

<P>
Validation report follows. Navigation bar below and bottom of the page can
be used to navigate between pages of the report. Click <a href="$script_url">here</a> to try another analysis.
<P>

$valid_gff3_image

<P>

$navigation_bar

<pre>
$content
</pre>

$navigation_bar

</TD>
</TR>
<TR>
<TD align="left">
</TD>
</TABLE>

<P>
$footer

END_HTML

    print $html;

    return 1;
    }

=head3 _generate_navigation_bar

 Function  : Generates a navigation bar to navigate through pages of the report file
 Arguments : $page_number
 Returns   : $html
 Notes     : This is a private method.

=cut

sub _generate_navigation_bar {
    my ($self, $page_number) = @_;

    my $session = $self->session;

    my $session_id = $session->id;

    my $report_file = $session->param("report_file");
    my $file_length = $session->param("file_length");
    my $total_page_number = $session->param("total_page_number");

    my $previous_page_number = $page_number - 1 < 1 ? 1
                                                    : $page_number - 1;

    my $next_page_number = $page_number + 1 > $total_page_number ? $total_page_number
                                                                 : $page_number + 1;

    my @page_list =
        map { $page_number eq $_ ? qq[<OPTION selected value="$_">Page $_</OPTION>\n] : qq[<OPTION value="$_">Page $_</OPTION>\n] }
            (1..$total_page_number);
    my $page_list = join('', @page_list);

    my $navigation_bar = <<HTML;
<TABLE class="small_box" width="100%">
<TR>
<TD width="40%" align="left">
Page $page_number of $total_page_number
</TD>

<TD align="center">
<FORM method="GET" action="validate_gff3_online">
<input type="hidden" name="session_id" value="$session_id"/></input>
<input type="hidden" name="page_type" value="display_report"/></input>
<input type="hidden" name="page_number" value="$previous_page_number"/></input>
<input type="submit" name="submit" value="Prev"></input>
</FORM>
</TD>

<TD align="center">
&nbsp;
</TD>

<TD align="center">
<FORM method="GET" action="validate_gff3_online">
<input type="hidden" name="session_id" value="$session_id"/></input>
<input type="hidden" name="page_type" value="display_report"/></input>
<input type="hidden" name="page_number" value="$next_page_number"/></input>
<input type="submit" name="submit" value="Next"></input>
</FORM>
</TD>

<TD width="40%" align="right">
<FORM method="GET" action="validate_gff3_online">
<input type="hidden" name="session_id" value="$session_id"/></input>
<input type="hidden" name="page_type" value="display_report"/></input>
<SELECT name="page_number">
$page_list
</SELECT>
<input type="submit" name="submit" value="Go"></input>
</FORM>
</TD>

</TR>
</TABLE>
HTML

    return $navigation_bar;
    }

=head3 _generate_footer

 Function  : Generates footer information
 Arguments : None
 Returns   : $html
 Notes     : This is a private method.

=cut

sub _generate_footer {
    my ($self) = @_;

    my @footer;

    if ($self->config("debug")) {
        my $time_stamp = $time{'dd-Mon-yyyy hh:mm:ss tz'};

        my $url = $ENV{HTTP_HOST} . $ENV{REQUEST_URI};
        $url =~ s/(.{100})/$1<BR>/g if $url =~ /\S{100,}/;

        my $software;
        foreach my $file ($0, $INC{'GFF3/Validator.pm'}, $INC{'GFF3/Online.pm'}) {
            my ($id) = $self->_get_version_information($file);
            my ($file_name) = $file =~ /([^\/]+)$/;
            $software .= "<b>$file_name</b>: $id\n";
            }
        chomp $software;

        push @footer, "<b>URL</b>: $url", "<b>Time</b>: $time_stamp", $software;
        }

    if ($self->config("debug") && $self->config("footer")) {
        push @footer, "&nbsp;";
        }

    if ($self->config("footer")) {
        push @footer, ref $self->config("footer") ? @{$self->config("footer")} : $self->config("footer");
        }

    my $html = join("\n", qq[<TABLE id="footer" class="small_box2" width="75%" align="center"><TR><TD>], "<pre>", @footer, "</pre>", qq[</TD></TR></TABLE>]);

    return $html;
    }

=head3 error

 Function  : Generates an error page,
             deletes session
 Arguments : $message
 Returns   : exit 0
 Notes     :

=cut

sub error {
    my ($self, $message) = @_;

    my $cgi = $self->cgi;

    my $page_type = $cgi->param("page_type");

    my $script_url = $cgi->url;

    my $session = $self->session;

    if (!$message) {
        $message = $session->param("message");
        }

    if ($self->javascript) {
        $session->param("message", $message);
        if ($page_type ne "error") {
            print $self->redirect("error");
            }
        }

    my $footer = $self->_generate_footer;

    my $html = <<HTML;
<center><h1>GFF3 Validator</h1></center>

<TABLE class="box" width="75%" align="center">
<TR>
<TD width="75%" align="left">

<b>An Error Occurred: </b><a style="color:red; font-style:italic">$message</a>
<P>
<center><b><a href="$script_url">[Try your analysis again]</a></b></center>

</TD>
</TR>

<TR>
<TD width="75%" align="left">
</TD>
</TABLE>

<P>
$footer

HTML

    print $html;

    my $session = $self->session;

    exit 0;
    }

=head2 _get_version_information

 Function  : Captures CVS version information of files for _get_id_information.
 Arguments : $file
 Returns   : $version_id
 Notes     : This is a private method

=cut

sub _get_version_information {
    my ($self, $file) = @_;
    open (IN, "<$file") or croak("Cannot read file ($file)");
    my $content; { local $/; $content = <IN>; }
    close IN;
    my ($id) = $content =~ /([\$]Id[^\$]*\$)/;
    return ($id);
    }

=head2 _clean_temp_dirs

 Function  : Clean temp dirs.
 Arguments : None
 Returns   : $version_id
 Notes     : This is a private method

=cut

sub _clean_temp_dirs {
    my ($self) = @_;

    my $expires_in_min = $self->config("expires_in_min");

    my $temp_dir = $self->config("temp_dir");
    my $session_dir = $self->config("session_dir");

    foreach my $file_wild_card ('*.xml', '*.gff3', '*.report', '*.log', 'cgisess_*', '*.temp', '*.cache') {
        foreach my $dir ($temp_dir, $session_dir) {
            my $clean_cmd = "find $dir -name \'$file_wild_card\' -amin +$expires_in_min -exec rm -f {} \\;";
            system $clean_cmd;
            }
        }

    return 1;
    }

=head2 _internal_css

 Function  : Stores minimal internal CSS
 Arguments : None
 Returns   : $html
 Notes     : This is a private method

=cut

sub _internal_css {
    my ($self) = @_;

    my $html = <<HTML;
body
{
font-family: helvetica, arial, 'sans serif';
font-size: 13;
color: #000000;
background-color: #ffffff;
}
.box
{
font-size: 13;
padding: 1cm;
border-style: solid;
border-width: thin;
border-color: #616161;
background-color: #f1f3ff;
}
.small_box
{
font-size: 11;
padding: 0.2cm;
border-style: solid;
border-width: thin;
border-color: #616161;
background-color: #bfd5e8;
}
.small_box2
{
font-size: 11;
padding: 0.3cm;
border-style: solid;
border-width: thin;
border-color: #616161;
background-color: #EEE9E9;
}

HTML

    return $html;
    }

=head1 SEE ALSO

=head1 AUTHOR

Payan Canaran <canaran@cshl.edu>

=head1 VERSION

$Id: Online.pm,v 1.2 2007/12/18 00:21:21 canaran Exp $

=head1 CREDITS

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2006-2007 Cold Spring Harbor Laboratory

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself. See DISCLAIMER.txt for
disclaimers of warranty.

=cut

1;
