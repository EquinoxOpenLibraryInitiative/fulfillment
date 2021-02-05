package FulfILLment::AT::Reactor::ItemRefresh;
use base 'OpenILS::Application::Trigger::Reactor';
use OpenSRF::Utils::Logger qw($logger);
use OpenILS::Application::AppUtils;
use OpenILS::Utils::CStoreEditor qw/:funcs/;

use strict; use warnings;
use Error qw/:try/;
use OpenSRF::Utils::SettingsClient;

my $U = 'OpenILS::Application::AppUtils';


sub ByItem {
    my $self = shift;
    my $env = shift;

    update_item($_) for @{$env->{target}};

    return 1;
}

sub ByBib {
    my $self = shift;
    my $env = shift;

    my $e = new_editor();
    for my $cn (@{ $e->search_asset_call_number( { record => $env->{target}->id } ) }) {
        update_item($_) for @{ $e->search_asset_copy( { call_number => $cn->id } ) };
    }

    return 1;
}

sub update_item {
    my $self = shift;
    my $i = shift;

    $i = $self if (!$i);

    my $owner = $i->source_lib;
    my $e = new_editor();
    my $FF = OpenSRF::AppSession->create('fulfillment.laicore');

    my ($error, $new_items);
    try {
        $new_items = $FF->request( 'fulfillment.laicore.item_by_barcode', $owner, $i->barcode)->gather(1);
    } otherwise {
        $error = 1;
    };

    unless ($error) {
        if (@$new_items) {
            my $item = shift @$new_items;

            $i->ischanged(1);
            $i->cache_time('now');
            $i->remote_id($item->{bib_id});
            $i->holdable($item->{holdable});
            $i->status(
                $item->{due_date} =~ /^\d+-\d+-\d+$/ ? 1 : 0
            );

            my $bib = $e->search_biblio_record_entry(
                {remote_id => $item->{bib_id}, owner => $owner}
            )->[0];

            if ($bib) {
                my $cn = $e->search_asset_call_number(
                    {label => $item->{call_number}, record => $bib->id}
                )->[0];
                $i->call_number($cn->id) if ($cn);
            }

            $e->xact_begin;
            $e->update_asset_copy($i) or return $e->die_event;
            return $e->xact_commit;
        }

        return undef;
    }

    return 0;
}

1;
