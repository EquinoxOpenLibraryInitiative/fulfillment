#!/usr/bin/perl
require '../oils_header.pl';
use vars qw/ $user $authtoken /;    # FIXME: $user not used?
use strict; use warnings;
use Time::HiRes qw/time/;
use Data::Dumper;
use OpenSRF::Utils::JSON;

#-----------------------------------------------------------------------------
# Creates, retrieves and deletes notes
#-----------------------------------------------------------------------------

err("usage: $0 <config> <username> <password> <patronid> <title> <text>") unless $ARGV[5];

my $config   = shift;  # - bootstrap config
my $username = shift;  # - oils login username
my $password = shift;  # - oils login password
my $patronid = shift;
my $title    = shift;
my $text     = shift;


sub go {
	osrf_connect($config);
	oils_login($username, $password);
	create_note();
	retrieve_notes();
	delete_notes();
	oils_logout();
}
go();



#-----------------------------------------------------------------------------
# 
#-----------------------------------------------------------------------------
my @created_ids;
sub create_note {

	for(0..9) {
		my $note = Fieldmapper::actor::usr_note->new;
	
		$note->usr($patronid);
		$note->title($title);
		$note->value($text);
		$note->pub(0);
	
		my $id = simplereq(
			'open-ils.actor', 
			'open-ils.actor.note.create', $authtoken, $note );
	
		oils_event_die($id);
		printl("created new note $id");
		push(@created_ids, $id);
	}

	return 1;
}

sub retrieve_notes {

	my $notes = simplereq(
		'open-ils.actor',
		'open-ils.actor.note.retrieve.all', $authtoken, 
		{ patronid => $patronid} );

	oils_event_die($notes);

	for my $n (@$notes) {
		printl("received note:");
		printl("\t". $n->creator);
		printl("\t". $n->usr);
		printl("\t". $n->title);
		printl("\t". $n->value);
	}
}

sub delete_notes {
	for(@created_ids) {
		my $stat = simplereq(
			'open-ils.actor', 
			'open-ils.actor.note.delete', $authtoken, $_);
		oils_event_die($stat);
		printl("deleted note $_");
	}
}

