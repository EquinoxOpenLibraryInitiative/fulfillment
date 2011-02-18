package OpenILS::WWW::EGCatLoader;
use strict; use warnings;
use Apache2::Const -compile => qw(OK DECLINED FORBIDDEN HTTP_INTERNAL_SERVER_ERROR REDIRECT HTTP_BAD_REQUEST);
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Application::AppUtils;
my $U = 'OpenILS::Application::AppUtils';

use constant COOKIE_ANON_CACHE => 'anoncache';
use constant ANON_CACHE_MYLIST => 'mylist';

# Retrieve the users cached records AKA 'My List'
# Returns an empty list if there are no cached records
sub fetch_mylist {
    my $self = shift;

    my $list = [];
    my $cache_key = $self->cgi->cookie(COOKIE_ANON_CACHE);

    if($cache_key) {

        $list = $U->simplereq(
            'open-ils.actor',
            'open-ils.actor.anon_cache.get_value', 
            $cache_key, ANON_CACHE_MYLIST);

        if(!$list) {
            $cache_key = undef;
            $list = [];
        }
    }

    $self->apache->log->info("Found anon-cache list [@$list]");

    return ($cache_key, $list);
}


# Adds a record (by id) to My List, creating a new anon cache + list if necessary.
sub load_mylist_add {
    my $self = shift;
    my $rec_id = $self->cgi->param('record');

    my ($cache_key, $list) = $self->fetch_mylist;
    push(@$list, $rec_id);

    $cache_key = $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.anon_cache.set_value', 
        $cache_key, ANON_CACHE_MYLIST, $list);

    return $self->mylist_action_redirect($cache_key);
}

# Removes a record ID from My List
sub load_mylist_del {
    my $self = shift;
    my $rec_id = $self->cgi->param('record');

    my ($cache_key, $list) = $self->fetch_mylist;
    return $self->mylist_action_redirect unless $cache_key;

    $list = [ grep { $_ ne $rec_id } @$list ];

    $cache_key = $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.anon_cache.set_value', 
        $cache_key, ANON_CACHE_MYLIST, $list);

    return $self->mylist_action_redirect($cache_key);
}

sub load_cache_clear {
    my $self = shift;
    $self->clear_anon_cache;
    return $self->mylist_action_redirect;
}

# Wipes the entire anonymous cache, including My List
sub clear_anon_cache {
    my $self = shift;
    my $field = shift;

    my $cache_key = $self->cgi->cookie(COOKIE_ANON_CACHE) or return;

    $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.anon_cache.delete_session', $cache_key)
        if $cache_key;

}

# Called after an anon-cache / My List action occurs.  Redirect
# to the redirect_url (cgi param) or referrer or home.
sub mylist_action_redirect {
    my $self = shift;
    my $cache_key = shift;

    $self->apache->print(
        $self->cgi->redirect(
            -url => $self->cgi->param('redirect_to') || $self->ctx->{referer} || $self->ctx->{home_page},
            -cookie => $self->cgi->cookie(
                -name => COOKIE_ANON_CACHE,
                -path => '/',
                -value => ($cache_key) ? $cache_key : '',
                -expires => ($cache_key) ? undef : '-1h'
            )
        )
    );

    return Apache2::Const::REDIRECT;
}

1;
