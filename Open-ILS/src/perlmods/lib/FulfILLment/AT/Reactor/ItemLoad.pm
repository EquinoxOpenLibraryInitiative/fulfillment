package FulfILLment::AT::Reactor::ItemLoad;
use base 'OpenILS::Application::Trigger::Reactor';
use OpenSRF::Utils::Logger qw($logger);
use OpenILS::Application::AppUtils;
use OpenILS::Utils::CStoreEditor qw/:funcs/;

use strict; use warnings;
use Error qw/:try/;
use OpenSRF::Utils::SettingsClient;

my $U = 'OpenILS::Application::AppUtils';

=comment
$item_template = {

         'isbn_issn_code' => '',
         'call_number' => '',
         'edit_date' => '',
         'create_date' => '',
         'fingerprint' => '',
         'barcode' => '',
         'holdable' => 't',
         'call_number' => '',
         'agency_id' => '',
         'error' => 0,
         'error_message' => ''
};
=cut

sub ByBib {
    my $self = shift;
    my $env = shift;

    my $owner = $env->{target}->owner;
    my $remote_bibid = $env->{target}->remote_id;
    my $bibid = $env->{target}->id;

    my $FF = OpenSRF::AppSession->create('fulfillment.laicore');

    my ($error, $new_items);
    try {
        $new_items = $FF->request( 'fulfillment.laicore.items_by_record', $owner, $remote_bibid)->gather(1);
    } otherwise {
        $error = 1;
    };

    if ($error or !$new_items or !@$new_items) {
        $FF->disconnect;
        return 0;
    }

    my $e = new_editor();
    for my $remote_cp (@$new_items) {
        try {
            $e->xact_begin;
    
            $$remote_cp{call_number} ||= 'UNKNOWN';
    
            $logger->info("Remote copy data: " . join(', ', map { "$_ => $$remote_cp{$_}" } keys %$remote_cp));
    
            my $existing_cp = $e->search_asset_copy(
                { source_lib => $owner, barcode => $$remote_cp{barcode} }
            )->[0];
    
            if (!$existing_cp) {
                $existing_cp = Fieldmapper::asset::copy->new;
                $existing_cp->isnew(1);
                $existing_cp->creator(1);
                $existing_cp->editor(1);
                $existing_cp->loan_duration(2);
                $existing_cp->fine_level(2);
                $existing_cp->source_lib($owner);
                $existing_cp->circ_lib($owner);
                $existing_cp->barcode($$remote_cp{barcode});
            }
    
            $existing_cp->ischanged( 1 );
            #$existing_cp->remote_id( $remote_cp->{bib_id} );
            $existing_cp->holdable( defined($remote_cp->{holdable}) ? $remote_cp->{holdable} : 1 );
            my $due = $remote_cp->{due_date} || ''; # avoid warnings
            $existing_cp->status( $due =~ /^\d+-\d+-\d+$/ ? 1 : 0 );
    
    
            my $existing_cn = $e->search_asset_call_number(
                { record => $bibid, owning_lib => $owner, label => $$remote_cp{call_number} }
            )->[0];
    
            if (!$existing_cn) {
                $existing_cn = Fieldmapper::asset::call_number->new;
                $existing_cn->isnew(1);
                $existing_cn->creator(1);
                $existing_cn->editor(1);
                $existing_cn->label($$remote_cp{call_number});
                $existing_cn->owning_lib($owner);
                $existing_cn->record($bibid);
    
                $existing_cn = $e->create_asset_call_number( $existing_cn );
            }
    
            $existing_cp->call_number( $existing_cn->id );
    
            if ($existing_cp->isnew) {
                $e->create_asset_copy( $existing_cp );
            } else {
                $e->update_asset_copy( $existing_cp );
            }
    
            $e->xact_commit;
        } otherwise {
            $e->xact_rollback;
        };
    }
    $e->disconnect;
    $FF->disconnect;

    return 1;
}

1;
