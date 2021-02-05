package OpenILS::Application::Search::Zips;
use base qw/OpenILS::Application/;
use strict; use warnings;

use OpenSRF::EX qw(:try);
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Application::AppUtils;
use OpenSRF::Utils::SettingsClient;

use open ':utf8';

my %zips;

# -----------------------------------------------------------------
# Reads zip code information from a file.  File format is : 
# ID|StateAbb|City|Zip|IsDefault|StateID|County|AreaCode
# Currently, StateAbb, City, Zip, County, AreaCode are used.  
# IsDefault should be set to 1
# -----------------------------------------------------------------

sub initialize {
    my $conf = OpenSRF::Utils::SettingsClient->new;
    my $zfile = $conf->config_value(
        "apps", "open-ils.search", "app_settings", "zips_file");
    return 1 unless $zfile and -f $zfile;

    $logger->info("search loaded zips file $zfile");
    open(F,$zfile);
    my @data = <F>;
    close(F);

    for(@data) {
        chomp $_;
        my @items = split(/\|/, "$_");
        my $items = {
            state       => $items[1],
            city        => $items[2],
            zip     => $items[3],
            stateid => $items[5],
            county  => $items[6],
            areacode    => $items[7],
            alert   => $items[8]
        };

        next unless $items[4] eq '1';
        $zips{$$items{zip}} = $items;
    }
}

__PACKAGE__->register_method(
    method => 'search_zip',
    api_name    => 'open-ils.search.zip',
    signature   => q/
        Given a zip code, returns address info for the zip code
        @param auth the login session key
        @param zip The zip code to check
        @return On success, returns an object of the form:
        { state=>, city=>, zip=>, stateid=>, county=>, areacode=>}
        returns event on error
    /
);
sub search_zip {
    my( $self, $conn, $zip ) = @_;
    $zip =~ s/(^\d{5}).*/$1/; # we don't care about the last 4 digits if they exist 
    return $zips{$zip};
}

1;
