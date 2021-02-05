package FulfILLment::Application::LAICore;
use strict; use warnings;
use OpenILS::Application;
use base qw/OpenILS::Application/;
use OpenSRF::AppSession;
use OpenSRF::EX qw(:try);
use OpenSRF::Utils::SettingsClient;
use OpenSRF::Utils::Logger qw($logger);
use OpenSRF::Utils::JSON;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Utils::CStoreEditor q/:funcs/;
use FulfILLment::LAIConnector;
use FulfILLment::AT::Reactor::ItemLoad;

sub killme_wrapper {

    my $self = shift;
    my $client = shift;
    my $method = $self->{real_method};
    die "killme_wrapper called without method\n" unless $method;

    $logger->info("FF executing LAICore::$method()");

    my @final = ();
    eval {
      local $SIG{ALRM} = sub { die 'killme' };
      alarm($self->{killme});
      my $this = bless($self,$self->{package});
      @final = $this->$method($client,@_);
      alarm(0);
    };
    alarm(0);

    if ($@) {
        $logger->error("Error executing $method : $@");
        return undef;
    }

    $client->respond($_) for (@final);
    return undef;
}

# TODO : If/when API calls return virtual Fieldmapper 
# objects (or arrays thereof), a wrapper to hash-ify 
# all outbound responses may be in order.

sub register_method {
    my $class = shift;
    my %args = @_;

    $class = ref($class) || $class;
    $args{package} = $class;

    if (exists($args{killme})) {
        $args{real_method} = $args{method};
        $args{method} = 'killme_wrapper';
        return $class->SUPER::register_method( %args );
    }

    $class->SUPER::register_method( %args );
}


__PACKAGE__->register_method(
    method    => "get_connector_info",
    api_name  => "fulfillment.laicore.connector_info.retrieve",
    signature => { params => [ {desc => 'Org Unit ID', type => 'number'} ] },
    argc      => 1,
    api_level => 1
);

sub get_connector_info {
    my ($self, $client, $ou) = @_;
    return undef if ($ou !~ /^\d+$/);
    return FulfILLment::LAIConnector->load($ou);
}

__PACKAGE__->register_method(
    method   => "items_by_barcode",
    api_name => "fulfillment.laicore.item_by_barcode",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "items_by_barcode",
    api_name => "fulfillment.laicore.item_by_barcode.batch",
    killme   => 120
);

sub items_by_barcode {
    my ($self, $client, $ou, $ids) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;

    return $connector->get_item_batch($ids) 
        if $self->api_name =~ /batch/;

    return $connector->get_item($ids);
}

__PACKAGE__->register_method(
    method   => "items_by_record",
    api_name => "fulfillment.laicore.items_by_record",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "items_by_record",
    api_name => "fulfillment.laicore.items_by_record.batch",
    killme   => 120
);
sub items_by_record {
    my ($self, $client, $ou, $ids) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;

    return $connector->get_items_by_record_batch($ids) 
        if $self->api_name =~ /batch/;

    return $connector->get_items_by_record($ids);
}

__PACKAGE__->register_method(
    method   => "records_by_item",
    api_name => "fulfillment.laicore.record_by_item",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "items_by_record",
    api_name => "fulfillment.laicore.record_by_item.batch",
    killme   => 120
);
sub records_by_item {
    my ($self, $client, $ou, $ids) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;

    return $connector->get_record_by_item_batch($ids) 
        if $self->api_name =~ /batch/;

    return $connector->get_record_by_item($ids);
}

__PACKAGE__->register_method(
    method   => "get_holds",
    api_name => "fulfillment.laicore.holds_by_item",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "get_holds",
    api_name => "fulfillment.laicore.holds_by_record",
    killme   => 120
);
# target is copy_barcode or record_id
sub get_holds {
    my ($self, $client, $ou, $target, $user_barcode) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;

    return $connector->get_item_holds($target, $user_barcode)
        if $self->api_name =~ /by_item/;

    return $connector->get_record_holds($target, $user_barcode);
}

__PACKAGE__->register_method(
    method   => "lender_holds",
    api_name => "fulfillment.laicore.hold.lender.place",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "lender_holds",
    api_name => "fulfillment.laicore.hold.lender.delete_earliest",
    killme   => 120
);

sub lender_holds {
    my ($self, $client, $ou, $copy_barcode) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;
    my $e = new_editor();

    # for lending library holds, we use the configured hold user
    my $user_barcode = $connector->{'user.hold'} || $connector->{'user'};

    if (!$user_barcode) {
        $logger->error(
            "FF no hold recipient defined for ou=$ou copy=$copy_barcode");
        return;
    }

    # TODO: proxy user pickup lib setting?
    return $connector->place_lender_hold($copy_barcode, $user_barcode)
        if $self->api_name =~ /place/;

    return $connector->delete_lender_hold($copy_barcode, $user_barcode);
}

__PACKAGE__->register_method(
    method   => "create_borrower_copy",
    api_name => "fulfillment.laicore.item.create_for_borrower",
    killme   => 120
);
sub create_borrower_copy {
    my ($self, $client, $ou, $src_copy_id) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;
    my $e = new_editor();

    my $src_copy = $e->retrieve_asset_copy([
        $src_copy_id,
        {   flesh => 3, 
            flesh_fields => {
                acp => ['call_number'], 
                acn => ['record'],
                bre => ['simple_record']
            }
        }
    ]);

    my $circ_lib = $e->retrieve_actor_org_unit($ou)->shortname;

    return $connector->create_borrower_copy($src_copy, $circ_lib);
}


__PACKAGE__->register_method(
    method   => "borrower_holds",
    api_name => "fulfillment.laicore.hold.borrower.place",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "borrower_holds",
    api_name => "fulfillment.laicore.hold.borrower.delete_earliest",
    killme   => 120
);
# ---------------------------------------------------------------------------
# Borrower Library Holds:
#   Create a hold against the temporary copy for the borrowing user
#   at the borrowing library.
# ---------------------------------------------------------------------------
sub borrower_holds {
    my ($self, $client, $ou, $copy_barcode, $user_barcode) = @_;

    # TODO: should be a pickup_lib here based on the pickup_lib
    # of the FF hold

    my $connector = FulfILLment::LAIConnector->load($ou) or return;
    my $e = new_editor();
    my $pickup_lib = $e->retrieve_actor_org_unit($ou)->shortname;

    return $connector->place_borrower_hold(
        $copy_barcode, $user_barcode, $pickup_lib)
        if $self->api_name =~ /place/;

    return $connector->delete_borrower_hold($copy_barcode, $user_barcode);
}


__PACKAGE__->register_method(
    method   => "circulation",
    api_name => "fulfillment.laicore.circ.retrieve",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "circulation",
    api_name => "fulfillment.laicore.circ.lender.checkout",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "circulation",
    api_name => "fulfillment.laicore.circ.lender.checkin",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "circulation",
    api_name => "fulfillment.laicore.circ.borrower.checkout",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "circulation",
    api_name => "fulfillment.laicore.circ.borrower.checkin",
    killme   => 120
);
sub circulation {
    my ($self, $client, $ou, $item_ident, $user_barcode) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;

    if ($self->api_name =~ /lender/) {
        # the circulation on the lender side is always checked
        # out to the circ proxy user.

        $user_barcode = $connector->{'user.circ'} || $connector->{'user'};
        if (!$user_barcode) {
            $logger->error("FF proxy circ user defined for $ou");
            return;
        }
    }

    if ($self->api_name =~ /checkout/) {

        return $connector->checkout_lender($item_ident, $user_barcode)
            if $self->api_name =~ /lender/;

        return $connector->checkout_borrower($item_ident, $user_barcode);
    } 
    
    if ($self->api_name =~ /checkin/) {

        return $connector->checkin_lender($item_ident, $user_barcode)
            if $self->api_name =~ /lender/;

        return $connector->checkin_borrower($item_ident, $user_barcode);
    }

    return $connector->get_circulation($item_ident, $user_barcode);
}

__PACKAGE__->register_method(
    method   => "records_by_id",
    api_name => "fulfillment.laicore.record_by_id",
    killme   => 120
);
__PACKAGE__->register_method(
    method   => "records_by_id",
    api_name => "fulfillment.laicore.record_by_id.batch",
    killme   => 120
);
sub records_by_id {
    my ($self, $client, $ou, $ids) = @_;

    my $connector = FulfILLment::LAIConnector->load($ou) or return;

    return $connector->get_record_by_id_batch($ids)
        if $self->api_name =~ /batch/;

    return $connector->get_record_by_id($ids);
}

__PACKAGE__->register_method(
    method   => "lookup_user",
    api_name => "fulfillment.laicore.lookup_user",
    killme   => 120
);

sub lookup_user {
    my ($self, $client, $ou, $user_barcode, $user_pass) = @_;
    my $connector = FulfILLment::LAIConnector->load($ou) or return;
    return $connector->get_user($user_barcode, $user_pass);
}

__PACKAGE__->register_method(
    method   => "import_items_by_record",
    api_name => "fulfillment.laicore.import_items_by_record",
    killme   => 120,
    signature => q/
        Import items from the remote site via remote record ID.
        Returns true on success, false on failure.
    /
);
sub import_items_by_record {
    my ($self, $client, $ou, $record_id) = @_;
    FulfILLment::LAIConnector->load($ou) or return;
    my $e = new_editor();

    # record_id param refers to the remote_id
    my $rec = $e->search_biblio_record_entry(
        {owner => $ou, remote_id => $record_id}
    )->[0] or return;

    return FulfILLment::AT::Reactor::ItemLoad->ByBib({target => $rec});
}


1;

