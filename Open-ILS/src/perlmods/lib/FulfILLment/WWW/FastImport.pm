package FulfILLment::WWW::FastImport;
use strict;
use warnings;
use bytes;

use Apache2::Log;
use Apache2::Const -compile => qw(OK REDIRECT DECLINED NOT_FOUND FORBIDDEN :log);
use APR::Const    -compile => qw(:error SUCCESS);
use APR::Table;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::RequestUtil;
use CGI;
use Data::Dumper;

use OpenSRF::EX qw(:try);
use OpenSRF::Utils::Cache;
use OpenSRF::System;
use OpenSRF::Utils::SettingsClient;
use OpenSRF::AppSession;
use OpenSRF::MultiSession;
use OpenSRF::Utils::JSON;
use XML::LibXML;

use OpenILS::Utils::Fieldmapper;
use OpenSRF::Utils::Logger qw/$logger/;

use MARC::Batch;
use MARC::File::XML ( BinaryEncoding => 'utf-8' );
use MARC::Charset;
use Getopt::Long;
use Unicode::Normalize;
use Encode;

use UNIVERSAL::require;

MARC::Charset->ignore_errors(1);

our @formats = qw/USMARC UNIMARC XML BRE/;
my $MAX_FILE_SIZE = 1073741824; # 1GB
my $FILE_READ_SIZE = 4096;

# set the bootstrap config and template include directory when
# this module is loaded
my $bootstrap;

sub import {
        my $self = shift;
        $bootstrap = shift;
}


sub child_init {
        OpenSRF::System->bootstrap_client( config_file => $bootstrap );
}

sub handler {
    my $r = shift;
    my $cgi = new CGI;

    my $auth = $cgi->param('ses') || $cgi->cookie('ses');

    unless(verify_login($auth)) {
        $logger->error("authentication failed on vandelay record import: $auth");
        return Apache2::Const::FORBIDDEN;
    }

    my $fh = $cgi->param('loadFile');
    my $x;
    my $mtype = (sysread($fh,$x,1) && $x =~ /^\D/o) ? 'XML' : 'USMARC';

    sysseek($fh,0,0);

    $r->content_type('html');
    print '<div>';

    my $conf = OpenSRF::Utils::SettingsClient->new;
    my $parallel = $conf->config_value(
        apps => 'fulfillment.www.fast-import' => app_settings => 'parallel'
    ) || 1;

    my $owner = $cgi->param('uploadLocation');

    my $multi = OpenSRF::MultiSession->new(
        app => 'open-ils.cstore', 
        cap => $parallel, 
        api_level => 1
    );

    my $batch = new MARC::Batch ($mtype, $fh);
    $batch->strict_off;

    my $count = 0;
    my $rec = -1;
    while (try { $rec = $batch->next } otherwise { $rec = -1 }) {
        $count++;
        warn "record $count\n";
        if ($rec == -1) {
            print "<div>Processing of record $count in set $fh failed.  Skipping this record</div>";
            next;
        }

        try {
            # Avoid an over-eager MARC::File::XML that may try to convert
            # our record from MARC8 to UTF8 and break because the record
            # is obviously already UTF8
            my $ldr = $rec->leader();
            if (($mtype eq 'XML') && (substr($ldr, 9, 1) ne 'a')) {
                print "<div style='color: orange;'>MARCXML record LDR/09 was not 'a'; record leader may be corrupt</div>";
                substr($ldr,9,1,'a');
                $rec->leader($ldr);
            }

            (my $xml = $rec->as_xml_record()) =~ s/\n//sog;
            $xml =~ s/^<\?xml.+\?\s*>//go;
            $xml =~ s/>\s+</></go;
            $xml =~ s/\p{Cc}//go;

            $xml = entityize($xml);
            $xml =~ s/[\x00-\x1f]//go;

            $multi->request(
                'open-ils.cstore.json_query',
                { from => [ 'biblio.fast_import', $owner, $xml ] }
            );

        } catch Error with {
            my $error = shift;
            print "<div style='color: red;'>Encountered a bad record during fast import: $error</div>";
        };

    }

    print "<div>Completed processing of $count records from $fh</div>";
    $multi->session_wait(1);
    $multi->disconnect;

    print '</div>';

    return Apache2::Const::OK;
}

# xml-escape non-ascii characters
sub entityize {
    my($string, $form) = @_;
    $form ||= "";

    # If we're going to convert non-ASCII characters to XML entities,
    # we had better be dealing with a UTF8 string to begin with
    $string = decode_utf8($string);

    if ($form eq 'D') {
        $string = NFD($string);
    } else {
        $string = NFC($string);
    }

    # Convert raw ampersands to entities
    $string =~ s/&(?!\S+;)/&amp;/gso;

    # Convert Unicode characters to entities
    $string =~ s/([\x{0080}-\x{fffd}])/sprintf('&#x%X;',ord($1))/sgoe;

    return $string;
}

sub verify_login {
        my $auth_token = shift;
        return undef unless $auth_token;

        my $user = OpenSRF::AppSession
                ->create("open-ils.auth")
                ->request( "open-ils.auth.session.retrieve", $auth_token )
                ->gather(1);

        if (ref($user) eq 'HASH' && $user->{ilsevent} == 1001) {
                return undef;
        }

        return $user if ref($user);
        return undef;
}

1;

