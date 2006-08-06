package OpenILS::Const;
use strict; use warnings;
use vars qw(@EXPORT_OK %EXPORT_TAGS);
use Exporter;
use base qw/Exporter/;


# ---------------------------------------------------------------------
# Shoves defined constants into the export array
# so they don't have to be listed twice in the code
# ---------------------------------------------------------------------
sub econst {
   my($name, $value) = @_;
   my $caller = caller;
   no strict;
   *{$name} = sub () { $value };
   push @{$caller.'::EXPORT_OK'}, $name;
}

# ---------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------



# ---------------------------------------------------------------------
# Copy Statuses
# ---------------------------------------------------------------------
econst OILS_COPY_STATUS_AVAILABLE     => 0;
econst OILS_COPY_STATUS_CHECKED_OUT   => 1;
econst OILS_COPY_STATUS_BINDERY       => 2;
econst OILS_COPY_STATUS_LOST          => 3;
econst OILS_COPY_STATUS_MISSING       => 4;
econst OILS_COPY_STATUS_IN_PROCESS    => 5;
econst OILS_COPY_STATUS_IN_TRANSIT    => 6;
econst OILS_COPY_STATUS_RESHELVING    => 7;
econst OILS_COPY_STATUS_ON_HOLDS_SHELF=> 8;
econst OILS_COPY_STATUS_ON_ORDER	     => 9;
econst OILS_COPY_STATUS_ILL           => 10;
econst OILS_COPY_STATUS_CATALOGING    => 11;
econst OILS_COPY_STATUS_RESERVES      => 12;
econst OILS_COPY_STATUS_DISCARD       => 13;
econst OILS_COPY_STATUS_DAMAGED       => 14;


# ---------------------------------------------------------------------
# Circ defaults for pre-cataloged copies
# ---------------------------------------------------------------------
econst OILS_PRECAT_COPY_FINE_LEVEL    => 2;
econst OILS_PRECAT_COPY_LOAN_DURATION => 2;
econst OILS_PRECAT_CALL_NUMBER        => -1;
econst OILS_PRECAT_RECORD			     => -1;


# ---------------------------------------------------------------------
# Circ constants
# ---------------------------------------------------------------------
econst OILS_CIRC_DURATION_SHORT       => 1;
econst OILS_CIRC_DURATION_NORMAL      => 2;
econst OILS_CIRC_DURATION_EXTENDED    => 3;
econst OILS_REC_FINE_LEVEL_LOW        => 'low';
econst OILS_REC_FINE_LEVEL_NORMAL     => 'normal';
econst OILS_REC_FINE_LEVEL_HIGH       => 'high';
econst OILS_STOP_FINES_CHECKIN        => 'CHECKIN';
econst OILS_STOP_FINES_RENEW          => 'RENEW';
econst OILS_STOP_FINES_LOST           => 'LOST';
econst OILS_STOP_FINES_CLAIMSRETURNED => 'CLAIMSRETURNED';
econst OILS_STOP_FINES_LONGOVERDUE    => 'LONGOVERDUE';





# ---------------------------------------------------------------------
# finally, export all the constants
# ---------------------------------------------------------------------
%EXPORT_TAGS = ( const => [ @EXPORT_OK ] );

