package FulfILLment::LAIConnector::Koha;
use base FulfILLment::LAIConnector;
use strict; use warnings;
use XML::LibXML;
use LWP::UserAgent;
use OpenSRF::Utils::Logger qw/$logger/;

# TODO: for holds
use DateTime;
my $U = 'OpenILS::Application::AppUtils';
use OpenILS::Utils::CStoreEditor qw/:funcs/;

# special thanks to Koha => misc/migration_tools/koha-svc.pl
sub svc_login { 
    my $self = shift;
    return $self->{svc_agent} if $self->{svc_agent};

    my $username = $self->{extra}->{'svc.user'} || $self->{user};
    my $password = $self->{extra}->{'svc.password'} || $self->{passwd};

    my $url = sprintf(
        "%s://%s:%s/cgi-bin/koha/svc",
        $self->{extra}->{'svc.proto'} || $self->{proto} || 'https',
        $self->{extra}->{'svc.host'} || $self->{host},
        $self->{extra}->{'svc.port'} || $self->{port} || 443 
    ); 

    my $ua = LWP::UserAgent->new();
    $ua->cookie_jar({});

    $logger->info("FF Koha logging in at $url/authentication");

    my $resp = $ua->post(
        "$url/authentication",
        {userid => $username, password => $password}
    );

    if (!$resp->is_success) {
        $logger->error("FF Koha svc login failed " . $resp->status_line);
        return;
    }

    $self->{svc_url} = $url;
    $self->{svc_agent} = $ua;

    return 1;
}

sub escape_xml {
    my $str = shift;
    $str =~ s/&/&amp;/sog;
    $str =~ s/</&lt;/sog;
    $str =~ s/>/&gt;/sog;
    return $str;
}

# sends a MARCXML stub record w/ a single embedded copy
sub create_borrower_copy {
    my ($self, $ref_copy, $circ_lib_code) = @_;
    return unless $self->svc_login;

    my $marc = <<XML;
<record
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.loc.gov/MARC21/slim http://www.loc.gov/standards/marcxml/schema/MARC21slim.xsd"
  xmlns="http://www.loc.gov/MARC21/slim">
  <datafield tag="100" ind1="1" ind2=" ">
    <subfield code="a">AUTHOR</subfield>
  </datafield>
  <datafield tag="245" ind1="1" ind2="0">
    <subfield code="a">TITLE</subfield>
  </datafield>
  <datafield tag="952" ind1=" " ind2=" ">
    <subfield code="p">BARCODE</subfield>
    <subfield code="o">CALLNUMBER</subfield>
    <subfield code="a">LOCATION</subfield>
  </datafield>
</record>
XML

    my $title = escape_xml($ref_copy->call_number->record->simple_record->title);
    my $author = escape_xml($ref_copy->call_number->record->simple_record->author);
    my $barcode = escape_xml($ref_copy->barcode); # TODO: setting for leading org id
    my $callnumber = escape_xml($ref_copy->call_number->label);

    $marc =~ s/TITLE/$title/g;
    $marc =~ s/AUTHOR/$author/g;
    $marc =~ s/BARCODE/$barcode/g;
    $marc =~ s/CALLNUMBER/$callnumber/g;
    $marc =~ s/LOCATION/$circ_lib_code/g;

    $logger->info("FF Koha borrower rec/copy: $marc");

    my $resp = $self->{svc_agent}->post(
        $self->{svc_url} . "/new_bib?items=1",
        {POSTDATA => $marc} 
        # note: passing Content => $marc fails
    );

    if (!$resp->is_success) {
        $logger->error("FF Koha create_borrower_copy " . $resp->status_line);
        return;
    }

    $logger->info($resp->decoded_content);

    my $resp_xml = XML::LibXML->new->parse_string($resp->decoded_content);
    $logger->info($resp_xml);
    $logger->info($resp_xml->toString);

    my $error = $resp_xml->getElementsByTagName('error')->string_value;
    my $marcxml = $resp_xml->getElementsByTagName('record')->shift;

    return {
        error => $error,
        barcode => $error ? '' : $barcode, # return bc on success
        title => $title,
        author => $author,
        location => $circ_lib_code,
        call_number => $callnumber,
        remote_id => $resp_xml->getElementsByTagName('biblionumber')->string_value,
        status => $resp_xml->getElementsByTagName('status')->string_value,
        marcxml => $marcxml ? $marcxml->toString : ''
    };
}

sub get_record_by_id {
    my ($self, $record_id, $with_items) = @_;
    return unless $self->svc_login;

    $with_items = '?items=1' if $with_items;

    my $url = $self->{svc_url}."/bib/$record_id$with_items";
    my $resp = $self->{svc_agent}->get($url);

    if (!$resp->is_success) {
        $logger->error("FF Koha record_by_id failed " . $resp->status_line);
        return;
    }

    return $resp->decoded_content
}

# NOTE: unused, but kept for reference
sub get_record_by_id_z3950 {
    my ($self, $record_id) = @_;

    my $attr = $self->{args}{extra}{'z3950.search_attr'};

    # Koha returns holdings by default, which is useful
    # for get_items_by_record (below).

    my $xml = $self->z39_client->get_record_by_id(
        $record_id, $attr, undef, 'xml', 1) or return;

    return {marc => $xml, id => $record_id};
}

sub get_items_by_record {
    my ($self, $record_id) = @_;

    my $rec = $self->get_record_by_id($record_id, 1) or return [];
    
    # when calling get_record_by_id_z3950 
    # my $doc = XML::LibXML->new->parse_string($rec->{marc}) or return [];

    my $doc = XML::LibXML->new->parse_string($rec) or return [];

    # marc code to copy field map
    my %map = (
        o => 'call_number',
        p => 'barcode',
        a => 'location_code'
    );

    my @items;
    for my $node ($doc->findnodes('//*[@tag="952"]')) {

        my $item = {bib_id => $record_id};

        for my $key (keys %map) {
            my $val = $node->findnodes("./*[\@code='$key']")->string_value;
            next unless $val;
            $val =~ s/^\s+|\s+$//g; # cleanup
            $item->{$map{$key}} = $val;
        }

        push (@items, $item);
    }

    return \@items;
}

# NOTE: initial code review suggests Koha only supports bib-level
# holds via SIP, but they are created via copy barcode (not bib id).
# Needs more research

sub place_borrower_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;

    # NOTE: i believe koha ignores (but requires) the hold type
    my $hold = $self->place_hold_via_sip(
        undef, $item_barcode, $user_barcode, $pickup_lib, 3)
        or return;

    $hold->{hold_type} = 'T';
    return $hold;
}

sub place_lender_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;

    # NOTE: i believe koha ignores (but requires) the hold type
    my $hold = $self->place_hold_via_sip(
        undef, $item_barcode, $user_barcode, $pickup_lib, 2)
        or return;

    $hold->{hold_type} = 'T';
    return $hold;
}

sub delete_borrower_hold {
    my ($self, $item_barcode, $user_barcode) = @_;

    # TODO: find the hold in the FF db to determine the pickup_lib
    # for now, assume pickup lib matches the user's home lib
    my $user = $self->flesh_user($user_barcode);
    my $pickup_lib = $user->home_ou->shortname if $user;

    my $resp = $self->sip_client->delete_hold(
        $user_barcode, undef, undef, 
        $pickup_lib, 3, $item_barcode)
        or return;

    return unless $resp;
    return $self->translate_sip_hold($resp);
}

sub delete_lender_hold {
    my ($self, $item_barcode, $user_barcode) = @_;

    my $user = $self->flesh_user($user_barcode);
    my $pickup_lib = $user->home_ou->shortname if $user;

    my $resp = $self->sip_client->delete_hold(
        $user_barcode, undef, undef, 
        $pickup_lib, 2, $item_barcode)
        or return;

    return unless $resp;
    return $self->translate_sip_hold($resp);
}


1;
