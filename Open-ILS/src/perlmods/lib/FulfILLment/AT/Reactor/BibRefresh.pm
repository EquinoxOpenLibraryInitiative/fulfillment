package FulfILLment::AT::Reactor::BibRefresh;
use base 'OpenILS::Application::Trigger::Reactor';
use OpenSRF::Utils::Logger qw($logger);
use OpenILS::Application::AppUtils;
use OpenILS::Utils::CStoreEditor qw/:funcs/;

use strict; use warnings;
use Error qw/:try/;
use OpenSRF::Utils::SettingsClient;

my $U = 'OpenILS::Application::AppUtils';
my $FF = OpenSRF::AppSession->create('fulfillment.laicore');

sub handler {
    my $self = shift;
    my $env = shift;

    update_bib($_) for @{$env->{target}};

    return 1;
}

sub update_bib {
    my $self = shift;
    my $b = shift || $self;
    my $e = new_editor();

    my $owner = $b->owner;
    my ($error, $new_bibs);

    try {
        $new_bibs = $FF->request( 'fulfillment.laicore.record_by_id', $owner, $b->remote_id)->gather(1);
    } otherwise {
        $error = 1;
    };

    unless ($error) {
        if (@$new_bibs) {

            my $bib = shift @$new_bibs;
            (my $id = $bib->{id}) =~ s#^/resources/##;
            $b->ischanged(1);
            $b->cache_time('edit_time');
            $b->marc($bib->{content});
            $b->remote_id($id); # just in case

            $e->xact_begin;
            $e->update_biblio_record_entry($b) or return $e->die_event;
            return $e->xact_commit;
        }

        return undef;
    }

    return 0;
}

