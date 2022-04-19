package FAKECACHE; # Mock cache for testing only

sub new {
    return bless {}, shift;
}

sub get_cache {
    my $self = shift;
    my $key = shift;
    delete $$self{$key} if ($$self{$key}{expire} && time > $$self{$key}{expire});
    return $$self{$key}{value};
}

sub put_cache {
    my $self = shift;
    my $key = shift;
    my $val = shift;
    my $exp = shift;
    $$self{$key}{value} = $val;
    if ($exp) {
        $$self{$key}{expire} = time + $exp;
    } else {
        delete $$self{$key}{expire};
    }
    return $val
}

package FulfILLment::LAIConnector::Sierra;
use base FulfILLment::LAIConnector;
use strict; use warnings;
use OpenSRF::Utils::Logger qw/$logger/;
use OpenSRF::Utils::Cache;
use OpenILS::Event;
use Digest::MD5 qw(md5_hex);
use LWP::UserAgent;
use URI::Escape;
use MIME::Base64 qw(encode_base64);
use Encode qw(encode);
use HTTP::Request;
use JSON::XS;
use Data::Dumper;

my $C = 'SIERRA_FF:';

my $json = JSON::XS->new;
$json->allow_nonref(1);

my $ua = LWP::UserAgent->new;
$ua->agent("FulfILLment/1.0");

sub init {
    my $self = shift;
    $self->{cache} = OpenSRF::Utils::Cache->new('global');
}

sub TEST_new {
    my $pkg = shift;
    my $self = bless {
        extra => {
            client_key    => '',
            client_secret => '',
            apiPath       => 'iii/sierra-api',
            apiVersion    => 'v6',
            barcode_as_pw => 0, # make true if library uses user=name, pw=barcode
        },
        host => 'catalog.library.org',
        user => 'staff-proxy-user-barcode',
        cache => FAKECACHE->new()
    } => $pkg;

    return $self;
}

sub accessToken {
    my $self = shift;
    my $cache = $self->{cache};

    my $t_key = $C .'auth:'. $self->{extra}{client_key};
    my $at = $cache->get_cache( $t_key );

    return $at if ($at);

    my $uri = sprintf(
        'https://%s/%s/token',
        $self->{host}, $self->{extra}{apiPath}
    );

    my $auth = $self->{extra}{client_key} . ':' . $self->{extra}{client_secret};

    my $req = HTTP::Request->new(POST => $uri);
    $req->header('Content-Type', 'application/x-www-form-urlencoded');
    $req->header('Accept-Language', 'en');
    $req->header('Cache-Control', 'no-cache');
    $req->header('Pragma', 'no-cache');
    $req->header('Authorization', 'Basic '. encode_base64($auth));
    $req->content('grant_type=client_credentials');

    my $res = $ua->request($req);
    if (!$res->is_success) {
        $logger->error(
            "FF Sierra REST auth token request error [HTTP ".$res->code."] $uri\n". Dumper($req) . "\n" . Dumper($res));
        return undef;
    }

    my $t = decode_json($res->content);
    $cache->put_cache( $t_key => $$t{access_token} => $$t{expires_in} - 10 );
    $logger->info("New Sierra access token $$t{access_token}");
    return $$t{access_token};
}

sub makeRequest {
    my ($self, $httpMethod, $path, $plist, $content, $return_status, $contentType) = @_;
    $plist //= [];
    my $params = { @$plist };
    my $pstring = '';

    $path ||= [];
    $content ||= '';
    $contentType ||= 'application/json';

    my $api_path = $self->{extra}{apiPath} || 'iii/sierra-api';
    my $api_ver  = $self->{extra}{apiVersion} || 'v6';
    my $uri = sprintf(
        'https://%s/%s/%s/%s',
        $self->{host}, $api_path, $api_ver, 
        join('/', @$path)
    );

    if (keys %$params) {
        $pstring = join '&', map { "$_=" . uri_escape_utf8($$params{$_}) } keys %$params;
    }

    $uri .= '?' . $pstring if ($pstring);

    my $req = HTTP::Request->new($httpMethod => $uri);
    $req->header('Content-Type', $contentType);
    $req->header('Accept', $contentType);
    $req->header('Accept-Language', 'en');
    $req->header('Authorization', 'Bearer '. $self->accessToken);
    $req->content($content) if ($content);

    $logger->info("FF Sierra REST request => $httpMethod : $uri : $content");

    my $res = $ua->request($req);

    if (!$res->is_success) {
        $logger->error("FF Sierra REST request error [HTTP ".$res->code."] $httpMethod : $uri");
        $logger->error(" ... Request object: ".Dumper($req));
        $logger->error(" ... Response object: ".Dumper({ map { ($_ => $$res{$_}) } grep { $_ ne '_request' } keys %$res }));
    }

    my $value = $res->content;
    $value = decode_json($value) if ($value && $contentType =~ /json/);
    return { status => $res->code, content => $value } if ($return_status);
    return $value;
}

sub makeRequest_checkdigit_retry {
    my $self = shift;
    my $where = shift;
    my $meth = shift;
    my $path = shift;
    my $params = shift;
    my $content = shift;
    my $return_status = shift;
    my $ctype = shift;

    my $struct = {
        path   => $path,
        params => $params,
    };

    my $res = $self->makeRequest(
        $meth => $path => $params => $content,
        1, $ctype
    );

    if ($res->{status} == 404) { # retry
        my ($part_key, $part_ind) = each %$where;
        chop $$struct{$part_key}[$part_ind];

        return $self->makeRequest(
            $meth => $path => $params => $content,
            $return_status, $ctype
        );
    }

    return $res if ($return_status);
    return $res->{content};
}

sub get_user {
    my $self = shift;
    my $user_barcode = shift;
    my $user_password = shift;

    my @fields = qw/names emails homeLibraryCode barcodes expirationDate/;

    my $resp;
    if ($user_password && $self->{extra}{barcode_as_pw}) { # no pin/pw, just "user = name, pw = barcode"
        ($user_barcode, $user_password) = ($user_password, $user_barcode);

        $resp = $self->makeRequest(
            GET => [qw/patrons find/], [
                varFieldTag => 'b',
                varFieldContent => $user_barcode,
                fields => join(',', @fields)
            ], '', 1
        );

        if ($resp->{status} == 200) {
            $resp = $resp->{content};
            return OpenILS::Event->new("ACTOR_USER_NOT_FOUND", error => 1) unless (grep { (my $x = $_) =~ s/\s//g; lc($x) eq lc($user_password) } @{$$resp{names}});
        }
        return OpenILS::Event->new("ACTOR_USER_NOT_FOUND", error => 1) unless (grep { (my $x = $_) =~ s/\s//g; lc($x) eq lc($user_password) } @{$$resp{names}});
    } else {
        if ($user_password) { # verify a user by password
            my $ameth = $self->{extra}{patron_auth_method} || 'native';
            $resp = $self->makeRequest(
                POST => [qw/patrons auth/], [],
                encode_json({
                    authMethod   => $ameth,
                    patronId     => $user_barcode,
                    patronSecret => $user_password
                }), 1
            );
            return OpenILS::Event->new("ACTOR_USER_NOT_FOUND", error => 1) unless ($resp->{status} == 204);

            $self->{cache}->put_cache( $C.'pw:'.$user_barcode => $user_password );

            $resp = $self->makeRequest(
                GET => [patrons => $resp->{content}], [
                    fields => join(',', @fields)
                ]
            );
        } else { # look up a user via barcode using proxy
            $resp = $self->makeRequest(
                GET => [qw/patrons find/], [
                    varFieldTag => 'b',
                    varFieldContent => $user_barcode,
                    fields => join(',', @fields)
                ]
            );
            return OpenILS::Event->new("ACTOR_USER_NOT_FOUND", error => 1) unless ($resp->{id});
        }
    }

    # TODO: we always assume barcode logins in FF
    $logger->info("Sierra retreived user " . Dumper($resp));

    my $nameparts = split_name($$resp{names}[0]);
    $resp->{given_name} = $$nameparts[0];
    $resp->{surname} = $$nameparts[1];
    $resp->{user_id} = $resp->{id};
    $resp->{exp_date} = $resp->{expirationDate};
    $resp->{user_barcode} = $resp->{barcodes}[0];
    $resp->{email} = $resp->{emails}[0] if $resp->{emails};

    return $resp;
}

sub split_name {
    my $name = shift;

    my @parts = split /,\s+/, $name;
    if (@parts > 1) { # last, first
        return [$parts[1], $parts[0]];
    }

    @parts = split /\s+/, $name;
    if (@parts > 1) { # first [middle] last
        return [$parts[0], $parts[-1]];
    }

    return ['',$name]; # justOneName (consider it lastname)
}

sub get_items_by_record {
    my ($self, $record_id) = @_;
    $record_id =~ s/\D//g; # "b" prefix, be gone!

    my @fields = qw/status barcode callNumber location bibIds/;
    my $resp = $self->makeRequest_checkdigit_retry(
        { params => 1 },
        GET => ['items'], [
            bibIds => $record_id,
            fields => join(',', @fields)
        ]
    );

    my @copies;
    for my $cp (@{$resp->{entries}}) {
        next if ($cp->{deleted});
        push @copies, $self->flesh_item($cp)
    }

    return \@copies;
}

sub get_record_by_id {
    my ($self, $record_id) = @_;
    $record_id =~ s/\D//g;

    my $resp = $self->makeRequest_checkdigit_retry(
        { path => 1 },
        GET => [ bibs => $record_id => 'marc' ],
        [], '', 0,
        'application/marc-xml'
    );

    $resp =~ s/\n//gso; # one line
    $resp =~ s/>\s+</></gso; # no extra space
    $resp =~ s/^<\?xml.+?\?>//; # toss the PI
    $resp =~ s/(<\/?)marcxml:/$1/g; # remove NS prefix
    $resp =~ s/<record>/<record xmlns="http:\/\/www.loc.gov\/MARC21\/slim">/; # add default NS prefix
    $resp =~ s/<collection[^>]*?>//; # remove <collection> wrapper
    $resp =~ s/<\/collection>//; # remove <collection> wrapper

    return {
        marc => $resp,
        error => 0,
        id => $record_id
    };
}

sub get_item {
    my ($self, $barcode) = @_;
    $barcode = [$barcode] if (!ref($barcode));

    my $resp = $self->makeRequest(
        POST => [ items => 'query' ],
        [ limit => 1, offset => 0 ],
        encode_json({
            target => {
                record => { type => 'item' },
                field  => { tag  => 'b'    },
            },
            expr => {
                operands => $barcode,
                op       => 'equals'
            }
        })
    );

    return undef unless $resp && @{$resp->{entries}};

    my $c_id = [split '/', $resp->{entries}[0]{link}]->[-1];

    return $self->get_item_by_id($c_id);
}

sub get_item_by_id {
    my ($self, $id) = @_;
    return undef unless $id;

    $id =~ s/\D//g;

    return $self->flesh_item(
        $self->makeRequest_checkdigit_retry(
            { path => 1 },
            GET => [ items => $id ]
        )
    );

}

sub flesh_item {
    my ($self, $cp) = @_;

    $cp->{bib_id} = $cp->{record_id} = $cp->{bibIds}[0];
    $cp->{owner} = $cp->{location}{code};
    $cp->{call_number} = $cp->{callNumber};

    if ($cp->{status}{duedate}) {
        $cp->{due_date} = [split 'T', $cp->{status}{duedate}]->[0];
    }

    if ($cp->{status}{code} eq '-') { # if available
        $cp->{holdable} = 't';
    } else {
        $cp->{holdable} = 'f';
    }

    return $cp;
}

sub get_record_holds {
    my ($self, $record_id) = @_;
}

sub place_lender_hold {
    my $self = shift;
    return $self->place_borrower_hold(@_);
}

sub place_borrower_hold {
    my ($self, $copy_barcode, $user_barcode, $pickup_lib) = @_;
    my $usr = $self->get_user($user_barcode);
    my $pu_lib = $usr->{homeLibraryCode};

    my $item = $self->get_item($copy_barcode);

    return $self->makeRequest(
        POST => [ patrons => $usr->{user_id} => holds => 'requests' ],
        [], encode_json({
            recordType => 'i',
            recordNumber => int($item->{id}),
            pickupLocation => $pu_lib
        })
    );
}

sub _get_user_holds {
    my ($self, $user_barcode) = @_;
    my $usr = $self->get_user($user_barcode);

    return $self->makeRequest(
        GET => [ patrons => $usr->{user_id} => 'holds' ]
    );
}

sub delete_lender_hold {
    my $self = shift;
    return $self->delete_borrower_hold(@_);
}

sub delete_borrower_hold {
    my ($self, $copy_barcode, $user_barcode) = @_;

    my $item = $self->get_item($copy_barcode);
    return undef unless $item;

    my $holds = $self->_get_user_holds($user_barcode)->{entries};
    for my $h (@$holds) {
        if ($$h{recordType} eq 'i') {
            my $c_id = [split '/', $$h{record}]->[-1];
            if ($$item{id} == $c_id) {
                my $h_id = [split '/', $$h{id}]->[-1];
                return $self->makeRequest(
                    DELETE => [ patrons => holds => $h_id ]
                );
            }
        }
    }

    return undef;
}

sub create_borrower_copy {
    my ($self, $ref_copy, $ou_code) = @_;

    my $itemPatch = {
            barcodes => [ $ref_copy->barcode ],
            messages => ['ILL: ' . join(
                ' / ',
                grep { defined($_) && $_ ne '' }
                    $ref_copy->call_number->record->simple_record->title,
                    $ref_copy->call_number->record->simple_record->author,
                    $ref_copy->call_number->record->simple_record->isbn
            )],
            owningLocations => [ $ou_code ]
    };

    my $copy = $self->get_item($ref_copy->barcode);
    if ($copy && $$copy{barcode}) {
        $logger->debug("FF found a preexisting Sierra borrower copy " . Dumper($copy));
        return $copy;
    }

    my $cp_link = $self->makeRequest(
        POST => [ 'items' ], [], encode_json($itemPatch)
    )->{'link'};

    if ($cp_link) {
        my $c_id = [split '/', $cp_link]->[-1];
        $copy = $self->get_item_by_id($c_id);
    }

    unless ($copy) {
        $logger->error(
            "FF unable to create Sierra borrower copy for ".$ref_copy->barcode);
        return;
    }

    $logger->debug("FF created Sierra borrower copy " . Dumper($copy));

    return $copy;
}

# borrower checkout attempts to create a bib-less copy
sub checkout_borrower {
    my ($self, $copy_barcode, $user_barcode) = @_;

    my $copy = $self->create_borrower_copy($copy_barcode);
    return $self->checkout_lender($copy_barcode, $user_barcode)
        if ($copy);

    return undef;
}

# to date, lender checkout requires no special handling
sub checkout_lender {
    my ($self, $copy_barcode, $user_barcode) = @_;

    my $args = {
        itemBarcode => $copy_barcode, 
        patronBarcode => $user_barcode
    };

    return $self->_send_checkout($args);
}

sub _send_checkout {
    my ($self, $args) = @_;

    my $resp = $self->makeRequest(
        PUT => [ patrons => 'checkout' ],
        [], encode_json($args)
    );

    return $logger->error("FF Sierra checkout failed to return a response") if (!$resp);
    return $logger->debug("FF Sierra checkout URI: $resp");
}

sub _get_proxy_checkouts {
    my ($self) = @_;

    my $uid = $self->get_user($self->{user})->{user_id};
    my $resp = $self->makeRequest(
        GET => [ patrons => $uid => 'checkouts' ],
        [fields => 'default,barcode,callNumber,numberOfRenewals']
    );

    return $resp->{entries};
}


sub checkin {
    my ($self, $copy_barcode) = @_;

    return $self->makeRequest(
        DELETE => [ items => checkouts => $copy_barcode]
    );
}


1;
