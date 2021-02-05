#
#===============================================================================
#
#         FILE: z39.50.pm
#
#  DESCRIPTION: 
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Michael Davadrian Smith (), msmith@esilibrary.com
#      COMPANY: Equinox Software
#      VERSION: 1.0
#      CREATED: 12/12/2011 01:12:32 PM
#     REVISION: ---
#===============================================================================

package FulfILLment::Util::Z3950;
use strict;
use warnings;
use Data::Dumper;
use JSON::XS;
use ZOOM;
use MARC::Record;
use MARC::File::XML ( BinaryEncoding => 'utf8' );
use MARC::Charset;
use OpenSRF::Utils::Logger qw/$logger/;

MARC::Charset->ignore_errors(1);

sub new{
    my($type) = shift;
    my $host = shift;
    #$host =~ s/http:\/\///;
    my $port = shift;
    my $database = shift; 
    my $login= shift;
    my $password= shift;
    my ($self)={
        'host'=>$host,
        'login' => $login,
        'password' => $password,
        'database' => $database,
        'port' => $port,
        'out'=>'',#will hold output of query 
    };
   
    bless($self,$type);

}


sub breaker2marc {
    my $lines = shift;
    my $delim = quotemeta(shift() || '$');

    my $rec = new MARC::Record;

    my $first = 1;
    for my $line (@$lines) {

        chomp($line);

        if ($first) {
            if ($line =~ /^\d/) {
                $rec->leader($line);
                $first--;
            }
        } elsif ($line =~ /^=?(\d{3}) (.)(.) (.+)$/) {

            my ($tag, $i1, $i2, $rest) = ($1, $2, $3, $4);

            if ($tag < 10) {
                $rec->insert_fields_ordered( MARC::Field->new( $tag => $rest ) );

            } else {

                my @subfield_data = split $delim, $rest;
                if ($subfield_data[0]) {
                    $subfield_data[0] = 'a ' . $subfield_data[0];
                } else {
                    shift @subfield_data;
                }

                my @subfields;
                for my $sfd (@subfield_data) {
                    if ($sfd =~ /^(.) (.+)$/) {
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


sub get_record_by_id {
    my $self = shift;
    my $recid = shift;
    my $attr = shift || '12';
    my $asxml = shift || 1;
    my $syntax = shift || 'usmarc';
    my $return_raw = shift || 0;

    my $conn = new ZOOM::Connection(
        $self->{'host'},
        $self->{'port'},
        databaseName => $self->{'database'},
        preferredRecordSyntax => $syntax
    );

    my $query = "\@attr 1=$attr \"$recid\"";

    $logger->info(sprintf(
        "FF Z3950 sending query to %s/%s => %s", 
        $self->{host}, $self->{database}, $query));

    my $rs = $conn->search_pqf($query);
     
    if ($conn->errcode() != 0) {
        $logger->error("Z39 bib-by-id failed: " . $conn->errmsg());
        return;
    }         

    $logger->info("Z39 bib-by-id returned ".$rs->size." hit(s)");

    return unless $rs->size;

    return $rs->record(0)->raw if $return_raw;

    # warning: render() is highly subjective and may
    # not behave as expected on all Z servers and formats
    my $m =  $rs->record(0)->render();

    my $rec =  breaker2marc([ split /\n/, $m ]);

    my $x =  $rec->as_xml_record;
    $x =~ s/^<\?.+?\?>.//sm;

    my @out;
    $conn->destroy();
    if($asxml == 1){
        return $x;
    }elsif($asxml == 0){
        return $m;
    }
}



sub getBibByTitle{
    my $self = shift;
    my $title = shift;
    my $attr = "4";
    my $asxml = shift || 1;

    my $conn = new ZOOM::Connection(
        $self->{'host'},
        $self->{'port'},
        databaseName => $self->{'database'},
        preferredRecordSyntax => "usmarc"
    );

     my $rs = $conn->search_pqf("\@attr 1=$attr \"$title\"");
     
     if ($conn->errcode() != 0) {
        die("something went wrong: " . $conn->errmsg())
     }         
    
    my $m =  $rs->record(0)->render();
    my $rec =  breaker2marc([ split /\n/, $m ]);
    my $x =  $rec->as_xml_record;
    $x =~ s/^<\?.+?\?>.//sm;

    my @out;
    $conn->destroy();
    if($asxml == 1){
        return $x;
    }elsif($asxml == 0){
        return $m;
    }
}





sub queryServer{
    my $self = shift;
    my $query = shift;
    my $asxml = shift || 1;
    my $conn = new ZOOM::Connection(
        $self->{host},
        $self->{port},
        databaseName => $self->{database},
        preferredRecordSyntax => "usmarc"
    );
    my $rs = $conn->search_pqf($query);
    
    if($conn->errcode() != 0){
        die("something went wrong: ".$conn->errmsg());
    }

    my $m =  $rs->record(0)->render();
    my $rec =  breaker2marc([ split /\n/, $m ]);
    my $x =  $rec->as_xml_record;
    $x =~ s/^<\?.+?\?>.//sm;
    my @out;
    $conn->destroy();
    if($asxml == 1){
        return $x;
    }elsif($asxml == 0){
        return $m;
    }


}















1;
