package OpenILS::Application::Storage;
use OpenSRF::Application;
use base qw/OpenSRF::Application/;

use OpenSRF::EX qw/:try/;
use OpenSRF::Utils::Logger qw/:level/;

# Pull this in so we can adjust it's @ISA
use OpenILS::Application::Storage::CDBI;

use OpenILS::Application::Storage::FTS;

# Suck in the method publishing modules
use OpenILS::Application::Storage::Publisher;

# the easy way to get to the logger...
my $log = "OpenSRF::Utils::Logger";

sub DESTROY {};

sub initialize {

	my $conf = OpenSRF::Utils::SettingsClient->new;

	$log->debug('Initializing ' . __PACKAGE__ . '...', DEBUG);

	my $driver = "OpenILS::Application::Storage::Driver::".
		$conf->config_value( apps => 'open-ils.storage' => app_settings => databases => 'driver');


	$log->debug("Attempting to load $driver ...", DEBUG);

	eval "use $driver;";
	throw OpenILS::EX::PANIC ( "Can't load $driver!  :  $@" ) if ($@);

	$log->debug("$driver loaded successfully", DEBUG);

	@OpenILS::Application::Storage::CDBI::ISA = ( $driver );
}

sub child_init {

	my $conf = OpenSRF::Utils::SettingsClient->new;

	OpenSRF::Application->method_lookup('crappola');

	$log->debug('Running child_init for ' . __PACKAGE__ . '...', DEBUG);

	OpenILS::Application::Storage::CDBI->child_init(
		$conf->config_value( apps => 'open-ils.storage' => app_settings => databases => 'database')
	);

	if (OpenILS::Application::Storage::CDBI->db_Main()) {
		$log->debug("Success initializing driver!", DEBUG);
		return 1;
	}
	return 0;
}

sub begin_xaction {
	my $self = shift;
	my $client = shift;

	$log->debug(" XACT --> 'BEGIN'ing transaction for session ".$client->session->session_id,DEBUG);
	return OpenILS::Application::Storage::CDBI->db_Main->begin_work;
}
__PACKAGE__->register_method(
	method		=> 'begin_xaction',
	api_name	=> 'open-ils.storage.transaction.begin',
	api_level	=> 1,
	argc		=> 0,
);

sub commit_xaction {
	my $self = shift;
	my $client = shift;

	$log->debug(" XACT --> 'COMMIT'ing transaction for session ".$client->session->session_id,DEBUG);
	return OpenILS::Application::Storage::CDBI->db_Main->commit;
}
__PACKAGE__->register_method(
	method		=> 'commit_xaction',
	api_name	=> 'open-ils.storage.transaction.commit',
	api_level	=> 1,
	argc		=> 0,
);


sub rollback_xaction {
	my $self = shift;
	my $client = shift;

	$log->debug(" XACT --> 'ROLLBACK'ing transaction for session ".$client->session->session_id,DEBUG);
	return OpenILS::Application::Storage::CDBI->db_Main->rollback;
}
__PACKAGE__->register_method(
	method		=> 'rollback_xaction',
	api_name	=> 'open-ils.storage.transaction.rollback',
	api_level	=> 1,
	argc		=> 0,
);


sub _cdbi2Hash {
	my $self = shift;
	my $obj = shift;
	return { map { ( $_ => $obj->$_ ) } ($obj->columns('All')) };
}

sub _cdbi_list2AoH {
	my $self = shift;
	my @objs = @_;
	return [ map { $self->_cdbi2Hash($_) } @objs ];
}

1;
