#
#===============================================================================
#
#         FILE: SIP2client.pm
#
#  DESCRIPTION: 
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Michael Davadrian Smith (), msmith@esilibrary.com
#      COMPANY: Equinox Software
#      VERSION: 1.0
#      CREATED: 05/14/2012 03:27:10 PM
#     REVISION: ---
#===============================================================================

package FulfILLment::Util::SIP2Client;

use strict;
use warnings;
use Data::Dumper;
use IO::Socket::INET;
use Encode;
use Sip qw(:all);
use Sip::Checksum qw(checksum); 
use Sip::Constants qw(:all); 
use Sip::MsgType;
use OpenSRF::Utils::Logger qw/:logger/;

$Sip::protocol_version = 2;
$Sip::error_detection = 1;
$/ = "\r";

sub new { 
    my ($type) = $_[0]; 
    my $self = {}; 
    $self->{host} = $_[1]; 
    $self->{login_username} = $_[2]; 
    $self->{login_passwd} = $_[3]; 
    $self->{port} = $_[4];
    $self->{protocol} = $_[5];
    $self->{location} = $_[6];
    bless($self,$type);
}

sub socket{
    my $self = shift;

    if ($self->{socket}) {
        # logout may cause disconnect
        return $self->{socket} if $self->{socket}->connected;

        # probably excessive, but can't hurt to clean up
        $self->{socket}->shutdown(2);
        $self->{socket}->close;
    }

    $logger->debug("FF creating SIP socket to ".$self->{host});

    $self->{socket} = IO::Socket::INET->new(
        PeerAddr => $self->{host},
        Proto => $self->{protocol},
        PeerPort => $self->{port}
    ) or die "Cannot connect to host $self->{host} $@";

    return $self->{socket};
}

sub sendMsg{
  my $self = $_[0];
  my $msg = $_[1];
  my $seqno = $_[2] || 1;
  my $resp;
  my %fields;
  my $sock = $self->socket;
  $sock->autoflush(1); 
  $logger->info("FF SIP request => $msg");
  write_msg({seqno => $seqno},$msg,$sock);
  $resp = <$sock>;
  # SIP Msg hates leading spaces especially
  $resp =~ s/^\s+|\s+$//mg;
  $logger->info("FF SIP response => $resp");
  return $resp;
}

sub login{
    my $self = $_[0];
    return $self->{login_resp} if ($self->{logged_in});
    my $userid = $self->{login_username};
    my $userpasswd = $self->{login_passwd};
    my $locationCode = $self->{location};

    # some SIP servers do not require login
    return $self->{logged_in} = 1 unless $userid and $userpasswd;

    my $msg = "93  CN$userid|CO$userpasswd|"; 
    $self->{login_resp} = $self->sendMsg($msg);
    my $u = Sip::MsgType->new($self->{login_resp},0);
    my ($ok) = @{$u->{fixed_fields}};
    $self->{logged_in} = ($ok eq 'Y');
    return $ok;

}

sub logout{
    my $self = $_[0];
    $self->{login_resp} = $self->{logged_in} = undef;
    if ($self->{socket}) {
        $self->{socket}->shutdown(2);
        $self->{socket}->close;
        $self->{socket} = undef;
    }
}

# args:
# patron_id
# patron_pass - optional
# start_index - optional
# end_index   - optional
sub lookup_user {
    my $self = shift;
    my $args = shift;

    $args->{enable_summary_pos} = 0 # backwards compat
        unless $args->{enable_summary_pos};

    my $msg = '63001'; # message 63, language english (001)
    $msg .= Sip::timestamp();

    # summary field is 10 slots, all spaces, one Y allowed.
    $msg .= $args->{enable_summary_pos} == $_ ? 'Y' : ' ' for (0..9);

    $msg .= add_field(FID_INST_ID, $self->{location});
    $msg .= add_field(FID_PATRON_ID, $args->{patron_id});

    # optional fields
    $msg .= maybe_add(FID_TERMINAL_PWD, $self->{login_passwd});
    $msg .= maybe_add(FID_PATRON_PWD, $args->{patron_pass});
    $msg .= maybe_add(FID_START_ITEM, $args->{start_index});
    $msg .= maybe_add(FID_END_ITEM, $args->{end_index});

    $self->login;

    my $resp = $self->sendMsg($msg, 5);
    my $u = Sip::MsgType->new($resp, 0, 1);
    my $out = $self->lookup_user_handler($u);

    $self->logout;
    return $out;
}


# deprecated, start using lookup_user() instead
sub lookupUser{
    my $self = $_[0];
    my $terminalPwd = $self->{login_passwd};
    my $location = $self->{location};   #institution id
    my $patronId = $_[1];
    my $patronPasswd = $_[2];
    my $start_item = $_[3] || 1;
    my $end_item = $_[4] || 10;
    my $msg = '63001';  #sets message id to 63 and the language to english, 001
    $msg .= Sip::timestamp()."Y";
    $msg .= ' ' x 9;  #Adds an empty 10 spaces for the summary field
    $msg .= add_field(FID_INST_ID,$location);
    $msg .= add_field(FID_PATRON_ID,$patronId);
    $msg .= maybe_add(FID_TERMINAL_PWD,$terminalPwd);
    $msg .= maybe_add(FID_PATRON_PWD,$patronPasswd);
    $msg .= maybe_add(FID_START_ITEM,$start_item);
    $msg .= maybe_add(FID_END_ITEM,$end_item);  
    $self->login;
    my $resp = $self->sendMsg($msg,5);
    #$self->logout;
    my $u = Sip::MsgType->new($resp,0);
    my $out = $self->lookup_user_handler($u);
    $self->logout;
    return $out;
}

sub lookup_user_handler{
    my $self = shift;
    my $data = shift;

    if (!$data) {
        $logger->error("FF SIP lookup_user returned no response");
        return;
    }

    my $fields = $data->{fields};
    my $fixed_fields = $data->{fixed_fields};
    my @wholename = split(',',$fields->{AE});
    my $surname = $wholename[0];
    my $given_name = $wholename[1];
    my $valid_patron = $fields->{BL};
    my $error = 0;
    my $error_message = "";
    $fields->{AF} ||= '';

    if($valid_patron eq "N" || $fields->{AF} eq "User not found"){
        $error = 1;
        $error_message =  "User is not valid";   
    }
     
    my $out = {
                #user_id => $fields->{AA},
                patron_status => $fixed_fields->[0],
                langauge => $fixed_fields->[1],
                transaction_date => $fixed_fields->[2],
                hold_items_count => $fixed_fields->[3],
                overdue_items_count => $data->{fixed_fields}->[4],
                charged_items_count => $data->{fixed_fields}->[5],
                fine_items_count => $data->{fixed_fields}->[6],
                recall_items_count => $data->{fixed_fields}->[7],
                unavailable_holds_count => $data->{fixed_fields}->[8],
                institution_id => $fields->{AO},
                patron_identifier => $fields->{AA},
                personal_name => $fields->{AE},
                holds_items_limit => $fields->{BZ},
                overdue_items_limit => $fields->{CA},
                charged_items_limit => $fields->{CB},
                valid_patron => $fields->{BL},
                valid_patron_password => $fields->{CQ},
                currency_type => $fields->{BH},
                fee_amount => $fields->{BV},
                fee_limit => $fields->{CC},
                hold_items => $fields->{AS},
                overdue_items => $fields->{AT},
                charged_items => $fields->{AU},
                fine_items => $fields->{AV},
                recall_items => $fields->{BU},
                unavailable_hold_items => $fields->{CD},
                home_address => $fields->{BD},
                email_address => $fields->{BE},
                home_phone_number => $fields->{BF},
                screen_message => $fields->{AF},
                print_line => $fields->{AG},
    };

    return $out;
}

sub checkout{
    my $self = $_[0];
    my $terminalPwd = $self->{login_passwd};
    my $location = $self->{location};   #institution id
    my $patron_id = $_[1];
    my $patron_passwd =$_[2];
    my $item_id = $_[3];
    my $fee_ack = $_[4]; # Y or N
    my $cancel = $_[5]; # Y or N
    my $due_date_epoch = $_[6];
    my $msg = '11NN';  #sets message id to 11, no blocking, no autorenew
    $msg .= Sip::timestamp();
    $msg .= Sip::timestamp($due_date_epoch);
    $msg .= maybe_add(FID_INST_ID,$location);
    $msg .= add_field(FID_PATRON_ID,$patron_id);
    $msg .= add_field(FID_ITEM_ID,$item_id);
    $msg .= maybe_add(FID_TERMINAL_PWD,$terminalPwd);
    $msg .= maybe_add(FID_PATRON_PWD,$patron_passwd);
    $msg .= maybe_add(FID_FEE_ACK,$fee_ack);
    $msg .= maybe_add(FID_CANCEL,$cancel);
    $self->login;
    my $resp = $self->sendMsg($msg,5);
    my $co = Sip::MsgType->new($resp,0);
    $self->logout;
    return $co;

}

sub checkin{
    my $self = $_[0];
    my $terminalPwd = $self->{login_passwd};
    my $location = $self->{location};   #institution id
    my $patron_id = $_[1];
    my $patron_passwd =$_[2];
    my $item_id = $_[3];
    my $item_properties = $_[4];
    my $cancel = $_[5] || "N";  #value should be Y or N
    my $fee_ack = $_[6] || "N";  #value should be Y or N
    my $msg = '09N';  #sets message id to 09, no blocking
    $msg .= Sip::timestamp();
    $msg .= Sip::timestamp();
    $msg .= add_field(FID_CURRENT_LOCN,$location);
    $msg .= add_field(FID_INST_ID,$location);
    $msg .= add_field(FID_PATRON_ID,$patron_id);
    $msg .= add_field(FID_ITEM_ID,$item_id);
    $msg .= add_field(FID_TERMINAL_PWD,$terminalPwd);
    $msg .= add_field(FID_ITEM_PROPS,$item_properties);
    $msg .= add_field(FID_CANCEL,$cancel);
    $msg .= add_field(FID_FEE_ACK,$fee_ack);
    $self->login;
    my $resp = $self->sendMsg($msg,5);
    my $ci = Sip::MsgType->new($resp,0);
    $self->logout;
    return $ci;

}

# translates a SIP checkout or checkin response to a human-friendlier hash
sub sip_msg_to_circ {
    my ($self, $msg, $type) = @_;
    $type |= '';

    my $fields = $msg->{fields};
    my $fixed_fields = $msg->{fixed_fields};

    $logger->debug("FF mapping SIP to circ for " . Dumper($msg));

    my $circ = {
        error => !$fixed_fields->[0],
        magnetic_media => $fixed_fields->[2], # Y N U
        transaction_date => $fixed_fields->[4],
        institution_id => $fields->{AO},
        patron_id => $fields->{AA},
        item_id => $fields->{AB},
        due_date => $fields->{AH},
        fee_type => $fields->{BT},
        security_inhibit => $fields->{BI},
        currency_type => $fields->{BH},
        fee_amount => $fields->{BV},
        media_type => $fields->{BV},
        item_properties => $fields->{CH},
        transaction_id => $fields->{BK},
        screen_message => $fields->{AF},
        print_line => $fields->{AG},
        permanent_location => $fields->{AQ}
        #title => 
        #call_number =>
        #price => 
    };

    if ($type eq 'checkout') {
        $circ->{renewal_ok} = $fixed_fields->[1];
        $circ->{desensitize} = $fixed_fields->[3];
    } else {
        $circ->{resensitize} = $fixed_fields->[1];
        $circ->{alert} = $fixed_fields->[3];
    }

    return $circ;
}



sub item_information_request{
    my ($self,$item_id) = @_;    
    $Sip::protocol_version = 2;
    my $msg = "17".Sip::timestamp();
    $msg .= add_field(FID_INST_ID,$self->{location});
    $msg .= add_field(FID_ITEM_ID,$item_id);
    $msg .= add_field(FID_TERMINAL_PWD,$self->{login_passwd});
    $self->login;
    my $resp = $self->sendMsg($msg,6);
    my $u = Sip::MsgType->new($resp,0);
    $self->logout;
    return unless $u;
    my $out = $self->item_information_request_handler($u);
    return $out;
}

sub item_information_request_handler{
    my $self  = $_[0];
    my $response = $_[1];
    my $fixed_fields = $response->{fixed_fields};
    my $fields = $response->{fields};
    
    my $out = {
                circulation_status => $fixed_fields->[0],
                security_marker =>  $fixed_fields->[1],
                fee_type => $fixed_fields->[2],
                transaction_date => $fixed_fields->[3],
                hold_queue_length => $fields->{CF},
                due_date => $fields->{AH},
                recall_date => $fields->{CJ},
                hold_pickup_date => $fields->{CM},
                item_identifier => $fields->{AB},
                title_identifier => $fields->{AJ},
                owner => $fields->{BG},
                currency_type => $fields->{BH},
                fee_amount => $fields->{BV},
                media_type => $fields->{CK},
                permanent_location => $fields->{AQ},
                current_location => $fields->{AP},
                item_properties => $fields->{CH},
                screen_message => $fields->{AF},
                print_line => $fields->{AG},
    }; 
    
    return $out; 
}


sub build_hold_msg{
    my ($self,$patron_id, $patron_pwd ,$holdMode,
        $expiration_date, $pickup_location, $hold_type,
        $item_id, $title_id, $fee_acknowledged 
        ) = @_;
    
    my $location = $self->{location};
    my $msg = "15";
    my $terminal_pwd = $self->{login_passwd} ; 

    if($holdMode eq "add"){
        $holdMode = "+";
    }elsif($holdMode eq "delete"){
        $holdMode = "-";
    }elsif($holdMode eq "change"){
        $holdMode = "*";
    }

    $msg .= $holdMode . Sip::timestamp();
    $msg .= maybe_add(FID_EXPIRATION,$expiration_date);
    $msg .= maybe_add(FID_PICKUP_LOCN,$pickup_location);
    $msg .= maybe_add(FID_HOLD_TYPE,$hold_type);
    $msg .= maybe_add(FID_INST_ID,$location);
    $msg .= add_field(FID_PATRON_ID,$patron_id);
    $msg .= maybe_add(FID_PATRON_PWD,$patron_pwd); 
    $msg .= maybe_add(FID_ITEM_ID,$item_id); 
    $msg .= maybe_add(FID_TITLE_ID,$title_id);
    $msg .= maybe_add(FID_TERMINAL_PWD,$terminal_pwd); 
    #$msg .= maybe_add(FID_FEE_ACK,$fee_acknowledged);  #This field did not work when tested with the Sirsi-dynex implementation 
    
    return $msg;
    
}

sub place_hold{
    
    my ($self,$patron_id, $patron_pwd ,$expiration_date, $pickup_location, $hold_type,
        $item_id, $title_id, $fee_acknowledged 
        ) = @_;

    my $hold_mode = "add";
    my $msg = $self->build_hold_msg($patron_id, $patron_pwd,$hold_mode,
        $expiration_date ,$pickup_location,$hold_type,$item_id,$title_id,$fee_acknowledged);
    $self->login;
    my $resp = $self->sendMsg($msg,5);
    my $u = Sip::MsgType->new($resp,0);
    $self->logout;
    return $u;
}

sub delete_hold{
    my ($self,$patron_id, $patron_pwd ,$expiration_date, $pickup_location, $hold_type,
        $item_id, $title_id, $fee_acknowledged 
        ) = @_;

    my $hold_mode = "delete";
    my $msg = $self->build_hold_msg($patron_id, $patron_pwd,$hold_mode,
        $expiration_date ,$pickup_location,$hold_type,$item_id,$title_id,$fee_acknowledged);
    $self->login;
    my $resp = $self->sendMsg($msg,5);
    my $u = Sip::MsgType->new($resp,0);
    return $u;
    $self->logout;
}

1;
