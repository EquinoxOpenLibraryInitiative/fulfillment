package FulfILLment::LAIConnector::Koha;
use base FulfILLment::LAIConnector;
use strict; use warnings;
use XML::LibXML;
use LWP::UserAgent;
use Data::Dumper;
use OpenSRF::Utils::Logger qw/$logger/;

# TODO: for holds
use DateTime;
my $U = 'OpenILS::Application::AppUtils';
use OpenILS::Utils::CStoreEditor qw/:funcs/;

# We're using both the legacy /svc API endpoint, because
# that's what's available to create bibs and items, and Koha's REST API

# special thanks to Koha => misc/migration_tools/koha-svc.pl
sub svc_login { 
    my $self = shift;
    return $self->{svc_agent} if $self->{svc_agent};

    my $username = $self->{extra}->{'svc.user'} || $self->{user};
    my $password = $self->{extra}->{'svc.password'} || $self->{passwd};

    my $url = sprintf(
        "%s://%s/cgi-bin/koha/svc",
        'https',
        $self->{extra}->{'svc.host'} || $self->{host},
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

sub _base_api_url {
    my $self = shift;

    return sprintf(
        "%s://%s/api/v1",
        'https',
        $self->{host},
    );
}

sub _oauth_login {
    my $self = shift;
    return 1 if $self->{oauth_agent};

    my $client_id = $self->{'user'};
    my $client_secret = $self->{'passwd'};

    my $url = $self->_base_api_url;

    my $ua = LWP::UserAgent->new();
    $ua->cookie_jar({});

    $logger->info("FF Koha logging in via OAuth");

    my $resp = $ua->post(
        "$url/oauth/token",
        {
            client_id => $client_id,
            client_secret => $client_secret,
            grant_type => 'client_credentials'
        }
    );

    if (!$resp->is_success) {
        $logger->error("FF Koha oauth login failed " . $resp->status_line);
        return;
    }

    my $result = OpenSRF::Utils::JSON->JSON2perl($resp->decoded_content);
    $self->{oauth_token} = $result->{access_token};
    $self->{oauth_agent} = $ua;

    return 1;
}

sub _make_api_request {
    my $self = shift;
    my $request_type = shift;
    my $route = shift;
    my $params = shift;
    my $format = shift // 'application/json';

    return unless $self->_oauth_login;

    my $url = $self->_base_api_url . '/' . $route;
    my $req = HTTP::Request->new(
        $request_type => $url
    );
    $req->header('Cache-Control', 'no-cache');
    $req->header('Pragma', 'no-cache');
    $req->header('Authorization', 'Bearer ' . $self->{oauth_token});
    $req->header('Accept', $format);
    $req->content(OpenSRF::Utils::JSON->perl2JSON($params)) if defined($params);

    my $resp = $self->{oauth_agent}->request($req);

    if (!$resp->is_success) {
        $logger->error(
            "FF Koha REST API request error [HTTP ".$resp->code."] for $url\n". Dumper($req) . "\n" . Dumper($resp));
        return undef;
    }
   
    if ($format =~ /json/) { 
        return OpenSRF::Utils::JSON->JSON2perl($resp->decoded_content);
    } else {
        return $resp->decoded_content;
    }
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
    my $barcode = escape_xml('ILL' . $ref_copy->barcode);
    my $callnumber = escape_xml($ref_copy->call_number->label);

    $marc =~ s/TITLE/$title/g;
    $marc =~ s/AUTHOR/$author/g;
    $marc =~ s/BARCODE/$barcode/g;
    $marc =~ s/CALLNUMBER/$callnumber/g;

    my $svc_user = $self->get_user($self->{extra}->{'svc.user'});
    return unless $svc_user;

    my $library = $svc_user->{home_library};
    $marc =~ s/LOCATION/$library/g;

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
    my ($self, $record_id) = @_;

    my $resp = $self->_make_api_request(
        'GET', 'biblios/' . $record_id, undef, 'application/marcxml+xml'
    );

    if (!$resp) {
        $logger->error("FF Koha record_by_id failed");
        return;
    }

    return {
        marc => $resp,
        error => 0,
        id => $record_id
    };
}

sub _get_due_date_for_item {
    my ($self, $koha_item_id) = @_;

    my $resp = $self->_make_api_request(
        'GET', 'checkouts', { item_id => $koha_item_id }, 'application/json'
    );

    if ($resp && $resp->[0] && $resp->[0]->{due_date}) {
        return $resp->[0]->{due_date}
    } else {
        return;
    }
}

sub get_items_by_record {
    my ($self, $record_id) = @_;

    my $resp = $self->_make_api_request(
        'GET', 'items', { biblionumber => $record_id }, 'application/json'
    );

    if (!$resp || !(ref $resp eq 'ARRAY')) {
        $logger->error("FF Koha get_items_by_record failed");
        return;
    }

    my @items;

    foreach my $item (@{ $resp }) {
        my $holdable = 't';
        if ($item->{checked_out_date} ||
            $item->{not_for_loan_status} ||
            $item->{lost_status} ||
            $item->{restricted_status}) {
            $holdable = 'f';
        }
        my $munged_item = {
            bib_id => $record_id,
            owner => $item->{home_library_id} // '',
            barcode => $item->{external_id} // '',
            call_number => $item->{callnumber} // '',
            holdable => $holdable,
            item_id => $item->{item_id},
        };
        if ($item->{checked_out_date}) {
            my $due_date = $self->_get_due_date_for_item($item->{item_id});
            if ($due_date) {
                $due_date =~ s/T.*$//;
                $munged_item->{due_date} = $due_date;
            }
        }
        push @items, $munged_item;
    }

    return \@items;
}

sub get_item {
    my ($self, $barcode) = @_;

    my $resp = $self->_make_api_request(
        'GET', 'items', { external_id => $barcode }, 'application/json'
    );

    if (!$resp || !(ref $resp eq 'ARRAY')) {
        $logger->error("FF Koha get_item failed");
        return;
    }

    return unless scalar(@{ $resp }) > 0;

    my $item = $resp->[0];
    my $holdable = 't';
    if ($item->{checked_out_date} ||
        $item->{not_for_loan_status} ||
        $item->{lost_status} ||
        $item->{restricted_status}) {
        $holdable = 'f';
    }
    my $munged_item = {
        bib_id => $item->{biblio_id},
        owner => $item->{home_library_id} // '',
        barcode => $item->{external_id} // '',
        call_number => $item->{callnumber} // '',
        holdable => $holdable,
        item_id => $item->{item_id},
    };
    if ($item->{checked_out_date}) {
        my $due_date = $self->_get_due_date_for_item($item->{item_id});
        if ($due_date) {
            $due_date =~ s/T.*$//;
            $munged_item->{due_date} = $due_date;
        }
    }
    return $munged_item;
}

sub place_borrower_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;

    my $ill_barcode = 'ILL' . $item_barcode;

    return $self->place_lender_hold($ill_barcode, $user_barcode);
}

sub place_lender_hold {
    my ($self, $item_barcode, $user_barcode) = @_;

    my $lender_user = $self->get_user($user_barcode);
    return unless defined $lender_user;

    my $item = $self->get_item($item_barcode);
    return unless defined $item;

    my $resp = $self->_make_api_request(
        'POST', 'holds', {
            patron_id => $lender_user->{user_id},
            biblio_id => $item->{bib_id},
            item_id => $item->{item_id},
            pickup_library_id => $lender_user->{home_library},
        }, 'application/json'
    );

    if (!$resp || !(ref $resp eq 'HASH')) {
        $logger->error("FF Koha place_lender failed");
        return;
    }

    return $resp->{hold_id};
}

sub _find_last_active_hold {
    my ($self, $item_id, $patron_id, $bib_id) = @_;

    my $resp = $self->_make_api_request(
        'GET', 'holds', {
            patron_id => $patron_id,
            biblio_id => $bib_id,
            item_id => $item_id
        }
    );

    return unless $resp and ref($resp) eq 'ARRAY';
    return $resp->[0]->{hold_id};
}

sub delete_borrower_hold {
    my ($self, $item_barcode, $user_barcode) = @_;

    my $ill_barcode = 'ILL' . $item_barcode;

    return $self->delete_lender_hold($ill_barcode, $user_barcode);
}

sub delete_lender_hold {
    my ($self, $item_barcode, $user_barcode) = @_;

    my $lender_user = $self->get_user($user_barcode);
    return unless defined $lender_user;

    my $item = $self->get_item($item_barcode);
    return unless defined $item;

    my $hold_id = $self->_find_last_active_hold($item->{item_id}, $lender_user->{user_id}, $item->{bib_id});
    return unless $hold_id;

    my $resp => $self->_make_api_request(
        'DELETE', 'holds/' . $hold_id
    );

    return $hold_id;
}

sub get_user {
    my $self = shift;
    my $user_barcode = shift;
    my $user_password = shift;

    return unless $self->_oauth_login;

    my $patron;
    if (defined($user_password) && $user_password ne '') {
        # validate the user credentials first
        my $password_check = $self->_make_api_request(
            'POST', 'contrib/kohasuomi/auth/patrons/validation',
            { cardnumber => $user_barcode, password => $user_password }
        );
        if ($password_check) {
            $patron = $password_check;
        } else {
            $logger->info("Koha: unable to verify credentials for user $user_barcode");
            return OpenILS::Event->new("ACTOR_USER_NOT_FOUND", error => 1);
        }
    } else {
        my $patrons = $self->_make_api_request('GET', 'patrons', { cardnumber => $user_barcode });
        if ($patrons && $patrons->[0]) {
            $patron = $patrons->[0];
        } else {
            $logger->info("Koha: unable to retrieve user $user_barcode");
            return OpenILS::Event->new("ACTOR_USER_NOT_FOUND", error => 1);
        }
    }

    my $data = {};
    $data->{surname} = $patron->{surname};
    $data->{initials} = $patron->{initials};
    $data->{given_name} = $patron->{firstname};
    $data->{user_id} = $patron->{patron_id};
    $data->{exp_date} = $patron->{expiry_date};
    $data->{user_barcode} = $user_barcode;
    $data->{email} = $patron->{email};
    $data->{home_library} = $patron->{library_id};

    return $data;
}

1;
