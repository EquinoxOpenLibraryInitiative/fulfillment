package FulfILLment::LAIConnector::Evergreen;
use base FulfILLment::LAIConnector;
use strict; use warnings;
use OpenSRF::Utils::Logger qw/$logger/;
use Digest::MD5 qw(md5_hex);
use LWP::UserAgent;
use URI::Escape;
use HTTP::Request;
use JSON::XS;
use Data::Dumper;

my $json = JSON::XS->new;
$json->allow_nonref(1);

my $ua = LWP::UserAgent->new;
$ua->agent("FulfILLment/1.0");

sub gateway {
    my ($self, $service, $method, @args) = @_;

    my $url = sprintf(
        'https://%s/osrf-gateway-v1?service=%s&method=%s',
        $self->{host}, $service, $method
    );
    $url .= '&param=' . uri_escape($json->encode($_)) for (@args);

    $logger->info("FF Evergreen gateway request => $url");

    my $req = HTTP::Request->new('GET' => $url);
    my $res = $ua->request($req);

    if (!$res->is_success) {
        $logger->error(
            "FF Evergreen gateway request error [HTTP ".$res->code."] $url");
        return undef;
    }

    my $value = decode_json($res->content);
    return $$value{payload} if $$value{status} == 200;
}

# --------------------------------------------------------------------
# Login 
# TODO: support authtoken re-use (and graceful recovery) for 
# faster batches of actions
# Always assumes barcode-based login.
# --------------------------------------------------------------------
sub login {
    my $self = shift;
    my $username = shift || $self->{user};
    my $password = shift || $self->{passwd};
    my $type = shift;

    my $json = $self->gateway(
        'open-ils.fulfillment',
        'fulfillment.connector.login',
        undef, $password, $type, $username
    );

    my $auth = $$json[0];
    $logger->info("EG: login failed for $username") unless $auth;
    return $self->{authtoken} = $auth;   
}

sub get_user {
    my $self = shift;
    my $user_barcode = shift;
    my $user_password = shift;

    my $resp = $self->gateway(
        'open-ils.fulfillment',
        'fulfillment.connector.verify_user_by_barcode',
        $user_barcode, $user_password
    );

    # TODO: we always assume barcode logins in FF, but it would be
    # nice if the EG connector could safey fall-through to username
    # logins.  Care must be taken to prevent multiple accounts, one 
    # for the barcode and one for the username.

    unless ($resp and $resp->[0]) {
        $logger->info("EG: unable to verify user $user_barcode");
        return undef;
    }

    my $data = $resp->[0];

    $logger->info("Evergreen retreived user " . Dumper($data));

    $data->{surname} = $data->{family_name};
    $data->{user_id} = $data->{id};
    $data->{given_name} = $data->{first_given_name};
    $data->{exp_date} = $data->{expire_date};
    $data->{user_barcode} = ref($data->{card}) ? 
        $data->{card}->{barcode} : $user_barcode;

    return $data;
}

sub get_items_by_record {
    my ($self, $record_id) = @_;

    my $auth = $self->login or return [];

    my $resp = $self->gateway(
        'open-ils.fulfillment', 
        'fulfillment.connector.copy_tree',
        $auth, $record_id
    );
    
    my $cns = $resp->[0];

    # flip
    for my $cn (@$cns) {
        $_->{call_number} = $cn for @{$cn->{copies}};
    }

    my @copies = map {@{$_->{copies}}} @$cns;
    for my $cp (@copies) {
        $cp->{owner} = $cp->{call_number}{owning_lib}{shortname};
        $cp->{call_number} = $cp->{call_number}{label};

        $cp->{bib_id} = $cp->{record_id} = $record_id;
        if ($cp->{circulations} and $cp->{circulations}->[0]) {
            $cp->{due_date} = substr($cp->{circulations}->[0]->{due_date},0,10);
        }

        if (grep { $cp->{status} == $_ } (0,7)) { # if available or reshelving
            # retain the value
        } else {
            $cp->{holdable} = 'f';
        }
    }

    return \@copies;
}

sub get_record_by_id {
    my ($self, $record_id) = @_;

    my $url = sprintf(
        "http://%s/opac/extras/supercat/retrieve/marcxml/record/%s",
        $self->{host}, $record_id
    );

    $logger->info("FF EG get_record_by_id() => $url");

    my $req = HTTP::Request->new("GET" => $url);
    my $res = $ua->request($req);

    if (!$res->is_success) {
        $logger->error(
            "FF Evergreen gateway request error [HTTP ".$res->code."] $url");
        return undef;
    }

    return {
        marc => $res->content,
        error => 0,
        id => $record_id
    };
}

sub get_item {
    my ($self, $barcode) = @_;

    my $auth = $self->login;

    # TODO add fields as needed
    my %fields;
    for my $field (qw/
        id circ_lib barcode location status holdable circulate/) {
        $fields{$field} = {path => $field, display => 1};
    }

    $fields{call_number} = {path => 'call_number.label', display => 1};
    $fields{record_id} = {path => 'call_number.record', display => 1};

    my $resp = $self->gateway(
        'open-ils.fielder',
        'open-ils.fielder.flattened_search',
        $auth, 'acp', \%fields, {barcode => $barcode}
    );

    my $copy = $resp->[0];
    $copy->{bib_id} = $copy->{record_id};

    return $resp->[0];
}

sub get_record_holds {
    my ($self, $record_id) = @_;
    my $auth = $self->login;
    
    # TODO: xmlrpc is dead
    #my $resp = $self->request(
    #'open-ils.circ',
    #'open-ils.circ.holds.retrieve_all_from_title',
    #$key,
    #$bibID,
    #)->value;
}

sub place_lender_hold {
    my $self = shift;
    return $self->place_borrower_hold(@_);
}

sub place_borrower_hold {
    my ($self, $copy_barcode, $user_barcode, $pickup_lib) = @_;

    my $auth = $self->login or return;

    my $resp = $self->gateway(
        'open-ils.fulfillment',
        'fulfillment.connector.create_hold',
        $auth, $copy_barcode, $user_barcode
    );


    $logger->debug("FF Evergreen item hold for copy=$copy_barcode ".
        "user=$user_barcode resulted in ".Dumper($resp));

    # NOTE: fulfillment.connector.create_hold only returns 
    # the hold ID and not the hold object.  is that enough?
    return $$resp[0] if $resp and @$resp;
    return;
}

sub delete_lender_hold {
    my $self = shift;
    return $self->delete_borrower_hold(@_);
}

sub delete_borrower_hold {
    my ($self, $copy_barcode, $user_barcode) = @_;

    my $auth = $self->login or return;

    my $resp = $self->gateway(
        'open-ils.fulfillment',
        'fulfillment.connector.cancel_oldest_hold',
        $auth, $copy_barcode
    );

    # NOTE: fulfillment.connector.cancel_oldest_hold only 
    # returns success or failure.  is that enough?
    return $resp and @$resp and $$resp[0];
}

sub create_borrower_copy {
    my ($self, $ref_copy, $ou_code) = @_;

    my $auth = $self->login or return;
    
    my $resp = $self->gateway(
        'open-ils.fulfillment',
        'fulfillment.connector.create_borrower_copy',
        $auth, $ou_code, $ref_copy->barcode, {
            title => $ref_copy->call_number->record->simple_record->title,
            author => $ref_copy->call_number->record->simple_record->author,
            isbn => $ref_copy->call_number->record->simple_record->isbn,
        }
    );

    my $copy = $resp->[0] if $resp;

    unless ($copy) {
        $logger->error(
            "FF unable to create borrower copy for ".$ref_copy->barcode);
        return;
    }

    $logger->debug("FF created borrower copy " . Dumper($copy));

    return $copy;
}

# borrower checkout uses a precat copy
sub checkout_borrower {
    my ($self, $copy_barcode, $user_barcode) = @_;

    my $args = {
        copy_barcode => $copy_barcode, 
        patron_barcode => $user_barcode,
        request_precat => 1
    };

    return $self->_perform_checkout($args);
}

# to date, lender checkout requires no special handling
sub checkout_lender {
    my ($self, $copy_barcode, $user_barcode) = @_;

    my $args = {
        copy_barcode => $copy_barcode, 
        patron_barcode => $user_barcode
    };

    return $self->_perform_checkout($args);
}

# ---------------------------------------------------------------------------
# attempts a checkout.  
# if the checkout fails with a COPY_IN_TRANSIT event, abort the transit and
# attempt the checkout again.
# ---------------------------------------------------------------------------
sub _perform_checkout {
    my ($self, $args) = @_;
    my $auth = $self->login or return;
    my $copy_barcode = $args->{copy_barcode};

    my $resp = $self->_send_checkout($auth, $args) or return;

    if ($resp->{textcode} eq 'COPY_IN_TRANSIT') {
        # checkout of in-transit copy attempted.  We really want this
        # copy, so let's abort the transit, then try again.

        $logger->info("FF EG attempting to abort ".
            "transit on $copy_barcode for checkout");

        my $resp2 = $self->gateway(
            'open-ils.circ',
            'open-ils.circ.transit.abort',
            $auth, {barcode => $copy_barcode}
        );

        if ($resp2 and $resp2->[0] eq '1') {
            $logger->info(
                "FF EG successfully aborted transit for $copy_barcode");

            # re-do the checkout
            $resp = $self->_send_checkout($auth, $args);

        } else {
            $logger->warn("FF EG unable to abort transit on checkout");
            return;
        }

    } 

    return $resp;
}

sub _send_checkout {
    my ($self, $auth, $args) = @_;

    my $resp = $self->gateway(
        'open-ils.circ',
        'open-ils.circ.checkout.full.override',
        $auth, $args
    );

    if ($resp) {
        # gateway returns an array
        if ($resp = $resp->[0]) {
            # circ may return an array of events; use the first.
            $resp = $resp->[0] if ref($resp) eq 'ARRAY';
            $logger->info("FF EG checkout returned event ".$resp->{textcode});
            return $resp;
        }
    }

    $logger->error("FF EG checkout failed to return a response");
    return;
}


sub checkin {
    my ($self, $copy_barcode, $user_barcode) = @_;
    my $auth = $self->login or return;

    # we want to check the item in at the 
    # correct location or it will go into transit.
    my $fields = {
        id => {path => 'id', display => 1},
        shortname => {path => 'shortname', display => 1}
    };

    my $resp = $self->gateway(
        'open-ils.fielder',
        'open-ils.fielder.flattened_search',
        $auth, 'aou', $fields, {shortname => $self->org_code}
    );

    my $checkin_args = {copy_barcode => $copy_barcode};

    if ($resp and $resp->[0]) {
        $logger->debug("FF EG found org ".Dumper($resp));
        $checkin_args->{circ_lib} = $resp->[0]->{id};
    } else {
        $logger->warn("FF EG unable to locate org unit ".
            $self->org_code.", passing no circ_lib on checkin");
    }

    $resp = $self->gateway(
        'open-ils.circ',
        'open-ils.circ.checkin.override',
        $auth, $checkin_args
    );

    if ($resp) {
        # gateway returns an array
        if ($resp = $resp->[0]) {
            # circ may return an array of events; use the first.
            $resp = $resp->[0] if ref($resp) eq 'ARRAY';
            $logger->info("FF EG checkin returned event ".$resp->{textcode});
            return $resp;
        }
    }

    $logger->error("FF EG checkin failed to return a response");
    return;
}


1;
