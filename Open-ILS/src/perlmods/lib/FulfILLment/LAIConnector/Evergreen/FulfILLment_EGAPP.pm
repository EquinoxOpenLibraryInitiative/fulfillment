use strict;
use warnings;

package OpenILS::Application::FulfILLment_EGAPP;

use OpenILS::Application;
use base qw/OpenILS::Application/;

use OpenSRF::EX qw(:try);
use OpenSRF::Utils::SettingsClient;
use OpenSRF::Utils::Logger qw($logger);

use OpenILS::Utils::Fieldmapper;
use OpenILS::Const qw/:const/;
use OpenILS::Application::AppUtils;
my $U = 'OpenILS::Application::AppUtils';

use OpenILS::Utils::CStoreEditor q/:funcs/;
use Digest::MD5 qw(md5_hex);
use Data::Dumper;

sub login {
    my( $self, $client, $username, $password, $type, $barcode ) = @_;

    $type ||= "staff";

    my $args = { 
        agent => 'fulfillment',
        password => $password,
        type => $type 
    };

    if ($barcode) {
        $args->{barcode} = $barcode;
    } else {
        $args->{username} = $username;
	}

    my $response = $U->simplereq(
        'open-ils.auth',
        'open-ils.auth.login',
        $args
    );

    $logger->warn("No auth response returned on login.") unless $response;

    my $authtime = $response->{payload}->{authtime};
    my $authtoken = $response->{payload}->{authtoken};

    my $ident = $username || $barcode;
    $logger->warn("Login failed for user $ident!") unless $authtoken;

    return $authtoken || '';
}   

__PACKAGE__->register_method(
    method => "login",
    api_name => "fulfillment.connector.login",
    signature => {
            desc => "Authenticate the requesting user",
            params => [
                { name => 'username', type => 'string' },
                { name => 'passwd', type => 'string' },
                { name => 'type', type => 'string' }
            ],
            'return' => {
                desc => 'Returns an authentication token on success, or an empty string on failure'
            }
    }
);

sub lookup_user {
    my ($self, $client, $authtoken, $keys, $value) = @_;

    $keys = [$keys] if (!ref($keys));

    ($authtoken) = $self
        ->method_lookup( 'fulfillment.connector.login' )
        ->run(@$authtoken)
            if (ref $authtoken);

    my $e = new_editor(authtoken => $authtoken);

    return undef unless $e->checkauth;

    for my $k ( @$keys ) {
        my $users = [];
        if ($k eq 'barcode') {
            my $cards = $e->search_actor_card({ $k => $value });
            if (@$cards) {
                $users = $e->search_actor_user([
                    { id => $$cards[0]->usr() },
                    {flesh => 1, flesh_fields => {au => ['card']}}
                ]);
            }
        } else {
            $users = $e->search_actor_user([
                { $k => $value },
                {flesh => 1, flesh_fields => {au => ['card']}}
            ]);
        }

        if ($users->[0]) {

            # user's are allowed to retrieve their own accounts
            # regardless of proxy permissions
            return recursive_hash($users->[0]) 
                if $users->[0]->id eq $e->requestor->id;

            # all other user retrievals require proxy user permissions
            return undef unless $e->allowed('fulfillment.proxy_user');
            return recursive_hash($users->[0]);
        }
    }

    return undef;
}

__PACKAGE__->register_method(
    method => "lookup_user",
    api_name => "fulfillment.connector.lookup_user",
    signature => {
            desc => "Retrieve a user hash",
            params => [
                { name => 'authtoken', type => 'string', desc => 'Either a valid auth token OR an arrayref containing a username and password to log in as' },
                { name => 'keys', type => 'string', 'One or more fields against which to attempt matching the retrieval value, such as "id" or "usrname"' },
                { name => 'lookup_value', type => 'string' }
            ],
            'return' => {
                desc => 'Returns a user hash on success, or nothing on failure'
            }
    }
);

sub verify_user_by_barcode {
    my ($self, $client, $user_barcode, $user_password) = @_;

    my ($authtoken) = $self
        ->method_lookup( 'fulfillment.connector.login' )
        ->run(undef, $user_password, 'opac', $user_barcode);

    return undef unless $authtoken;

    my $user = $U->simplereq(
        'open-ils.auth',
        'open-ils.auth.session.retrieve', 
        $authtoken
    );

    return recursive_hash($user);
}

__PACKAGE__->register_method(
    method => "verify_user_by_barcode",
    api_name => "fulfillment.connector.verify_user_by_barcode",
    signature => {
            desc => q/Given a user barcode and password, returns the 
                user hash if the barcode+password combo is valid/,
            params => [
                {name => 'barcode', type => 'string', desc => 'User barcode'},
                {name => 'password', type => 'string', desc => 'User password'}
            ],
            'return' => {
                desc => 'Returns a user hash on success, or nothing on failure'
            }
    }
);


sub lookup_holds {
    my ($self, $client, $authtoken, $uid) = @_;

    ($authtoken) = $self
        ->method_lookup( 'fulfillment.connector.login' )
        ->run(@$authtoken)
            if (ref $authtoken);

    my $e = new_editor(authtoken => $authtoken);

    return undef unless $e->checkauth;
    return undef unless $e->allowed('fulfillment.proxy_user');

    $uid ||= $e->requestor->id;

    my $holds = $e->search_action_hold_request([
        { usr => $uid, capture_time => undef, cancel_time => undef },
        { order_by => { ahr => 'request_time'  } }
    ]);

    return recursive_hash($holds);
}

__PACKAGE__->register_method(
    method => "lookup_holds",
    api_name => "fulfillment.connector.lookup_holds",
    signature => {
            desc => "Retrieve a list of open holds for a user",
            params => [
                { name => 'authtoken', type => 'string', desc => 'Either a valid auth token OR an arrayref containing a username and password to log in as' }
            ],
            'return' => {
                desc => 'Returns an array of hold hashes on success, or nothing on failure'
            }
    }
);

sub copy_detail {
    my ($self, $client, $authtoken, $barcode ) = @_;

    ($authtoken) = $self
        ->method_lookup( 'fulfillment.connector.login' )
        ->run(@$authtoken)
            if (ref $authtoken);

    my $e = new_editor(authtoken => $authtoken);
    return undef unless $e->checkauth;
    return undef unless $e->allowed('fulfillment.proxy_user');

    my $tree =  $U->simplereq('open-ils.circ', 'open-ils.circ.copy_details.retrieve.barcode', $authtoken, $barcode);

    return recursive_hash($tree);
}

__PACKAGE__->register_method(
    method => "copy_detail",
    api_name => "fulfillment.connector.copy_detail",
    signature => {
            desc => "Fetch a copy tree by bib id, optionally org-scoped",
            params => [
                { name => 'authtoken', type => 'string', desc => 'Either a valid auth token OR an arrayref containing a username and password to log in as' },
                { name => 'barcode', type => 'string', desc => 'Copy barcode' },
            ],
            'return' => {
                desc => 'Returns a fleshed copy on success, or nothing on failure'
            }
    }
);

sub copy_tree {
    my ($self, $client, $authtoken, $bib, @orgs ) = @_;

    ($authtoken) = $self
        ->method_lookup( 'fulfillment.connector.login' )
        ->run(@$authtoken)
            if (ref $authtoken);

    my $e = new_editor(authtoken => $authtoken);
    return undef unless $e->checkauth;
    return undef unless $e->allowed('fulfillment.proxy_user');

    my $tree;
    if (@orgs) {
        $tree =  $U->simplereq('open-ils.cat', 'open-ils.cat.asset.copy_tree.retrieve', $authtoken, $bib, @orgs);
    } else {
        $tree =  $U->simplereq('open-ils.cat', 'open-ils.cat.asset.copy_tree.global.retrieve', $authtoken, $bib);
    }

    $_->owning_lib($U->fetch_org_unit($_->owning_lib)) for @$tree;

    return recursive_hash($tree);
}

__PACKAGE__->register_method(
    method => "copy_tree",
    api_name => "fulfillment.connector.copy_tree",
    signature => {
            desc => "Fetch a copy tree by bib id, optionally org-scoped",
            params => [
                { name => 'authtoken', type => 'string', desc => 'Either a valid auth token OR an arrayref containing a username and password to log in as' },
                { name => 'bib_id', type => 'string', desc => 'Bib id to fetch copies from' },
                { name => 'org', type => 'string', desc => 'Org id for copy scoping; repeatable' },
            ],
            'return' => {
                desc => 'Returns a CN-CP tree on success, or nothing on failure'
            }
    }
);

sub recursive_hash {
    my $obj = shift;

    if (ref($obj)) {
        if (ref($obj) =~ /Fieldmapper/) {
            $obj = $obj->to_bare_hash;
            $$obj{$_} = recursive_hash($$obj{$_}) for (keys %$obj);
        } elsif (ref($obj) =~ /ARRAY/) {
            $obj = [ map { recursive_hash($_) } @$obj ];
        } else {
            $$obj{$_} = recursive_hash($$obj{$_}) for (keys %$obj);
        }
    }

    return $obj;
}


sub create_hold {
    my ($self, $client, $authtoken, $copy_bc, $patron_bc) = @_;

    ($authtoken) = $self
        ->method_lookup( 'fulfillment.connector.login' )
        ->run(@$authtoken)
            if (ref $authtoken);

    my $e = new_editor(authtoken => $authtoken);
    return undef unless $e->checkauth;
    return undef unless $e->allowed('fulfillment.proxy_user');

    my $patron = $e->requestor->id;

    if ($patron_bc) {
        my $p = $e->search_actor_card({barcode => $patron_bc})->[0];
        $patron = $p->usr if $p;
    }

    my $copy = $e->search_asset_copy({barcode => $copy_bc, deleted => 'f'})->[0];
    return undef unless ($copy);

    my $hold = new Fieldmapper::action::hold_request;
    $hold->usr($patron);
    $hold->target($copy->id);
    $hold->hold_type('F');
    $hold->pickup_lib($copy->circ_lib);

    my $resp =  $U->simplereq('open-ils.circ', 'open-ils.circ.holds.create.override', $authtoken, $hold);

    return undef if (ref $resp);
    return $resp;
}

__PACKAGE__->register_method(
    method => "create_hold",
    api_name => "fulfillment.connector.create_hold",
    signature => {
            desc => "Create a new hold",
            params => [
                { name => 'authtoken', type => 'string', desc => 'Either a valid auth token OR an arrayref containing a username and password to log in as' },
                { name => 'copy_bc', type => 'string', desc => 'Copy barcode on which to place a hold' },
                { name => 'patron_bc', type => 'string', desc => 'Patron barcode as which to place a hold, if different from calling user' },
            ],
            'return' => {
                desc => 'Returns a hold id on success, or nothing on failure'
            }
    }
);

sub cancel_proxy_hold {
    my ($self, $client, $authtoken, $copy_bc) = @_;

    ($authtoken) = $self
        ->method_lookup( 'fulfillment.connector.login' )
        ->run(@$authtoken)
            if (ref $authtoken);

    my $e = new_editor(authtoken => $authtoken);
    return undef unless $e->checkauth;
    return undef unless $e->allowed('fulfillment.proxy_user');

    my ($holds) = $self
        ->method_lookup( 'fulfillment.connector.lookup_holds' )
        ->run($authtoken);

    my $copy = $e->search_asset_copy({barcode => $copy_bc, deleted => 'f'})->[0];
    return undef unless ($copy);

    $holds = [ grep { $_->{target} == $copy->id } @$holds ];

    my $resp =  $U->simplereq('open-ils.circ', 'open-ils.circ.hold.cancel', $authtoken, $holds->[0]->{id}) if (@$holds);

    return undef if (ref $resp);
    return $resp;
}

__PACKAGE__->register_method(
    method => "cancel_proxy_hold",
    api_name => "fulfillment.connector.cancel_oldest_hold",
    signature => {
            desc => "Retrieve a list of open holds for a user",
            params => [
                { name => 'authtoken', type => 'string', desc => 'Either a valid auth token OR an arrayref containing a username and password to log in as' },
                { name => 'copy_bc', type => 'string', desc => 'Copy barcode against which to cancel the oldest hold' },
            ],
            'return' => {
                desc => 'Returns 1 on success, or nothing on failure'
            }
    }
);


__PACKAGE__->register_method(
    method => "create_borrower_copy",
    api_name => "fulfillment.connector.create_borrower_copy",
    signature => {
        desc => "Creates a pre-cat copy for borrower holds/circs",
        params => [
            {   name => 'authtoken', 
                type => 'string', 
                desc => q/Either a valid auth token OR an arrayref 
                    containing a username and password to log in as/ 
            },
            {   name => 'ou_code', 
                type => 'string', 
                desc => 'org_unit shortname to use as the copy circ lib' 
            },
            {   name => 'barcode',
                type => 'string',
                desc => q/copy barcode.  Note, if a barcode collision 
                    occurs the barcode of the final copy may be different/,
            },
            {   name => 'args', 
                type => 'hash', 
                desc => 'Hash of optional extra information: title, author, isbn'
            }
        ],
        'return' => {
            desc => 'Copy object (hash) or nothing on failure'
        }
    }
);

sub create_borrower_copy {
    my ($self, $client, $auth, $ou_code, $barcode, $args) = @_;
    $args ||= {};

    ($auth) = $self
        ->method_lookup('fulfillment.connector.login')
        ->run(@$auth) if ref $auth;

    my $e = new_editor(authtoken => $auth, xact => 1);
    my $circ_lib = $e->search_actor_org_unit({shortname => $ou_code});
    if (!@$circ_lib) {
        $logger->error("Unable to locate org unit '$ou_code'");
        $e->rollback;
        return;
    }

    my $e_copy = $e->search_asset_copy(
        {deleted => 'f', barcode => $barcode})->[0];

    # copy with the requested barcode already exists.
    # Add a prefix to the barcode. 
    # TODO: make the prefix a setting
    # TODO: maybe all such copies should be given a prefix for consistency
    if ($e_copy) {
        my $ok_copy;
        if ($e_copy->call_number != -1) {
            $barcode = "FF$barcode";
            $ok_copy = $e->search_asset_copy(
                {deleted => 'f', barcode => $barcode})->[0];
        } else {
            $logger->info("returning preexisting precat copy");
            $ok_copy = $e_copy;
        }

        if ($ok_copy) {
            $ok_copy->circ_lib($circ_lib->[0]->id);
            $ok_copy->dummy_title($args->{title} || "");
            $ok_copy->dummy_author($args->{author} || "");
            $ok_copy->dummy_isbn($args->{isbn} || "");

            $ok_copy->call_number(OILS_PRECAT_CALL_NUMBER);
            $ok_copy->loan_duration(OILS_PRECAT_COPY_LOAN_DURATION);
            $ok_copy->fine_level(OILS_PRECAT_COPY_FINE_LEVEL);
            $ok_copy->status(7); # reshelving

            unless ($e->update_asset_copy($ok_copy)) {
                $logger->error("error updating FF precat copy");
                $e->rollback;
                return;
            }

            $e->commit;
            return recursive_hash($ok_copy);
        }
    }

    my $copy = Fieldmapper::asset::copy->new;
    $copy->barcode($barcode);
    $copy->circ_lib($circ_lib->[0]->id);
    $copy->creator($e->requestor->id);
    $copy->editor($e->requestor->id);

    $copy->call_number(OILS_PRECAT_CALL_NUMBER); 
    $copy->loan_duration(OILS_PRECAT_COPY_LOAN_DURATION);
    $copy->fine_level(OILS_PRECAT_COPY_FINE_LEVEL);
    $copy->status(7); # reshelving

    # if the caller provided any additional metadata on the
    # item we're creating, capture it in the dummy fields
    $copy->dummy_title($args->{title} || "");
    $copy->dummy_author($args->{author} || "");
    $copy->dummy_isbn($args->{isbn} || "");

    unless ($e->create_asset_copy($copy)) {
        $logger->error("error creating FF precat copy");
        $e->rollback;
        return;
    }

    # fetch from DB to ensure updated values (dates, etc.)
    $copy = $e->retrieve_asset_copy($copy->id);
    $e->commit;
    return recursive_hash($copy);
}



1;

