package FulfILLment::LAIConnector;
use strict; use warnings;
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Application::AppUtils;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use FulfILLment::Util::Z3950;
use FulfILLment::Util::SIP2Client;
use FulfILLment::Util::NCIP;
my $U = 'OpenILS::Application::AppUtils';

# Determines the correct connector to load for the provided org
# unit and returns a ref to a new instance of the connector.
# This is the main sub called by external modules.
sub load {
    my ($class, $org_id) = @_;

    return undef unless $org_id;

    # collect all of the FF org unit settings for this org.
    my $settings = new_editor()->search_config_org_unit_setting_type(
        {name => {'like' => 'ff.remote.connector%'}}
    );

    my $cdata = { 
        map {
            $_->name => $U->ou_ancestor_setting($org_id, $_->name)
        } @$settings
    };

    my %args = (org_id => $org_id, extra => {});

    for my $key (keys %$cdata) {
        my $setting = $cdata->{$key};
        my $value = $setting->{value};
        (my $newkey = $key) =~ s/^ff\.remote\.connector\.//;
        if ($newkey =~ /^extra\./) {
            $newkey =~ s/^extra\.//;
            $args{extra}{$newkey} = $value;
        } else {
            $args{$newkey} = $value;
        }
    }

    if (!$args{type}) {
        $logger->error("No ILS type specifed for org unit $org_id");
        return undef;
    }

    if ($args{disabled}) {
        $logger->info("FF connector for ".$args{type}." disabled");
        return;
    }

    return $class->_load_connector($args{type}, $args{version}, \%args);
}

# Returns a new LAIConnector for the specified type
# and (optional) version.  All additional args are
# passed through to the connector constructor.
sub _load_connector {
    my ($class, $type, $version, $args) = @_;

    my $module = "FulfILLment::LAIConnector::$type";
    $module .= "::$version" if $version;

    $logger->info("FF loading ILS module org=$$args{org_id} $module");

    # note: do not wrap in eval {}.  $module->use 
    # uses eval internally and nested evals clobber $@
    $module->use;

    if ($@) {
        $logger->error("Unable to load $module : $@");
        return undef;
    }

    my $connector;
    eval { $connector = $module->new($args) };

    if ($@) {
        $logger->error("Unable to create $module object : $@");
        return undef;
    }

    if (!$connector->init) {
        $logger->error("Error initializing connector $module");
        return undef;
    }

    return $connector;
}

sub new {
    my ($class, $args) = @_;
    $args ||= {};
    return bless($args, $class);
}

sub z39_client {
    my $self = shift;

    if (!$self->{z39_client}) {

        my $host = $self->{extra}{'z3950.host'} || $self->{host};
        my $port = $self->{extra}{'z3950.port'};
        my $database = $self->{extra}{'z3950.database'};

        unless ($host and $port and $database) {
            $logger->info("FF Z39 not configured for $self, skipping...");
            return;
        }

        $self->{z39_client} =
            FulfILLment::Util::Z3950->new(
                $host, $port, $database, 
                $self->{extra}{'z3950.username'},
                $self->{extra}{'z3950.password'}
        );
    }

    return $self->{z39_client};
}

sub sip_client {
    my $self = shift;

    if (!$self->{sip_client}) {

        my $host = $self->{extra}{'sip2.host'} || $self->{host};
        my $port = $self->{extra}{'sip2.port'};

        unless ($host and $port) {
            $logger->info("FF SIP not configured for $self, skipping...");
            return;
        }

        $self->{sip_client} =
            FulfILLment::Util::SIP2Client->new(
                $host, 
                $self->{extra}{'sip2.username'},
                $self->{extra}{'sip2.password'},
                $port, 
                $self->{extra}{'sip2.protocol'}, # undef == SOCK_STREAM
                $self->{extra}{'sip2.institution'}
        );
    }

    return $self->{sip_client};
}

sub ncip_client { 
    my $self = shift;

    if (!$self->{ncip_client}) {
        my $host = $self->{extra}{'ncip.host'} || $self->{host};
        my $port = $self->{extra}{'ncip.port'};

        unless ($host and $port) {
            $logger->info("FF NCIP not configured for $self, skipping...");
            return;
        }

        $self->{ncip_client} = FulfILLment::Util::NCIP->new(
            protocol => $self->{extra}->{'ncip.protocol'},
            host => $host,
            port => $port,
            path => $self->{extra}->{'ncip.path'}, 
            template_paths => ['/openils/var/ncip/v1'], # TODO
            ils_agency_name => $self->{extra}->{'ncip.ils_agency.name'},
            ils_agency_uri => $self->{extra}->{'ncip.ils_agency.uri'},
            ff_agency_name => 'FulfILLment',
            ff_agency_uri => 'http://fulfillment-ill.org/ncip/schemes/agency.scm'
        );
    }

    return $self->{ncip_client};
}


# override with connector-specific initialization as needed
# return true on success, false on failure
sub init {
    my $self = shift;
    return 1;
}

# commonly accessed data

# retursn the connector type (ff.remote.connector.type)
sub type {
    my $self = shift;
    return $self->{type};
}
# returns the connector ILS version string (ff.remote.connector.version)
sub version {
    my $self = shift;
    return $self->{version};
}
# returns the actor.org_unit.id for our current context org unit
sub org_id {
    my $self = shift;
    return $self->{org_id};
}
# returns the actor.org_unit.shortname value for our current context org unit
sub org_code {
    my $self = shift;
    return $self->{org_code} ?  $self->{org_code} :
        $self->{org_code} = 
            new_editor()->retrieve_actor_org_unit($self->org_id)->shortname;
}


# ----------------------------------------------------------------------------
# Below are methods responsible for communicating with remote ILSes.  In some
# cases, default implementations are provided.  This is only done when the 
# implementation could reasonably by used by multiple connectors and only when
# using SIP2 or Z39.50 as the communication layer.
# 
# Connectors should override each method as needed.
# ----------------------------------------------------------------------------

# returns one item
# Default implementation uses SIP2
sub get_item {
    my ($self, $copy_barcode) = @_;

    my $item = 
        $self->sip_client->item_information_request($copy_barcode)
        or return;

    $item->{barcode} = $item->{item_identifier};
    $item->{status} = $item->{circulation_status};
    $item->{location_code} = $item->{permanent_location};

    return $item;
}

# returns a list of items
sub get_item_batch {
    my ($self, $item_idents) = @_;
    return [map {$self->get_item($_)} @$item_idents];
}

# returns a list of items
sub get_items_by_record {
    my ($self, $record_id) = @_;
    return [];
}

# returns a list of items
sub get_items_by_record_batch {
    my ($self, $record_ids) = @_;
    return [map {$self->get_items_by_record($_)} @$record_ids];
}

# returns one record
sub get_record_by_id {
    my ($self, $rec_id) = @_;
    return;
}

# returns one record
sub get_record_by_id_batch {
    my ($self, $rec_ids) = @_;
    return [];
}

# returns one record
sub get_record_by_item {
    my ($self, $item_ident) = @_;
    return [];
}

# returns a list of records
sub get_record_by_item_batch {
    my ($self, $item_idents) = @_;
    return [];
}

# returns 1 user.
# Default implementation uses SIP2
sub get_user {
    my ($self, $user_barcode, $user_pass) = @_;

    my $user = $self->sip_client->lookup_user({
        patron_id => $user_barcode,
        patron_pass => $user_pass
    });

    return unless $user;

    $user->{user_barcode} = $user->{patron_identifier};
    $user->{loaned_items} = $user->{charged_items};
    $user->{loaned_items_count} = $user->{charged_items_count};
    $user->{loaned_items_limit} = $user->{charged_items_limit};
    $user->{lang_pref} = $user->{language};
    $user->{phone} = $user->{home_phone_number};

    # by default, assume name is delivered space-separated
    my @names = split(' ', $user->{personal_name} || $user->{full_name});
    $user->{full_name} = $user->{personal_name};
    $user->{surname} = pop(@names);
    $user->{given_name} = join(' ', @names);

    $user->{billing_address} = $user->{home_address};
    $user->{mailing_address} = $user->{home_address};

    return $user;
}

# returns a list of holds
sub get_item_holds {
    my ($self, $item_ident) = @_;
    return [];
}

# TODO: docs
sub place_borrower_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;
}

# TODO: docs
sub delete_borrower_hold {
    my ($self, $item_barcode, $user_barcode) = @_;
}

# TODO: docs
sub place_lender_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;
}

# TODO: docs
sub delete_lender_hold {
    my ($self, $item_barcode, $user_barcode) = @_;
}

sub get_lender_pickup_lib {
    my ($self, $user_barcode) = @_;

    # first try the org unit setting
    return $self->{extra}->{pickup_location}
        if $self->{extra}->{pickup_location};

    # next try the home org unit of the proxy user
    # NOTE: proxy user may not exist in local DB
    my $user = $self->flesh_user($user_barcode);
    return $user ? $user->home_ou->shortname : undef;
}

# ---------------------------------------------------------------------------
# Provide a default hold placement via SIP
# TODO: turn params into a hash
# ---------------------------------------------------------------------------
sub place_hold_via_sip {
    my $self = shift;
    my $bib_id = shift || ''; # bre.id, not bre.remote_id
    my $copy_barcode = shift || '';
    my $user_barcode = shift || '';
    my $pickup_lib = shift || '';
    my $expire_date = shift;
    my $hold_type = shift;
    my $remote_id = shift;

    if (!$hold_type) {
        # if no hold type is provided, assume passing 
        # a barcode implies a copy-level hold

        # 2 == bib hold
        # 3 == copy hold
        $hold_type = $copy_barcode ? 3 : 2;
    }

    if (!$expire_date) {
        $expire_date =  # interval should be a setting?
            DateTime->now->add({months => 6})->strftime("%Y%m%d    000000");
    }

    $pickup_lib = $self->get_lender_pickup_lib unless $pickup_lib;

    $logger->warn("FF has no pickup lib for $user_barcode") if !$pickup_lib;

    $logger->info("FF placing hold copy=$copy_barcode; ".
        "pickup_lib=$pickup_lib; bib=$bib_id; ".
        "user=$user_barcode; expire=$expire_date");

    # bib holds are placed against the remote id of the bib
    if ($bib_id and not $remote_id) {
        $remote_id = new_editor()->json_query({
            select => {bre => ['remote_id']},
            from => 'bre',
            where => {id => $bib_id}
        })->[0]->{remote_id};
    }
    my $resp = $self->sip_client->place_hold($user_barcode, undef, 
        $expire_date, $pickup_lib, $hold_type, $copy_barcode, $remote_id);

    return undef unless $resp;

    my $blob = $self->translate_sip_hold($resp);
    $blob->{bibID} = $bib_id;
    $blob->{hold_type} = $bib_id ? 'T' : 'C';

    return undef if $blob->{error};
    return $blob;
}

sub translate_sip_hold {
    my ($self, $sip_msg) = @_;

    my $fields = $sip_msg->{fields};
    my $fixed_fields = $sip_msg->{fixed_fields};

    # TODO: verify returned format is sane

    return {
        error => !$fixed_fields->[0],
        error_message => $fields->{AF},
        success_message => $fields->{AF},
        expire_time => $fields->{BW},
        expires => $fields->{BW},
        placed_on => $fixed_fields->[2],
        request_time => $fixed_fields->[2],
        status => $fixed_fields->[1] eq 'Y' ? 'Available' : 'Pending',
        title => $fields->{AJ},
        barcode => $fields->{AB},
        itemid => $fields->{AB},
        pickup_lib => $fields->{BS}
    };
}

# given a copy barcode, this will return the copy whose source lib
# matches my org unit fleshed with its call number and bib record
sub flesh_copy {
    my ($self, $copy_barcode) = @_;

    # find the FF copy so we can get the copy's record_id
    my $copy = new_editor()->search_asset_copy([
        {   barcode => $copy_barcode, source_lib => $self->org_id},
        {   flesh => 2,
            flesh_fields => {
                acp => ['call_number'],
                acn => ['record']
            }
        }
    ])->[0];

    return $copy ? $copy : undef;
}


# given a user barcode, this will return the use whose home lib
# is at or below my org unit, fleshed with home_ou
sub flesh_user {
    my ($self, $user_barcode) = @_;
    
    my $cards = new_editor()->search_actor_card([
        {   barcode => $user_barcode,
            org => $U->get_org_descendants($self->org_id)
        }, {
            flesh => 2,
            flesh_fields => {ac => ['usr'], au => ['home_ou']}
        }
    ]);

    return @$cards ? $cards->[0]->usr : undef;
}




# returns one hold
# pickup_lib is the library code (org_unit.shortname)
sub place_item_hold {
    my ($self, $item_ident, $user_barcode, $pickup_lib) = @_;
    return;
}

# returns one hold
# pickup_lib is the library code (org_unit.shortname)
sub place_record_hold {
    my ($self, $rec_id, $user_barcode, $pickup_lib) = @_;
    return;
}

# returns one hold
# pickup_lib is the library code (org_unit.shortname)
sub delete_item_hold {
    my ($self, $item_ident, $user_barcode, $pickup_lib) = @_;
    return;
}

# returns one hold
# pickup_lib is the library code (org_unit.shortname)
sub delete_record_hold {
    my ($self, $rec_id, $user_barcode, $pickup_lib) = @_;
    return;
}

# returns a list of holds
sub get_record_holds {
    my ($self, $rec_id) = @_;
    return [];
}

# ---------------------------------------------------------------------------
# Allow connectors to provide lender vs. borrower checkout and checkin 
# handling.  Call the stock checkout/checkin methods by default.
# ---------------------------------------------------------------------------
sub checkout_lender {
    my $self = shift;
    return $self->checkout(@_);
}
sub checkout_borrower {
    my $self = shift;
    return $self->checkout(@_);
}
sub checkin_lender {
    my $self = shift;
    return $self->checkin(@_);
}
sub checkin_borrower {
    my $self = shift;
    return $self->checkin(@_);
}

# ---------------------------------------------------------------------------
# Provide default checkout and checkin routines via SIP.
# Override with connector-specific behavior as needed.
# ---------------------------------------------------------------------------
sub checkout {
    my ($self, $item_barcode, $user_barcode) = @_;
    return unless $self->sip_client;
    my $resp = $self->sip_client->checkout($user_barcode, undef, $item_barcode);
    return $self->sip_client->sip_msg_to_circ($resp, 'checkout');
}

sub checkin {
    my ($self, $item_barcode, $user_barcode) = @_;
    return unless $self->sip_client;
    my $resp = $self->sip_client->checkin($user_barcode, undef, $item_barcode);
    return $self->sip_client->sip_msg_to_circ($resp);
}


# ---------------------------------------------------------------------------

# returns one circulation
sub get_circulation {
    my ($self, $item_ident, $user_barcode) = @_;
    return;
}

# ---------------------------------------------------------------------------
# Reference copy is the asset.copy hold target for the lender hold,
# fleshed with ->call_number->record.  The borrower copy is a temporary / 
# dummy copy created at the borrowing library for the purposes of 
# hold placement and circulation at the borrowing library.
# ---------------------------------------------------------------------------
sub create_borrower_copy {
    my ($self, $reference_copy, $circ_lib_code) = @_;
}

# --------------------------------------------------
# -- these method have no corresponding API calls --
# -- their purpose is unclear                     --

sub item_get_page {
    # TODO: params?
    return [];
}
sub item_get_range {
    # TODO: params?
    return [];
}
sub resource_get_page {
    # TODO: params
    return [];
}
sub resource_get_range {
    # TODO: params
    return [];
}
sub resource_get_actor_relation {
    # TODO: params
    return [];
}
sub resource_get_total_pages {
    # TODO: params
    return [];
}
sub resource_get_on_date {
    # TODO: params
    return [];
}
sub resource_get_after_date {
    # TODO: params
    return [];
}
sub resource_get_before_date {
    # TODO: params
    return [];
}
sub actor_get_range {
    # TODO: params
    return [];
}
sub actor_get_page {
    # TODO: params
    return [];
}
sub actor_get_total_pages {
    # TODO: params
    return [];
}
sub actor_list_holds {
    my ($self, $user_barcode) = @_;
    return [];
}
sub get_results_per_page {
    # TODO: params
    return [];
}
sub get_host_ills {
    # TODO: params
    return;
}
sub item_get_total_pages {
    # TODO: params?
    return [];
}
sub item_get_all {
    # TODO: params?
    return [];
}

1;
