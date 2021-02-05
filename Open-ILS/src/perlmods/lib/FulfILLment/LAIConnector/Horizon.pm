package FulfILLment::LAIConnector::Horizon;
use base FulfILLment::LAIConnector;
use strict; use warnings;
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Utils::Fieldmapper;
use FulfILLment::Util::Z3950;
use FulfILLment::Util::SIP2Client;
use XML::LibXML;
use Data::Dumper;
use Encode;
use Unicode::Normalize;
use DateTime;
use MARC::Record;
use MARC::File::XML ( BinaryEncoding => 'utf8' );
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Application::AppUtils;
my $U = 'OpenILS::Application::AppUtils';

sub get_item {
    my ($self, $item_ident) = @_;

    my $sip_item = $self->sip_client->item_information_request($item_ident);
    return unless $sip_item;

    my $item = $sip_item;
    $item->{barcode} = $sip_item->{item_identifier};
    $item->{status} = $sip_item->{circulation_status};
    $item->{location_code} = $sip_item->{permanent_location};

    return $item;
}

sub get_item_batch {
    my ($self, $item_barcodes) = @_;
    return [map {$self->get_item($_)} @$item_barcodes];
}

sub get_record_by_id {
    my ($self, $record_id) = @_;

    my $bib = {}; 
    my $attr =  $self->{args}{extra}{'z3950.search_attr'};
    my $xml = $self->z39_client->get_record_by_id($record_id, $attr);

    # TODO: clean this up
    if ($xml =~ /something went wrong/) {
          $bib->{'error'} = 1;
          $bib->{'error_message'} = $xml;
    } else {
         $bib->{'marc'} = $xml;
         $bib->{'id'} = $record_id;
    }   

    return $bib;
}



=comment Format for holdings via Z39.50

<holdings>
 <holding>
  <localLocation>LIB NAME</localLocation>
  <shelvingLocation>Juvenile Fiction</shelvingLocation>
  <callNumber>J ROWLING</callNumber>
  <circulations>
   <circulation>
    <availableNow value="1"/>
    <restrictions>LIB NAME</restrictions>
    <itemId>1234567890</itemId>
    <renewable value="1"/>
    <onHold value="0"/>
    <temporaryLocation>Checked In</temporaryLocation>
   </circulation>
  </circulations>
 </holding>
 ...
=cut

sub get_items_by_record {
    my ($self, $record_id) = @_;

    my $attr =  $self->{args}{extra}{'z3950.search_attr'};
    my $xml = $self->z39_client->get_record_by_id($record_id, $attr, undef, 'opac', 1);

    # entityize()
    $xml = decode_utf8($xml);
    NFC($xml);
    $xml =~ s/&(?!\S+;)/&amp;/gso;
    $xml =~ s/([\x{0080}-\x{fffd}])/sprintf('&#x%X;',ord($1))/sgoe;

    # strip control chars, etc.
    # silence 'uninitialized value in substitution iterator'
    no warnings;
    $xml =~ s/([\x{0000}-\x{001F}])//sgoe; 
    use warnings;

    my $doc = XML::LibXML->new->parse_string($xml);

    my %map = (
        circ_lib => 'localLocation',
        location => 'shelvingLocation',
        call_number => 'callNumber',
        barcode => 'itemId',
        status => 'temporaryLocation'
    );

    my @copies;
    for my $node ($doc->findnodes('//holding')) {
        my $copy = {};

        for my $key (keys %map) {
            my $fnode = $node->getElementsByTagName($map{$key})->[0];
            $copy->{$key} = $fnode->textContent if $fnode;
        }

       push(@copies, $copy);
    }

    return \@copies;
}

sub get_user {
    my ($self, $user_barcode, $user_pass) = @_;

    # fetch the user using the default implementation
    my $user = $self->SUPER::get_user($user_barcode, $user_pass);
    return unless $user;

    # munge the names...
    # personal_name is delivered => SURNAME, GIVEN NAME
    my @names = split(',', $user->{personal_name} || $user->{full_name});
    $user->{full_name} = $user->{personal_name};
    $user->{given_name} = $names[1];
    $user->{surname} = $names[0];

    return $user;
}

# copy hold
sub place_borrower_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;
    return $self->place_hold_via_sip(
        undef, $item_barcode, $user_barcode, $pickup_lib);
}

# bib hold
sub place_lender_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;

    my $copy = $self->flesh_copy($item_barcode) or return;

    return $self->place_hold_via_sip(
        $copy->call_number->record->id,
        undef, # item_barcode
        $user_barcode, 
        $pickup_lib
    );
}

sub delete_borrower_hold {
    my ($self, $item_barcode, $user_barcode) = @_;

    my $resp = $self->sip_client->delete_hold(
        $user_barcode, 
        undef, undef, undef, undef, 
        $item_barcode
    );

    return $resp ? $self->translate_sip_hold($resp) : undef;
}

sub delete_lender_hold {
    my ($self, $item_barcode, $user_barcode) = @_;
    my $copy = $self->flesh_copy($item_barcode) or return;
    
    my $resp = $self->sip_client->delete_hold(
        $user_barcode, 
        undef, undef, undef, undef, undef,
        $copy->call_number->record->id
    );

    return $resp ? $self->translate_sip_hold($resp) : undef;
}

sub delete_item_hold {
    my ($self, $item_ident, $user_barcode) = @_;

    my $resp = $self->sip_client->delete_hold(
        $user_barcode, undef, undef, undef, undef, $item_ident);

    return unless $resp;
    return $self->translate_sip_hold($resp);
}

sub delete_record_hold {
    my ($self, $record_id, $user_barcode) = @_;

    my $resp = $self->sip_client->delete_hold(
        $user_barcode, undef, undef, undef, undef, undef, $record_id);

    return [] unless $resp;

    my $blob = $self->translate_sip_hold($resp);
    $blob->{bibID} = $record_id;
    return $blob;
}


# ---------------------------------------------------------
# BELOW NEEDS RE-TESTING
# ---------------------------------------------------------

sub get_user_holds {
    my $self = shift;
    my $user_barcode = shift;
    my $user_pass = shift;
    my @holds;

    # TODO: requiring user_pass may be problematic...  

    # Horizon provides available holds and unavailable holds in
    # separate lists, which requires multiple patron info requests.
    # FF does not differentiate, though, so collect them all 
    # into one patron holds list.

    # available holds
    my $user = $self->sip_client->lookup_user({
        patron_id => $user_barcode,
        patron_pass => $user_pass
    });

    # TODO: fix the Available/Pending statuses?

    if ($user) {
        $logger->debug("User hold items = @{$user->{hold_items}}");
        push(@holds, translate_patron_info_hold($_, 'Available')) 
            for @{$user->{hold_items}};
    }

    # unavailable holds
    $user = $self->sip_client->lookup_user({
        patron_id => $user_barcode,
        patron_pass => $user_pass,
        enable_summary_pos => 5
    });

    if ($user) {
        $logger->debug("User pending hold items = @{$user->{hold_items}}");
        push(@holds, translate_patron_info_hold($_, 'Pending')) 
            for @{$user->{hold_items}};
    }

    return \@holds;
}

sub translate_patron_info_hold {
    my ($txt, $status) = @_;

    # Horizon SIP2 patron info hold format
    # |CDSOFFTESTB12 CENT 06/05/13 $0.00 b SO FF Test Book 1|
    # |CDSOFFTESTB22 CENT 06/05/13 $0.00 b SO FF Test Book 2|

    my ($barcode, undef, $xact_start, undef, undef, $title) = split(' ', $txt);

    return {
        placed_on => $xact_start,
        status => $status,
        title => $title,
        barcode => $barcode,
        itemid => $barcode
    };
}

sub create_borrower_copy {
    my ($self, $ref_copy, $ou_code) = @_;

    return unless $self->ncip_client;

    my $simple_rec = $ref_copy->call_number->record->simple_record;

    my ($doc, @errs) = $self->ncip_client->request(
        'CreateItem',
        item => {
            barcode => $ref_copy->barcode,
            call_number => $ref_copy->call_number->label,
            title => $simple_rec->title,
            author => $simple_rec->author,
            owning_lib => $ou_code
        }
    );


    @errs = ('See Error Log') unless @errs or $doc;

    if (@errs) {
        $logger->error(
            "FF unable to create borrower copy ".
                $ref_copy->barcode." : @errs");
        return;
    }

    my $barcode = $doc->findnodes(
        '//CreateItemResponse/UniqueItemId/ItemIdentifierValue'
    )->string_value;

    if (!$barcode) {
        $logger->error("FF unable to create borrower copy : ".$doc->toString);
        return;
    }

    $logger->info("FF created borrower copy $barcode");

    return {barcode => $barcode};
}


1;
