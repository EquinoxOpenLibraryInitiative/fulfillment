package FulfILLment::LAIConnector::III;
use base FulfILLment::LAIConnector;
use strict; use warnings;
use Net::Telnet;
use Net::OpenSSH;
use OpenSRF::Utils::Logger qw/$logger/;

# connect to SSH / Millenium terminal app
sub ssh_connect {
    my $self = shift;

    my $host = $self->{'ssh.host'} || $self->{'host.item'} || $self->{host};
    my $user = $self->{'ssh.user'} || $self->{'user.item'} || $self->{user};
    my $pass = $self->{'ssh.passwd'} || $self->{'passwd.item'} || $self->{passwd};

    # creating a pty spawns a child process make sure 
    # we're not picking up any existing sigchld handlers
    $SIG{CHLD} = 'DEFAULT';

    $logger->info("FF III SSH connecting to $user\@$host");

    my $ssh = Net::OpenSSH->new(
        $host, user => $user, password => $pass);

    if ($ssh->error) {
        $logger->error("FF III SSH connect error " . $ssh->error);
        return;
    }

    my ($fh, $pid) = $ssh->open2pty();
    my $term = Net::Telnet->new(Fhopen => $fh);

    # keep these around for later cleanup and to ensure $ssh stays in scope
    $self->{ssh_parent} = $ssh;
    $self->{ssh_pty} = $fh;
    $self->{ssh_pid} = $pid;
    $self->{ssh_term} = $term;

    return 1 if $term->waitfor(-match => '/SEARCH/', -errmode => "return");

    $logger->error("FF III never received SSH menu prompt");
    $self->ssh_disconnect;
    return;
}

sub ssh_disconnect {
    my $self = shift;
    return unless $self->{ssh_parent};

    $logger->debug("FF III SSH disconnecting");

    $self->{ssh_pty}->close if $self->{ssh_pty};
    $self->{ssh_term}->close if $self->{ssh_term};
    $self->{ssh_term} = undef;
    $self->{ssh_parent} = undef;

    # required to avoid <defunct> SSH processes
    if (my $pid = $self->{ssh_pid}) { # assignment
        $logger->debug("FF III SSH waiting on child $pid");
        waitpid($pid, 0);
    }
}

# send command to SSH term and wait for a response
sub send_wait {
    my ($self, $send, $wait, $timeout) = @_;

    if ($send) {
        $logger->debug("FF III sending SSH command '$send'");
        $self->{ssh_term}->print($send);
    }

    my @response;

    if ($wait) {
        $logger->debug("FF III SSH waiting for '$wait'...");

        @response = $self->{ssh_term}->waitfor(
            -match => "/$wait/", 
            -errmode => 'return',
            -timeout => $timeout || 10
        );

        if (@response) {
            my $txt = join('', @response);
            $txt =~ s/[[:cntrl:]]//mg;
            $logger->debug("FF III SSH wait received text: $txt");
            warn "==\n$send ==> \n$txt\n";

        } else {
            $logger->warn(
                "FF III SSH timed out waiting for '$wait' :".
                $self->{ssh_term}->errmsg);
        }
    }

    return @response;
}


sub get_user {
    my ($self, $user_barcode, $user_pass) = @_;

    return $self->SUPER::get_user($user_barcode, $user_pass)
        if $self->sip_client;

    # no SIP, use SSH instead..
    $self->ssh_connect or return;

    my $user;
    eval { $user = $self->get_user_guts($user_barcode, $user_pass) };
    $logger->error("FF III error getting user $user_barcode : $@");

    $self->ssh_disconnect;
    return $user;
} 

sub get_items_by_record {
    my ($self, $record_id) = @_;
    $self->ssh_connect or return;

    my @items;
    eval { @items = $self->get_items_by_record_guts($record_id) };
    $logger->error("FF III get_items_by_record() died : $@") if $@;

    $self->ssh_disconnect;
    return @items ? \@items : [];
}

sub get_record_by_id {
    my ($self, $rec_id) = @_;

    if ($self->z39_client) {
        $logger->info("FF III fetching record from Z39: $rec_id");
        chop($rec_id); # z39 does not want the final checksum char.
        return { marc => $self->z39_client->get_record_by_id($rec_id) };
    } else {
        $logger->info("FF III fetching record from SSH: $rec_id");
        return $self->get_record_by_id_ssh($rec_id);
    }
}

sub place_lender_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;

    my $hold = $self->place_hold_via_sip(
        undef, $item_barcode, $user_barcode, $pickup_lib, 2)
        or return;

    $hold->{hold_type} = 'T';
    return $hold;
}

sub delete_lender_hold {
    my ($self, $item_barcode, $user_barcode) = @_;

    my $user = $self->flesh_user($user_barcode);
    my $pickup_lib = $user->home_ou->shortname if $user;

    my $resp = $self->sip_client->delete_hold(
        $user_barcode, undef, undef, 
        $pickup_lib, 2, $item_barcode)
        or return;

    return unless $resp;
    return $self->translate_sip_hold($resp);
}



1;
