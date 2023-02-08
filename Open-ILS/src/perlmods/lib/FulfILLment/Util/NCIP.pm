package FulfILLment::Util::NCIP;
use strict;
use warnings;
use IO::Socket;
use Data::Dumper;
use XML::LibXML;
use LWP::UserAgent;
use HTTP::Request;
use Template;
use OpenSRF::Utils::Logger qw/$logger/;

my $ua = LWP::UserAgent->new;
$ua->agent("FulfILLment/1.0");
$ua->default_header('Content-Type' => 'application/xml; charset="utf-8"');

sub new {
    my ($class, %args) = @_;
    return bless(\%args, $class);
}

sub request {
    my ($self, $type, %params) = @_;

    $logger->info("FF NCIP sending message $type");

    my $xml = $self->compile_xml($type, %params);
    return unless $xml;

    my $proto = $self->{protocol} || '';
    my $resp_xml;
    if ($proto =~ /http/i) {
        $resp_xml = $self->send_via_http($xml);
    } elsif ($proto =~ /tcp/i) {
        $resp_xml = $self->send_via_tcp($xml);
    } else {
        $logger->error("FF Invalid NCIP protocol '$proto'");
        return;
    }

    my $doc = $self->parse_xml($resp_xml) or return;
    return ($doc, $self->extract_ncip_errors($doc));
}

# parses/verifies XML and returns an XML doc
sub parse_xml {
    my ($self, $xml) = @_;

    my $parser = XML::LibXML->new;
    $parser->keep_blanks(0);

    my $doc;
    eval { $doc = $parser->parse_string($xml) };

    if (!$doc) {
        $logger->error("FF invalid XML for NCIP message $@ : $xml");
        return;
    }

    my $log_xml = $doc->toString;
    $log_xml =~ s/\n/ /g;
    $logger->debug("FF NCIP XML : $log_xml");

    return $doc;
}


# extract all //Problem/* text values
sub extract_ncip_errors {
    my ($self, $doc) = @_;
    my @errors;
    my $prob_xpath = '//Problem//Value';
    push(@errors, $_->textContent) for $doc->findnodes($prob_xpath);
    return @errors;
}

# sends the xml template for the requested message type 
# through TT to generate the final XML message.
sub compile_xml {
    my ($self, $type, %params) = @_;

    # insert the agency info into the template environment
    $params{ff_agency_name}  = $self->{ff_agency_name};
    $params{ff_agency_uri}   = $self->{ff_agency_uri};
    $params{ils_agency_name} = $self->{ils_agency_name};
    $params{ils_agency_uri}  = $self->{ils_agency_uri};

    my $template = "$type.tt2";

    my $tt = Template->new({
        ENCODING => 'utf-8',
        INCLUDE_PATH => $self->{template_paths}
    });

    my $xml = '';
    if ($tt->process($template, \%params, \$xml)) {

        my $doc = $self->parse_xml($xml) or return;
        return $doc->toString;

    } else {
        $logger->error("FF NCIP XML template error : ".$tt->error);
        return;
    }
}

sub send_via_http {
    my ($self, $xml) = @_;

    my $url = sprintf(
        '%s://%s:%s%s', 
        $self->{protocol}, 
        $self->{host}, 
        $self->{port}, 
        $self->{path}
    );

    $logger->debug("FF NCIP url = $url");

    my $r = HTTP::Request->new('POST', $url);
    $r->content($xml);
    my $resp = $ua->request($r);

    return $resp->decoded_content if $resp->is_success;

    $logger->error("FF NCIP HTTP(S) Error : " . $resp->status_line);
    return;
}

sub send_via_tcp {
    my ($self, $xml) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $self->{host},
        PeerPort => $self->{port},
        Proto => 'tcp',
        Timeout => 10,
    );    

    if (!$sock) {
        $logger->error("FF NCIP TCP connection error $!");
        return;
    }

    $sock->send($xml);
    my $resp_xml = <$sock>; 

    $sock->close or $logger->warn("FF error closing socket $!");
    return $resp_xml;
}

1;
