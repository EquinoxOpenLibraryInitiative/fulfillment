package FulfILLment::LAIConnector::III::2011_1_3;
use base FulfILLment::LAIConnector::III;
use strict; use warnings;
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Application::AppUtils;
my $U = 'OpenILS::Application::AppUtils';

use MARC::Record;
use MARC::Batch;
use MARC::File::XML (BinaryEncoding => 'utf8');
use LWP::UserAgent;
use HTTP::Request;
use WWW::Mechanize;
use XML::Simple;
use Data::Dumper;

my $ua = LWP::UserAgent->new;
$ua->agent("FulfILLment/1.0");

# title-level hold on bib ID only supported
sub place_lender_hold {
    my ($self, $item_barcode, $user_barcode, $pickup_lib) = @_;

    my $acp = new_editor()->search_asset_copy([ 
        {   barcode => $item_barcode, 
            deleted => 'f',
            source_lib => $U->get_org_ancestors($self->org_id)
        }, {
            flesh => 2, 
            flesh_fields => {
                acp => ['call_number'],
                acn => ['record']
            }
        }
    ])->[0];

    my $remote_id = $acp->call_number->record->remote_id;

    # TODO: verify this is needed
    $remote_id =~ s/^\.//; # kill the preceding '.'
    #$remote_id =~ s/^b//;  # kill the preceding 'b'

    # checkdigit
    #$remote_id =~ s/(.)$//;


    my $hold = $self->place_hold_via_sip(
        $acp->call_number->record->id, undef, 
        $user_barcode, $pickup_lib, undef, 2, $remote_id)
        or return;

    $hold->{hold_type} = 'T';
    return $hold;
}

sub get_record_by_id_ssh {
    my ($self, $record_id) = @_;

    $self->ssh_connect or return;
    $self->send_wait('S', 'Choose one') or return;
    $self->send_wait('B', 'Choose one') or return;
    $self->send_wait('R', 'Type Record') or return;
    $self->send_wait("$record_id", 'Choose one') or return;
    $self->send_wait('T', 'BIBLIOGRAPHIC Information') or return;
    $self->send_wait('M');
    my ($pre, $post) = $self->send_wait('T', 'Regular Display') or return;
    $self->ssh_disconnect or return;

    my @lines = split(/\[\d+;\d+(;\d+)?[Hm]/, $pre);
    
    my @marc;
    foreach (@lines){   
        next unless $_;
        s/^(\s+)//g;
        next unless /^\d{3}/;
        s/\x1b//g;
        s/\[0m//g;
        s/\[0xF\]//g;
        s/[[:cntrl:]]//g;
        push @marc,$_;
    }

    my $rec =  breaker2marc(\@marc);
    $rec->insert_fields_ordered(
        MARC::Field->new('907', ' ', ' ', a => $record_id)
    ) unless $rec->subfield('907' => 'a');

    my $x =  $rec->as_xml_record;
    $x =~ s/^<\?.+?\?>.//sm;
    return {marc => $x};
}

sub get_items_by_record_guts {
    my ($self, $record_id) = @_;
    my @items;

    $self->send_wait('S', 'prominently') or return;
    $self->send_wait('B', 'SEARCHING RECORDS') or return;
    $self->send_wait('R', 'RECORD') or return;
    $self->send_wait($record_id, 'Choose one') or return;

    my ($prematch, $match) = $self->send_wait(
        'S', 'To see a particular|BARCODE\s*[^\s]+') or return;

    if ($match =~ /BARCODE/) {
        # single-copy bib jumps right to copy details.


        # we need the Copy Type from the match as well, 
        # so push it back into the main text
        $prematch .= $match;
        my $item = $self->parse_item_screen($prematch);

        unless ($item and $item->{barcode}) {
            $logger->warn(
                "FF III unable to parse single-item screen for $record_id");
            return;
        }

        push(@items, $item);

    } else {
        # multi-copy bib

        my @item_indexes = ($prematch =~ /ITEM\s+(\d+)\s>/g);

        for my $index (@item_indexes) {
            my @response = $self->send_wait($index, 'Record SUMMARY') or last;
            my $screen = $response[0];

            $logger->debug("FF III item screen contains ".
                length($screen)." characters");

            my $item;
            $logger->debug("FF III parsing item screen for entry $index");
            $item = $self->parse_item_screen($screen);

            unless ($item and $item->{barcode}) {
                $logger->warn(
                    "FF III unable to parse item screen for $record_id");
                last;
            }

            push(@items, $item);

            # return to the summary screen
            $self->send_wait('S', 'To see a particular') or last;
        }
    }

    return @items;
}

sub get_user_guts {
    my ($self, $user_barcode, $user_pass) = @_;

    $self->send_wait('S', 'prominently') or return;
    $self->send_wait('P', 'RECORDS') or return;
    $self->send_wait('D', 'BARCODE') or return; # 2009 uses 'B'

    my ($txt, $match) = $self->send_wait(
        $user_barcode, 
        'Record|BARCODE not found'
    ) or return;

    if ($match =~ /BARCODE not found/) {
        $logger->info("FF III user '$user_barcode' not found");
        return;
    }

    $txt =~ s/\[\d+;\d+(;\d+)?[Hm]//g;
    $txt =~ s/^\d\d\d\s+.+//g;
    $txt =~ s/\x1b//g;
    $txt =~ s/\[0m//g;
    $txt =~ s/\[0xF\]//g;
    $txt =~ s/[[:cntrl:]]//g;

    my $user = {
        exp_date => qr/EXP DATE:\s(\d+\-\d+\-\d+)/,
        user_id => qr/PIN\s+([A-Za-z0-9]+)INPUT/,
        notice_pref => qr/NOTICE PREF:\s(.*)TOT/,
        lang_pref => qr/LANG PREF:\s+(\w+)/,
        mblock => qr/MBLOCK:\s+([A-Za-z0-9\-])\s+/,
        patron_agency => qr/PAT AGENCY:\s+(\d+)\s+/,
        overdue_items_count => qr/HLODUES:\s+(\d+)/,
        notes => qr/PMESSAGE:\s+([A-Za-z0-9\-])/,
        home_ou => qr/HOME LIBR:\s+(\w+)/,
        total_renewals  => qr/TOT RENWAL:\s+(\d+)/,
        email_address => qr/EMAIL ADDR\s+([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,3})/,
        claims_returned_count => qr/CL RTRND:\s(\d+)/,
        loaned_items_count => qr/CUR CHKOUT:\s(\d+)/,
        money_owed => qr/MONEY OWED:\s(\$\d+\.\d+)/,
        overdue_penalty => qr/OD PENALTY:\s(\d+)/,
        institution_code => qr/HOME LIBR:\s+(\w+)/,
        block_until => qr/BLK UNTIL:\s(\d+\-\d+\-\d+)/,
        full_name => qr/PATRN NAME\s+(.*)ADDRESS/,
        street_address => qr/ADDRESS\s+(.*)SSN/,
        ssn => qr/SSN #\s+(\d+)P BARCODE/,
        photocopy_count => qr/PIUSE:\s+(\d+)/,
        patron_code1 => qr/PCODE1:\s+(\d+)/,
        patron_code2 => qr/PCODE2:\s+(\d+)/,
        patron_code3 => qr/PCODE3:\s+(\d+)/,
        patron_code4 => qr/PCODE4:\s+(\d+)/,
        notes => qr/PMESSAGE:\s+([A-Za-z0-9\-])/,
        ill_request => qr/ILL REQUES:\s+(\d+)/,
        last_circ_date => qr/CIRCACTIV:\s(\d+\-\d+\-\d+)/,
        patron_type => qr/P TYPE:\s(\d+)/,
        census => qr/CENSUS:\s(\d+)\s+/,
        total_checkouts => qr/TOT CHKOUT:\s(\d+)/,
        checkouts => qr/CUR CHKOUT:\s+(\d+)/,
        phone => qr/TELEPHONE\s+(\d\d\d\-\d\d\d\-\d\d\d\d)/,
        input_by => qr/INPUT BY\s+([A-Za-z\/]+)/,
        birth_date => qr/BIRTH DAT:(\d\d\-\d\d-\d\d)/,
        cur_item_A => qr/CUR ITEMA:\s(\d+)/,
        cur_item_B => qr/CUR ITEMB:\s(\d+)/,
        cur_item_C => qr/CUR ITEMC:\s(\d+)/,
        cur_item_D => qr/CUR ITEMD:\s(\d+)/,
        error => 0,
    };

    for my $key (keys %$user) {
        my ($val) = ($txt =~ $user->{$key});
        $user->{$key} = $val;
    }

    my %prefs = (
        z => 'email',
        t => 'phone',
        p => 'secondary phone'
    );

    $user->{notice_pref} = $prefs{$user->{notice_pref}};
    $user->{barcode} = $user_barcode;
    
    return $user;
}

# not needed if SIP is used.
sub get_item_via_ssh {
    my ($self, $item_barcode) = @_;

    $self->ssh_connect or return;

    $self->send_wait('S', 'prominently') or return;
    $self->send_wait('I', 'SEARCHING RECORDS') or return;
    $self->send_wait('D', 'BARCODE') or return; # NOTE: 2009 uses 'B'
    my ($screen) = $self->send_wait($item_barcode, 'NEW Search') or return;

    $self->ssh_disconnect;

    if ($screen =~ /not found|PATRON Information/g) {
        $logger->info("FF III unable to locate item $item_barcode");
        return;
    }

    my $item = $self->parse_item_screen($screen, $item_barcode);

    $logger->error("FF III error parsing item screen for $item_barcode")
        unless $item;

    return $item;
}


sub place_record_hold {
    my ($self, $record_id, $user_barcode) = @_;

    my $host = $self->{host};
    my $password = $self->{'passwd.hold'} || $self->{passwd};

    # $self->{port} usually == 80; need a separate SSL port config
    my $port = 443; 

    # XXX do we need an org setting for default lender hold pickup location?
    # TODO: web form pads the pickup lib values.  add padding via sprintf to match.
    my $pickup_lib = 'pla    ';

    chop($record_id); # strip check digit
    $record_id = substr($record_id, 1); # strip the initial '.'

    my $url = "https://$host/search~S1?/.$record_id/".
        ".$record_id/1%2C1%2C1%2CB/request~$record_id";

    $logger->info("FF III title hold URL: $url");

    my $mech = WWW::Mechanize->new();
    my $content;

    eval {
        $mech->post($url);
        $mech->form_name('patform');
        $mech->set_fields('pin', $password, 'code', $user_barcode);
        $mech->select('locx00', $pickup_lib);
        my $response = $mech->submit(); 
        $content = $mech->content if $response;
    };

    $logger->info($content); # XXX
  
    if ($@ or !$content){
        my $msg = $@ || 'no content';
        $logger->info("FF III error placing title hold on $record_id : $msg");
        return {error => 1, error_message => $@};
    }
    
    my @title = ($content =~ /<p>Requesting <strong>(.+)<\/strong><br \/><p>/);
    my @err_response_msg = ($content =~ /<font color="red" size="\+2">(.+)<\/font>/g);
    my @success_response_msg = ($content =~ /Your request for .* was successful./g);
    my @delivered_to = ($content =~ /Your request will be delivered to .* when it is available./);

    if($content =~ /No Such Record/){
        $logger->info("FF III no such record $record_id in title hold");
        return {
            error => 1, 
            error_message => # TODO: i18n?
                "A hold could not be placed on $record_id, no such record"
        }
    }
    
    if ($content =~ /Request denied/){
        $logger->info("FF III title hold for $record_id denied");
        $err_response_msg[0] =~ s/<strong>//;
        $err_response_msg[0] =~ s/<\/strong>//;

        return {
            error => 1,
            error_message => $err_response_msg[0],
            title => $title[0]
        };

    } elsif ($content =~ /Your request for .* was successful./g){
        $success_response_msg[0] =~ s/<strong>//;
        $success_response_msg[0] =~ s/<\/strong>//;

        return {
            error => 0,
            success_message => $success_response_msg[0],
            title => $title[0]
        };
    }

    @title = ($content =~ 
        /class="bibInfoLabel">Title<\/td>\n<td class="bibInfoData">\n<strong>(.*)<\/strong>/g);
    
    if ($title[0]){
        return {
            error => 0,
            success_message => "Your request for $title[0] was successful.",
            title => $title[0]
        };
    }
}


# ---------------------------------------------------------------------------
# Everything below here needs modification and testing
# ---------------------------------------------------------------------------


sub get_item_fields{
    my $self=$_[0];
    my $itemData=$_[1];
    return [] unless $itemData;
    $logger->debug("FF III get_item_fields parsing " .length($itemData)." characters");
    #print Dumper $itemData;
    $itemData =~ s/\e\[\d+(?>(;\d+)*)[mh]//gi;
    $itemData =~ s/\e\[k//gi;
    $itemData =~ s/[[:cntrl:]]//g;
    $itemData =~ s/VOLUME/VOLUME:/g;
    $itemData =~ s/CALL #/CALL #:/g;
    $itemData =~ s/R > Browse Nearby EntriesI > Show similar ITEMSN >//g;
    $itemData =~ s/R > RETURN to BrowsingZ > Show Items Nearby on ShelfF > FORWARD browseI > Show similar ITEMSN >//g;
    $itemData =~ s/U > Show BIBLIOGRAPHIC RecordZ > Show Items Nearby on Shelf//g;
    $itemData =~ s/\+ > ADDITIONAL options1-2,N,A,Z,I,U,T,E,\+\).*ITEM Information//g;
    $itemData =~ s/I > Show similar ITEMSA > ANOTHER Search by RECORD #//g;
    $itemData =~ s/U > Show similar BIBLIOGRAPHIC RecordS > Record SUMMARY//g;
    $itemData =~ s/U > Show BIBLIOGRAPHIC RecordS > Record SUMMARY//g;
    $itemData =~ s/T > Display MARC RecordE > Mark item for//g;
    $itemData =~ s/U > Show BIBLIOGRAPHIC Record//g;
    $itemData =~ s/NEW Search//g;
    $itemData =~ s/N,A,S,Z,I,U,T,E\)//g;
    $itemData =~ s/N >//g;
   
    if(my @l = ($itemData =~ m/(\d+)BARCODE/g)){
        $itemData =~ s/VOLUME:/VOLUME: $l[0]/g;
    }
    
    $itemData =~ s/(\d+)BARCODE/BARCODE:/g;
    #$itemData =~ s/1BARCODE/BARCODE/g;
    my @fields = grep {defined and not /^\s*$/} split /(\s{2,})|(-  -)/, $itemData;
    #my $i=0;
    my @newfields = [];
   
   foreach (@fields){
     #$_.=':' if $_ eq 'VOLUME';
     $_.=':' if $_ eq 'BARCODE';
     
     if((/^[ \-]+$/ or $newfields[$#newfields] eq 'BARCODE:') and @newfields){
         $newfields[$#newfields] .=$_;
     }else{
         unless(ref($_) eq 'ARRAY'){
            push @newfields, $_;
         }
     }
       
     #$i++;
    }
  
   return \@newfields;
}







sub get_item_call_and_bib_number {
    $logger->debug("In get_item_call_and_bib_number");
    my $self = $_[0];
    my $item_data = $_[1];
    $item_data =~ s/\e\[\d+(?>(;\d+)*)[mh]//gi;
    $item_data =~ s/\e\[k//gi;
    $item_data =~ s/[[:cntrl:]]//g;

    my @c = ($item_data =~ /BIBLIOGRAPHIC Information\s+CALL #\s+(.*?)AUTHOR/);
    
    if(not defined($c[0])){
        @c = ($item_data =~ /BIBLIOGRAPHIC Information\s+CALL #\s(.*?)TITLE/);
    }

    if (!$c[0]) {
        # in multi-copy records, the call number is embedded in the 
        # copy data and has no predictable terminating string.
        # capture it all and chop it off at the first occurence 
        # of 2 consecutive spaces

        @c = ($item_data =~ /CALL #\s+(.*)/);
        if ($c[0]) {
            $c[0] =~ s/(.*?)\s{2}.*/$1/mg;
            $c[0] =~ s/\s+$//;
        } else {
            $logger->warn("FF III unable to parse callnumber");
            $c[0] = 'UNKNOWN';
        }
    }

    #get Barcode
    my @b = ($item_data =~ /BARCODE:.*(B.*)\s+BIBLIOGRAPHIC Information/);
    
    if($b[0]){
        $b[0] =~ s/\s//g;
    }else{
        @b = ($item_data =~ /BARCODE\s+([^\s]+)/);
    }
 
    #get title
    my @f = split("TITLE",$item_data) ;
    my @fingerprint = ($f[0] =~ /\s+(.*)\s{5,}/);    
    my @out;
    
    if(not defined $fingerprint[0]){ 
        @fingerprint = ($item_data =~ /TITLE\s+(.*)\s{5,}/);
    }

    @out = ($b[0],$c[0],$fingerprint[0]);
    $logger->debug("Exiting get_item_call_and_bib_number");
    return \@out;
}



         

sub parse_item_screen{
    $logger->debug("In parse_item_screen");
    my $self = $_[0];
    my $screen = $_[1];
    my $jhash={};
    my @nvp;
    my $label;
    my $value;
    my @screen_split;
    my $rs = $screen;
    my @record_number = ($rs =~ /(I\d.*)\s+ITEM Information/g);
    my $e = "ESC[7;2H";
    $e = ord($e);
    $record_number[0] =~ s/\s+//g;
    push @screen_split, split(/ITEM Information/,$screen);
    #print Dumper @screen_split;
    my $fields = $self->get_item_fields($screen_split[1]); 


    my $call_and_bib = $self->get_item_call_and_bib_number($screen_split[1]);

    my $barcode = (defined($_[2])) ? $_[2] : $call_and_bib->[0];
    my @fingerprint = ($screen =~ /TITLE\s+([^.!?\s][^.!?]*)\s+/);
    $logger->debug("setting fields to their FulfILLment equivalents"); 
    
    foreach(@$fields){
        @nvp=split(":",$_);
        $label=$nvp[0];
        $value=$nvp[1];
        if($label eq "DUE DATE"){
            $label="due_date";
        }elsif($label eq "BARCODE"){
            $label="barcode";
        }elsif($label eq "STATUS"){
            $label="holdable";
        }elsif($label eq "LOCATION"){
            $label="location";
        }elsif($label eq "PRICE"){
            $label="price";
        }elsif($label eq "COPY #"){
            $label = "copy_number";
        }elsif($label eq "I TYPE"){
            $label = "item_type";
        }elsif($label eq "IMESSAGE"){
            $label = "note";
        }elsif($label eq "AGENCY"){
            $label = "agency";
        }elsif($label eq "IN LOC"){
            $label = "in_location";
        }elsif($label eq "LOU"){
            $label = "last_checkout_date";
        }elsif($label eq "ICODE1"){
            $label = "item_code1";
        }elsif($label eq "ICODE2"){
            $label = "item_code2";
        }elsif($label eq "ICODE3"){
            $label = "item_code3";
        }elsif($label eq "IUSE1"){
            $label = "item_use1";
        }elsif($label eq "IUSE2"){
            $label = "item_use2";
        }elsif($label eq "IUSE3"){
            $label = "item_use3";
        }elsif($label eq "OPACMSG"){
            $label = "opac_msg";
        }elsif($label eq "OUT LOC"){
            $label = "out_location";
        }elsif($label eq "# RENEWALS"){
            $label = "num_renewals";
        }elsif($label eq "# OVERDUE"){
            $label = "num_overdue";
        }elsif($label eq "LOANRULE"){
            $label = "loanrule";
        }elsif($label eq "LYRCIRC"){
            $label = "last_year_circ_stats";
        }

        if($label eq "holdable" and $value eq " -"){
            $value="t";
        }elsif($label eq "holdable" and $value eq "e"){
            $value="t";
        }elsif($label eq "holdable" ){
            $value="f";
        }
        
        $jhash->{$label}=$value;
    }

        #print Dumper $call_and_bib;
        if($jhash->{due_date}){
            if($jhash->{'due_date'} eq "-  -"){
                $jhash->{'due_date'} = '';
            }
        }

        # avoid leading/trailing spaces in cn
        $call_and_bib->[1] =~ s/^\s+//g;
        $call_and_bib->[1] =~ s/\s+$//g;

        $jhash->{'call_number'} = $call_and_bib->[1];
        #$jhash->{'bib_id'}=$call_and_bib->[0];
        $jhash->{'item_id'} = $record_number[0]; 
        $jhash->{'barcode'} = $barcode;
        $jhash->{'error_message'} = '';  
        #$jhash->{'fingerprint'} = $fingerprint[0];
        $jhash->{'fingerprint'} = '';
        #print Dumper $jhash;
        $logger->debug("Exiting parse_item_screen");
        #print  Dumper $jhash; 
        return $jhash;
}


sub get_item_by_call_number{
    my $self = $_[0];
    my $ssh = $self->initialize;
    my $item_id = $_[1];
    my $call_number_type = $_[2];
    my @out;
    my @entries; #If there are multiple entries for an item, the entries are stored here.
    #print "preparing to search the catalog\n";
    $ssh->print("S");
    $ssh->waitfor(-match => '/prominently\?/',
                  -errmode => "return") or die "search failed;", $ssh->lastline;
    #print "ok\n";
    #print "selecting option to search for items\n";
    $ssh->print("I");
    $ssh->waitfor(-match => '/SEARCHING RECORDS/',
                  -errmode => "return")or die "search failed;", $ssh->lastline;
    #print "ok\n";
    #select attribute to search by, i.e title, barcode etc...
    $ssh->print("C");
    $ssh->waitfor(-match => '/CALL NUMBER SEARCHES/',
                  -errmode => "return") or die "search failed;", $ssh->lastline;
    
    if(lc($call_number_type) eq "dewey"){
        
        $ssh->print("D");
        $ssh->waitfor(-match => '/DEWEY CALL NO :/',
                  -errmode => "return") or die "search failed;", $ssh->lastline;
    
    }elsif(lc($call_number_type) eq "lc"){
        $ssh->print("C");
        $ssh->waitfor(-match => '/LC CALL NO :/',
                  -errmode => "return") or die "search failed;", $ssh->lastline;
    
    }elsif(lc($call_number_type) eq "local"){
        $ssh->print("L");
        $ssh->waitfor(-match => '/LOCAL CALL NO :/',
                  -errmode => "return") or die "search failed;", $ssh->lastline;
    }
    
    $ssh->print($item_id); 
    push @out,$ssh->waitfor(-match => '/NEW Search/',
                  -errmode => "return") or die "search failed;", $ssh->lastline;
    #print "Done.\n";
    
    if(my @num_entries =  ($out[0] =~ /(\d+)\sentries found/)){
        #my $i = 0;
        #$i++;
        $ssh->print(1);
        push @out,$ssh->waitfor(-match => '/NEW Search/',
                  -errmode => "return") or die "search failed;", $ssh->lastline;
        #print "Done.\n";
    }

    $self->ssh_disconnect;
    my @items;
    push @items,$self->parse_item_screen($out[2]);
    return \@items;
}


#Under construction

sub get_item_by_bib_number_z3950{
    my $self = $_[0];
    my $bibID = $_[1];    
    my $marc = $self->get_bib_records_by_record_number_z3950($bibID);
    my $batch = MARC::Batch->new('XML', $marc ); 
    while (my $m = $batch->next ){
        print $m->subfield(650,"a"),"\n";

    }
    #my $record = $batch->next();
    #print Dumper $record; 

}





# Method: get_bib_records_by_record_num
# Params:
#   idList => list of record numbers

#BIBLIOGRAPHIC RECORDS
#Notes: Section contains methods to retrieve and parse bibliographic records
#==================================================================================


sub get_bib_records_by_record_number{
    my $self = $_[0];
    my $ssh = $self->initialize;
    my $id = $_[1];
    my $count=0;
    my @out;
    my @screen;
    my @marc;
    my @bib = ();
    my $jhash={};
    
    eval{ 
    if(ref($ssh) eq "ARRAY"){
        return $ssh;
    }

    #select SEARCH the catalog
    #print "getBibRecords\n";
    #print "preparing to search the catalog\n";
    $ssh->print("S");
    
    $ssh->waitfor(-match => '/prominently\?/',
                  -errmode => "return") or die "Search failed. Could not retrieve ", $id;

    #print "ok\n";
    #print "selecting option to search for bibliographic records\n";
    #select item record option
    $ssh->print("B");
    $ssh->waitfor(-match => '/SEARCHING RECORDS/',
                  -errmode => "return") or die "Search failed. Could not retrieve ", $id;
    
    #print "ok\n";
    #print "selecting option to search by record number\n";
    #select attribute to search by, i.e title, barcode etc...
    $ssh->print("R"); #search by record number
    #print "ok\n";
    #print "searching for id=$id\n";
    #search for id
    $ssh->print($id);
    my $first = 1;
    #print "searching more of the document\n";
    my @bid;
    
    my $get_more = sub {
                        my @temp_screen = (); 
                        my @lines;
                        my $last = 0;
                        my $get_more = shift;
                        
                        if($first == 1){
                            $ssh->print("T");
                            $ssh->waitfor(-match => '/BIBLIOGRAPHIC Information/',
                                -errmode => "return") or die "Search failed. Could not retrieve ", $id;
                                #-errmode => "return") or die "search failed;", $ssh->lastline;
                            $ssh->print("M");
                            #$first = 0;
                        }    
                        
                        $ssh->print("M");
                        $ssh->print("T");
                        #delete the following two lines
                        
                        push @temp_screen ,$ssh->waitfor(-match => '/Regular Display/',
                                -errmode => "return") or die "Search failed. Could not retrieve ", $id;
                                #-errmode => "return") or die "search failed;", $ssh->lastline;
                        #print Dumper $temp_screen[0];
                        
                        @bid = ($temp_screen[0] =~ /([Bb].*)\s+BIBLIOGRAPHIC Information/);
                        if($temp_screen[0] =~ /COUNTRY:/g and $first == 0 ){
                            #print Dumper $temp_screen[0];
                            #print "Reached end of record... I think\n";
                            return 1; 
                        }
                        push @lines,split(/\[\d+;\d+(;\d+)?[Hm]/,$temp_screen[0]);
                        
                        foreach  (@lines){   
                              if($_){ 
                                $_ =~ s/^(\s+)//g;
                                if($_ =~/^\d\d\d\s+.+/g){
                                   $_ =~ s/\x1b//g;
                                   $_ =~ s/\[0m//g;
                                   $_ =~ s/\[0xF\]//g;
                                   $_ =~ s/[[:cntrl:]]//g;
                                   push @marc,$_;
                                   #print Dumper $_;
                                }
                             }
                        }
                        #print Dumper @lines;

                        $first = 0;
                        #print Dumper @marc; 
                        $ssh->print("M");
                        $ssh->print("T");
                        @temp_screen = (); 
                        $get_more->($get_more);
                   };


    $get_more->($get_more);

    my @id = ($bid[0]) ? ($bid[0] =~ /([Bb][0-9]+)\s+/) : ""  ;
    #print Dumper @marc; 
     
    #print "bid = ".$id[0]."\n";
    #print "ok\n"; 
    #push @out, $self->parse_bib_records( $self->grab_bib_screen($ssh,$id), $id );
    #print "logging out\n";
    $ssh->print("N");
    $ssh->print("Q");
    $ssh->print("Q");
    $ssh->print("X");
    $ssh->waitfor(-match => '/closed/',
                  #-errmode => "return")or die "log out failed;", $ssh->lastline;
                  -errmode => "return") or die "Search failed. Could not retrieve ", $id;
    
    #print "logged out\n";
    my $rec =  breaker2marc(\@marc);
    $rec->insert_fields_ordered(
        MARC::Field->new(
            '907',
            ' ',
            ' ',
            'a' => $id[0]
        )
    ) if (!$rec->subfield( '907' => 'a' ));

    my $x =  $rec->as_xml_record;
    $x =~ s/^<\?.+?\?>.//sm;
    #my $jhash={};
    $jhash->{'marc'}=$x;
    #$bid =~ s/\[/$bid/g;
    $jhash->{'id'}=$id[0];
    $jhash->{'format'}="marcxml";
    $jhash->{error} = 0;
    $jhash->{error_message} = '';
    #print "xml = $x\n";
    #my @bib = ();
    push @bib,$jhash;
    #warn Dumper \@bib; 
    return \@bib;

    1;
    }or do {
        $jhash->{error} = 1;
        $jhash->{error_message} = $@;
        push @bib,$jhash;
        return \@bib;
    }

}




sub get_range_of_records{
    my $self = $_[0];
    my $list = $_[1];
    my $dir = `pwd`;
    my $file = "/openils/lib/perl5/FulfILLment/WWW/LAIConnector/conf/III_2009B_1_2/marc/marc_dump.mrc";
    open FILE, ">$file" or die &!;
   
    foreach my $r (@$list){
        my $record = $self->get_bib_records_by_record_number($r);

        print FILE $record->[0]->{marc};   

    }
    
    close FILE;
    my @out;
    my $jhash;
    push @out,$jhash;
    return \@out;

}







sub breaker2marc {
    my $lines = shift;
    my $delim = quotemeta(shift() || '|');
    my $rec = new MARC::Record;
    for my $line (@$lines) {

        chomp($line);

        if ($line =~ /^=?(\d{3})\s{2}(.)(.)\s(.+)$/) {

            my ($tag, $i1, $i2, $rest) = ($1, $2, $3, $4);
            if ($tag < 10) {
                $rec->insert_fields_ordered( MARC::Field->new( $tag => $rest ) );

            } else {

                my @subfield_data = split $delim, $rest;
                if ($subfield_data[0]) {
                    $subfield_data[0] = 'a' . $subfield_data[0];
                } else {
                    shift @subfield_data;
                }

                my @subfields;
                for my $sfd (@subfield_data) {
                    if ($sfd =~ /^(.)(.+)$/) {
                        push @subfields, $1, $2;
                    }
                }

                $rec->insert_fields_ordered(
                    MARC::Field->new(
                        $tag,
                        $i1,
                        $i2,
                        @subfields
                    )
                ) if @subfields;
            }
        }
    }

    return $rec;
}


#END BIBLIOGRAPHIC RECORDS
#=====================================================================================





#Places hold on a III server through the web interface



sub parse_hold_response{
    my $self = $_[0];
    my $txt = $_[1];
    my @resp = split("END SEARCH WIDGET -->",$txt);
    my $success = ($resp[1] =~ /denied/) ? "false" : "true"; 
    if(!defined($resp[1])){$success = "false"}
    my $msg = $resp[1];
    $msg =~ s/<p>//g;
    $msg =~ s/<\/p>//g;
    $msg =~ s/<br \/>//g;
    $msg =~ s/&nbsp;//g;
    $msg =~ s/<!-End the bottom logo table-->//g;
    $msg =~ s/<\/body>//g;
    $msg =~ s/<\/html>//g;
    $msg =~ s/<\/strong\>//g;
    $msg =~ s/<strong>//g;
    $msg =~ s/\./\. /g;
    $msg =~ s/\n//g;
    $msg =~ s/<font color="red"\s+size="\+2">/\. /g;
    $msg =~ s/<\/font>//g;
    my $data = {};
    $data->{'success'} = $success;
    $data->{'message'} = $msg;
    my $out = []; 
    $out->[0] = $data;
    return $out; 
}



sub list_holds{
    $logger->debug("In list_holds");
    my $self = shift;
    my $host = $self->{host};
    my $port = $self->{port};
    my $user_barcode = shift;
    my $passwd = shift;
    my $patron_sys_num = shift;
    my $action = shift || "list_holds";
    my $response;
    my $content;
    $logger->debug("params are host=$host\n port=$port\n user_barcode=$user_barcode\n passwd=$passwd\n patron_sys_number=$patron_sys_num");
    my $url = "https://$host:$port/patroninfo~S0/$patron_sys_num/holds/?name=$user_barcode&code=$passwd";
    my $out;
    my $mech = WWW::Mechanize->new();
    
    eval{
        $mech->post($url);
        $mech->form_name('patform');
        $mech->set_fields('pin',$passwd,
                          'code',$user_barcode  
                    
                            );

        $response = $mech->submit(); 
        $content = $mech->content;
    };
    
    if($@){
        my $hold;
        my @out;
        $hold->{error} = 1;
        $hold->{error_message} = "There was an error looking up holds for the user $user_barcode : $@";
        push @out,$hold;
        $logger->debug("Exiting list_holds");
        return \@out;
    }
 
    
    $logger->debug("Exiting list_holds");
    return $self->parse_hold_list($content,"list_holds");

}



sub list_holds_by_bib{
    my $self = shift;
    my $host = shift;
    my $port = shift;
    my $login = shift;
    my $user_barcode = shift;
    my $bibID = shift;
    my $patron_sys_num = shift;
    my $holds =  $self->list_holds($host,$port,$login,$user_barcode,$patron_sys_num);
    my @out;

    foreach(@$holds){
        if($_->{'bibid'} eq $bibID){
            push @out,$_;
        }
    }
    
    return \@out;
}



sub list_holds_by_item{
    my $self = shift;
    my $host = shift;
    my $port = shift;
    my $login = shift;
    my $user_barcode = shift;
    my $itemID = shift;
    my $patron_sys_num = shift;
    my $holds =  $self->list_holds($host,$port,$login,$user_barcode,$patron_sys_num);
    my @out;

    foreach(@$holds){
        if($_->{'itemid'} eq $itemID){
            push @out,$_;
        }
    }
    
    return \@out;
}


sub delete_hold{
    $logger->debug("In delete_hold");
    my $self = shift;
    my $host = $self->{host};
    my $port = $self->{port};
    my $userid = $self->{login};
    $userid =~ s/\s/%20/g;
    my $search_id = shift;
    my $id_type = shift;
    my $patron_sys_num = shift;
    my $user_barcode = shift;

    $logger->debug("fields are host=$host\n port=$port \n userid=$userid \n search_id=$search_id \n id_type=$id_type \n patron_sys_num=$patron_sys_num \n user_barcode=$user_barcode\n");
    
    my $response_body;
    my $holds =  $self->list_holds($userid,$user_barcode,$patron_sys_num);
    my $itemid;
    my $linkid;
    my $num_holds_before = @$holds;
    my $num_holds_after;
    
    if($id_type eq "bib"){ 
    
        if(length($search_id) > 8){
            chop($search_id);
        }
        
        foreach(@$holds){
            #print "bibid = $_->{bibid}  search_id = $search_id\n";
            if($_->{'bibid'} eq $search_id){
                #print "item id = ".$_->{'itemid'}."\n";
                $itemid = $_->{'itemid'};
                $linkid = $_->{'linkid'};
            }
        }
    }elsif($id_type eq "item"){
        foreach(@$holds){
            if($_->{'itemid'} eq $search_id){
                #print "item id = ".$_->{'itemid'}."\n";
                $itemid = $_->{'itemid'};
                $linkid = $_->{'linkid'};
            }
        }
    }
   
    $itemid = (defined($itemid)) ? $itemid : "";
    $linkid = (defined($linkid)) ? $linkid : "";
    my $url = "https://$host:$port/patroninfo~SO/$patron_sys_num/holds?name=$userid&code=$user_barcode&$linkid=on&currentsortorder=current_pickup&updateholdssome=YES&loc$itemid=";
    my @out;
    my $msg = {};
    my $mech = WWW::Mechanize->new();
    $response_body = $mech->post($url);

    if($mech->success){
       my $nha = $self->list_holds($userid,$user_barcode,$patron_sys_num);
       $num_holds_after = @$nha;
       #check to see whether the user was successfully authenticated 
       my $auth = $self->loggedIn($response_body);
       
       if($auth ne "t"){
           $msg->{"error"} = 1;
           $msg->{"error_message"} = "The user $userid could not be authenticated";
           push @out, $msg;
           return \@out;
       }
       
       if($num_holds_before == $num_holds_after){
           $msg->{"error"} = 1;
           $msg->{"error_message"} = "The hold for $search_id either does not exist or could not be deleted";
           push @out, $msg;
           return \@out;
       }elsif($num_holds_before > $num_holds_after){
           $msg->{"error"} = 0;
           $msg->{"success_message"} = "The hold for $search_id has been deleted";
           push @out, $msg; 
           return \@out;
       }
       
    }else{
       $msg->{"error"} = 1;
       $msg->{"error_message"} = "An error occured: code $mech->status";
       push @out, $msg;
       return \@out; 
    }
}




sub parse_hold_list{
    my $self = shift;
    my $in = shift;
    my $action = shift;
    $in =~ s/\n//g;
    my @holds; 
    my @holdEntries = split(/(<tr class="patFuncEntry".*?<\/tr>)/ ,$in); 
    my $user = {};
    shift @holdEntries;
    pop @holdEntries;
    my @userSurname = ($in =~ /<h4>Patron Record for<\/h4><strong>(\w+),.*<\/strong><br \/>/);
    my @userGivenName = ($in =~ /<h4>Patron Record for<\/h4><strong>(\w+),.*<\/strong><br \/>/);
    my @expDate = ($in =~ /EXP DATE:(\d\d\-\d\d\-\d\d\d\d)<br \/>/);

    
    $user->{surname} = $userSurname[0]; 
    $user->{given_name} = $userGivenName[0]; 
    $user->{exp_date} = $expDate[0]; 
    
    if($action eq "lookup_user"){
        push @holds,$user;
    }elsif($action eq "list_holds"){

        foreach(@holdEntries){
            my $hold = {};
            my @bibid = ($_ =~ /record=(.*)~/);
            my @pickup = ($_ =~ /"patFuncPickup">(\w+)<\/td>/);
            my @title = ($_ =~ /record=.*>\s(.*)<\/a>/);
            my @status = ($_ =~ /"patFuncStatus">\s(\w+)\s<\/td>/);
            my @itemid = ($_ =~ /id="cancel(\w+)x/); 
            my @linkid = ($_ =~ /id="(cancel.+x\d+)"\s+\/>/); 
        
            $hold->{'bibid'} = $bibid[0] if(defined $bibid[0]);
            $hold->{'pickup'} = $pickup[0] if(defined $pickup[0]);
            $hold->{'title'} = $title[0] if(defined $title[0]);
            $hold->{title} =~ s/<.+>.*<\/.+>//g if(defined $hold->{title});
            $hold->{'status'} = $status[0] if(defined $status[0]);
            $hold->{'itemid'} = $itemid[0] if(defined $status[0]);
            $hold->{'linkid'} = $linkid[0] if(defined $status[0]);
            push @holds, $hold if (defined $hold->{'bibid'});
        }

        if($user->{surname}){
            $user->{error} = 0;
            $user->{error_meessage} = '';
        }else{
            $user->{error} = 1;
            $user->{error_message} = 'supplied user could not be looked up';
        }
    }
    
    return \@holds;
}


sub loggedIn{
    my $self = $_[0];
    my $response = $_[1];
    if($response =~ /Please enter the following information/g){
        return "f";
    }

    return "t";
}





1;
