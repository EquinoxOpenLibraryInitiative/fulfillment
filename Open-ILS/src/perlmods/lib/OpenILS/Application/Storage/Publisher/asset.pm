package OpenILS::Application::Storage::Publisher::asset;
use base qw/OpenILS::Application::Storage/;
#use OpenILS::Application::Storage::CDBI::asset;
#use OpenILS::Utils::Fieldmapper;
use OpenSRF::Utils::Logger qw/:level/;
use OpenSRF::EX qw/:try/;
use OpenSRF::Utils::JSON;

#

my $log = 'OpenSRF::Utils::Logger';

use MARC::Record;
use MARC::File::XML ( BinaryEncoding => 'UTF-8' );

#our $_default_subfield_map = {
#        call_number     => $cn,
#        barcode         => $bc,
#        owning_lib      => $ol,
#        circulating_lib => $cl,
#        copy_location   => $sl,
#        copy_number     => $num,
#        price           => $pr,
#        status          => $loc,
#        create_date     => $date,
#
#        legacy_item_type        => $it,
#        legacy_item_cat_1       => $ic1,
#        legacy_item_cat_2       => $ic2,
#};

my %org_cache;

sub import_xml_holdings {
    my $self = shift;
    my $client = shift;
    my $editor = shift;
    my $record = shift;
    my $xml = shift;
    my $tag = shift;
    my $map = shift;
    my $date_format = shift || 'mm/dd/yyyy';

    ($record) = biblio::record_entry->search_where($record);

    return 0 unless ($record);

    my $r = MARC::Record->new_from_xml($xml);

    my $count = 0;
    for my $f ( $r->fields( $tag ) ) {
        next unless ($f->subfield( $map->{owning_lib} ));

        my ($ol,$cl);

        try {
            $ol = 
                $org_cache{ $f->subfield( $map->{owning_lib} ) }
                || actor::org_unit->search( shortname => $f->subfield( $map->{owning_lib} ) )->next->id;

            $org_cache{ $f->subfield( $map->{owning_lib} ) } = $ol;
        } otherwise {
            $log->debug('Could not find library with shortname ['.$f->subfield( $map->{owning_lib} ).'] : '. shift(), ERROR);
            $log->info('Failed holdings tag: ['.OpenSRF::Utils::JSON->perl2JSON( $f ).']');
        };
        
        try {
            $cl =
                $org_cache{ $f->subfield( $map->{circulating_lib} ) }
                || actor::org_unit->search( shortname => $f->subfield( $map->{circulating_lib} ) )->next->id;

            $org_cache{ $f->subfield( $map->{circulating_lib} ) } = $cl;
        } otherwise {
            $log->debug('Could not find library with shortname ['.$f->subfield( $map->{circulating_lib} ).'] : '. shift(), ERROR);
            $log->info('Failed holdings tag: ['.OpenSRF::Utils::JSON->perl2JSON( $f ).']');
        };

        next unless ($ol && $cl);

        my $cn;
        try {
            $cn = asset::call_number->find_or_create(
                { label     => $f->subfield( $map->{call_number} ),
                  owning_lib    => $ol,
                  record    => $record->id,
                  creator   => $editor,
                  editor    => $editor,
                }
            );
        } otherwise {
            $log->debug('Could not find or create callnumber ['.$f->subfield( $map->{call_number} )."] on record $record : ". shift(), ERROR);
            $log->info('Failed holdings tag: ['.OpenSRF::Utils::JSON->perl2JSON( $f ).']');
        };

        next unless ($cn);

        my $create_date =  $f->subfield( $map->{create_date} );

        my ($m,$d,$y);
        if ($date_format eq 'mm/dd/yyyy') {
            ($m,$d,$y) = split '/', $create_date;

        } elsif ($date_format eq 'dd/mm/yyyy') {
            ($d,$m,$y) = split '/', $create_date;

        } elsif ($date_format eq 'mm-dd-yyyy') {
            ($m,$d,$y) = split '-', $create_date;

        } elsif ($date_format eq 'dd-mm-yyyy') {
            ($d,$m,$y) = split '-', $create_date;

        } elsif ($date_format eq 'yyyy-mm-dd') {
            ($y,$m,$d) = split '-', $create_date;

        } elsif ($date_format eq 'yyyy/mm/dd') {
            ($y,$m,$d) = split '/', $create_date;
        }

        if ($y == 0) {
            (undef,undef,undef,$d,$m,$y) = localtime;
            $m++;
            $y+=1900;
        }

        my $price = $f->subfield( $map->{price} );
        $price =~ s/[^0-9\.]+//gso;
        $price ||= '0.00';

        try {
            $cn->add_to_copies(
                { circ_lib  => $cl,
                  copy_number   => $f->subfield( $map->{copy_number} ),
                  price     => $price,
                  barcode   => $f->subfield( $map->{barcode} ),
                  loan_duration => 2,
                  fine_level    => 2,
                  creator   => $editor,
                  editor    => $editor,
                  create_date   => sprintf('%04d-%02d-%02d',$y,$m,$d),
                }
            );
            $count++;
        } otherwise {
            $log->debug('Could not create copy ['.$f->subfield( $map->{barcode} ).'] : '. shift(), ERROR);
        };
    }

    return $count;
}
__PACKAGE__->register_method(
    method      => 'import_xml_holdings',
    api_name    => 'open-ils.storage.asset.holdings.import.xml',
    argc        => 5,
    stream      => 0,
);

# XXX
# see /home/miker/cn_browse-test.sql for page up and down sql ...
# XXX

sub cn_browse_pagedown {
    my $self = shift;
    my $client = shift;

    my %args = @_;

    my $cn = uc($args{label});
    my $org = $args{org_unit};
    my $depth = $args{depth};
    my $boundry_id = $args{boundry_id};
    my $size = $args{page_size} || 20;
    $size = int($size);

    my $table = asset::call_number->table;

    my $descendants = "actor.org_unit_descendants($org)";
    if (defined $depth) {
        $descendants = "actor.org_unit_descendants($org,$depth)";
    }

    my $orgs = join(',', @{ asset::call_number->db_Main->selectcol_arrayref("SELECT DISTINCT id FROM $descendants;") });
    
    my $sql = <<"    SQL";
        select
                cn.label,
                cn.owning_lib,
                cn.record,
                cn.id
        from
                $table cn
        where
            not deleted
                and (oils_text_as_bytea(label) > ? or ( cn.id > ? and oils_text_as_bytea(label) = ? ))
            and owning_lib in ($orgs)
        order by oils_text_as_bytea(label), 4, 2
        limit $size;
    SQL

    my $sth = asset::call_number->db_Main->prepare($sql);
    $sth->execute($cn, $boundry_id, $cn);
    while ( my @row = $sth->fetchrow_array ) {
        $client->respond([@row]);
    }
    $sth->finish;

    return undef;
}
__PACKAGE__->register_method(
    method      => 'cn_browse_pagedown',
    api_name    => 'open-ils.storage.asset.call_number.browse.page_down',
    argc        => 4,
    stream      => 1,
);

sub cn_browse_pageup {
    my $self = shift;
    my $client = shift;

    my %args = @_;

    my $cn = uc($args{label});
    my $org = $args{org_unit};
    my $depth = $args{depth};
    my $boundry_id = $args{boundry_id};
    my $size = $args{page_size} || 20;
    $size = int($size);

    my $table = asset::call_number->table;

    my $descendants = "actor.org_unit_descendants($org)";
    if (defined $depth) {
        $descendants = "actor.org_unit_descendants($org,$depth)";
    }

    my $orgs = join(',', @{ asset::call_number->db_Main->selectcol_arrayref("SELECT DISTINCT id FROM $descendants;") });

    my $sql = <<"    SQL";
        select * from (
            select
                    cn.label,
                    cn.owning_lib,
                    cn.record,
                    cn.id
            from
                    $table cn
            where
                not deleted
                    and (oils_text_as_bytea(label) < ? or ( cn.id < ? and oils_text_as_bytea(label) = ? ))
                and owning_lib in ($orgs)
            order by oils_text_as_bytea(label) desc, 4 desc, 2 desc
            limit $size
        ) as bar
        order by 1,4,2;
    SQL

    my $sth = asset::call_number->db_Main->prepare($sql);
    $sth->execute($cn, $boundry_id, $cn);
    while ( my @row = $sth->fetchrow_array ) {
        $client->respond([@row]);
    }
    $sth->finish;

    return undef;
}
__PACKAGE__->register_method(
    method      => 'cn_browse_pageup',
    api_name    => 'open-ils.storage.asset.call_number.browse.page_up',
    argc        => 4,
    stream      => 1,
);

sub cn_browse_target {
    my $self = shift;
    my $client = shift;

    my %args = @_;

    my $cn = uc($args{label});
    my $org = $args{org_unit};
    my $depth = $args{depth};
    my $size = $args{page_size} || 20;
    my $topsize = $size / 2;
    $topsize = int($topsize);
    $bottomsize = $size - $topsize;

    my $table = asset::call_number->table;

    my $descendants = "actor.org_unit_descendants($org)";
    if (defined $depth) {
        $descendants = "actor.org_unit_descendants($org,$depth)";
    }

    my $orgs = join(',', @{ asset::call_number->db_Main->selectcol_arrayref("SELECT DISTINCT id FROM $descendants;") });

    my $top_sql = <<"    SQL";
        select * from (
            select
                    cn.label,
                    cn.owning_lib,
                    cn.record,
                    cn.id
            from
                    $table cn
            where
                not deleted
                    and oils_text_as_bytea(label) < ?
                and owning_lib in ($orgs)
            order by oils_text_as_bytea(label) desc, 4 desc, 2 desc
            limit $topsize
        ) as bar
        order by 1,4,2;
    SQL

    my $bottom_sql = <<"    SQL";
        select
                cn.label,
                cn.owning_lib,
                cn.record,
                cn.id
        from
                $table cn
        where
            not deleted
                and oils_text_as_bytea(label) >= ?
            and owning_lib in ($orgs)
        order by oils_text_as_bytea(label),4,2
        limit $bottomsize;
    SQL

    my $sth = asset::call_number->db_Main->prepare($top_sql);
    $sth->execute($cn);
    while ( my @row = $sth->fetchrow_array ) {
        $client->respond([@row]);
    }
    $sth->finish;

    $sth = asset::call_number->db_Main->prepare($bottom_sql);
    $sth->execute($cn);
    while ( my @row = $sth->fetchrow_array ) {
        $client->respond([@row]);
    }
    $sth->finish;

    return undef;
}
__PACKAGE__->register_method(
    method      => 'cn_browse_target',
    api_name    => 'open-ils.storage.asset.call_number.browse.target',
    argc        => 4,
    stream      => 1,
);


sub copy_proximity {
    my $self = shift;
    my $client = shift;

    my $cp = shift;
    my $org = shift;    # hold pickup lib
    my $hold = shift;

    return unless ($cp && $org);

    if ($hold) {
        my $row = action::hold_request->db_Main->selectrow_hashref(
            'SELECT proximity AS prox FROM action.hold_copy_map WHERE hold = ? and target_copy = ?',
            {},
            "$hold",
            "$cp"
        );
        return $row->{prox} if $row;

        # There was a bug here before.
        # action.hold_copy_calculated_proximity()  was called with a
        # third argument, $org.  Wrong.  a.hccp() interprets its third
        # argument as an optional override of copy circ lib.  $org
        # here is hold pickup lib.  This had the effect of basically
        # measuring the distance between a hold's pickup lib and
        # itself, which is always zero, so all proximities landing in
        # the hold copy map were zero.

        $log->debug("Calculating copy proximity with: action.hold_copy_calculated_proximity($hold,$cp)", DEBUG);
        $row = action::hold_request->db_Main->selectrow_hashref(
            'SELECT action.hold_copy_calculated_proximity(?,?) AS prox',
            {},
            "$hold",
            "$cp"
        );

        return $row->{prox} if $row;
    }

    $cp = asset::copy->retrieve($cp) unless (ref($cp));

    return unless $cp;
    my $ol = $cp->circ_lib;

    return (actor::org_unit_proximity->search( from_org => "$ol", to_org => "$org"))[0]->prox;
}
__PACKAGE__->register_method(
    method      => 'copy_proximity',
    api_name    => 'open-ils.storage.asset.copy.proximity',
    argc        => 2,
    stream      => 1,
);

sub asset_copy_location_all {
    my $self = shift;
    my $client = shift;

    for my $rec ( asset::copy_location->retrieve_all ) {
        next if $rec->deleted eq "t";
        $client->respond( $rec->to_fieldmapper );
    }

    return undef;
}
__PACKAGE__->register_method(
    method      => 'asset_copy_location_all',
    api_name    => 'open-ils.storage.direct.asset.copy_location.retrieve.all',
    argc        => 0,
    stream      => 1,
);

# XXX arg, with the descendancy SPs...
sub ranged_asset_copy_location {
        my $self = shift;
        my $client = shift;
        my @binds = @_;
        
        my $ctable = asset::copy_location->table;
        
        my $descendants = defined($binds[1]) ?
                "actor.org_unit_full_path(?, ?)" :
                "actor.org_unit_full_path(?)" ;

        
        my $sql = <<"    SQL";
                SELECT  DISTINCT c.*
                  FROM  $ctable c
                        JOIN $descendants d
                                ON (d.id = c.owning_lib)
                  WHERE deleted IS FALSE
                 ORDER BY name
    SQL
        
        my $sth = asset::copy_location->db_Main->prepare($sql);
        $sth->execute(@binds);
        
        while ( my $rec = $sth->fetchrow_hashref ) {
        
                my $cnct = new Fieldmapper::asset::copy_location;
        map {$cnct->$_($$rec{$_})} keys %$rec;
                $client->respond( $cnct );
        }

        return undef;
}
__PACKAGE__->register_method(
        method          => 'ranged_asset_copy_location',
        api_name        => 'open-ils.storage.ranged.asset.copy_location.retrieve',
        argc            => 1,
        stream          => 1,
);


sub fleshed_copy {
    my $self = shift;
    my $client = shift;
    my @ids = @_;

    return undef unless (@ids);

    @ids = ($ids[0]) unless ($self->api_name =~ /batch/o);

    for my $id ( @ids ) {
        next unless $id;
        my $cp = asset::copy->retrieve($id);
        next unless $cp;

        my $cp_fm = $cp->to_fieldmapper;
        $cp_fm->circ_lib( $cp->circ_lib->to_fieldmapper );
        $cp_fm->location( $cp->location->to_fieldmapper );
        $cp_fm->status( $cp->status->to_fieldmapper );
        $cp_fm->stat_cat_entries( [ map { $_->to_fieldmapper } $cp->stat_cat_entries ] );

        $client->respond( $cp_fm );
    }

    return undef;
}
__PACKAGE__->register_method(
    api_name    => 'open-ils.storage.fleshed.asset.copy.batch.retrieve',
    method      => 'fleshed_copy',
    argc        => 1,
    stream      => 1,
);
__PACKAGE__->register_method(
    api_name    => 'open-ils.storage.fleshed.asset.copy.retrieve',
    method      => 'fleshed_copy',
    argc        => 1,
);

sub fleshed_copy_by_barcode {
    my $self = shift;
    my $client = shift;
    my $bc = ''.shift;

    my ($cp) = asset::copy->search( { barcode => $bc } );

    return undef unless ($cp);

    my $cp_fm = $cp->to_fieldmapper;
    $cp_fm->circ_lib( $cp->circ_lib->to_fieldmapper );
    $cp_fm->location( $cp->location->to_fieldmapper );
    $cp_fm->status( $cp->status->to_fieldmapper );

    return $cp_fm;
}   
__PACKAGE__->register_method(
    api_name    => 'open-ils.storage.fleshed.asset.copy.search.barcode',
    method      => 'fleshed_copy_by_barcode',
    argc        => 1,
    stream      => 1,
);


#XXX Fix stored proc calls
sub fleshed_asset_stat_cat {
        my $self = shift;
        my $client = shift;
        my @list = @_;

    @list = ($list[0]) unless ($self->api_name =~ /batch/o);
    for my $sc (@list) {
            my $cat = asset::stat_cat->retrieve($sc);
        
        next unless ($cat);

                my $sc_fm = $cat->to_fieldmapper;
                $sc_fm->entries( [ map { $_->to_fieldmapper } $cat->entries ] );
                $client->respond( $sc_fm );
        }

        return undef;
}
__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.fleshed.asset.stat_cat.retrieve',
        api_level       => 1,
        method          => 'fleshed_asset_stat_cat',
);

__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.fleshed.asset.stat_cat.retrieve.batch',
        api_level       => 1,
        stream          => 1,
        method          => 'fleshed_asset_stat_cat',
);


#XXX Fix stored proc calls
sub ranged_asset_stat_cat {
        my $self = shift;
        my $client = shift;
        my $ou = ''.shift();

        return undef unless ($ou);
        my $s_table = asset::stat_cat->table;

        my $select = <<"        SQL";
                SELECT  s.*
                  FROM  $s_table s
                        JOIN actor.org_unit_full_path(?) p ON (p.id = s.owner)
                  ORDER BY name
        SQL

        $fleshed = 0;
        $fleshed = 1 if ($self->api_name =~ /fleshed/o);

        my $sth = asset::stat_cat->db_Main->prepare_cached($select);
        $sth->execute($ou);

        for my $sc ( map { asset::stat_cat->construct($_) } $sth->fetchall_hash ) {
                my $sc_fm = $sc->to_fieldmapper;
                $sc_fm->entries(
                        [ $self->method_lookup( 'open-ils.storage.ranged.asset.stat_cat_entry.search.stat_cat' )->run($ou,$sc->id) ]
                ) if ($fleshed);
                $client->respond( $sc_fm );
        }

        return undef;
}
__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.ranged.fleshed.asset.stat_cat.all',
        api_level       => 1,
        stream          => 1,
        method          => 'ranged_asset_stat_cat',
);

__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.ranged.asset.stat_cat.all',
        api_level       => 1,
        stream          => 1,
        method          => 'ranged_asset_stat_cat',
);


#XXX Fix stored proc calls
sub multiranged_asset_stat_cat {
        my $self = shift;
        my $client = shift;
        my $ous = shift;

        return undef unless (defined($ous) and @$ous);
        my $s_table = asset::stat_cat->table;

        my $select = <<"        SQL";
                SELECT  s.*
                  FROM  $s_table s
          WHERE s.owner IN ( XXX )
                  ORDER BY name
        SQL

    my $collector = ' INTERSECT ';
    my $entry_method = 'open-ils.storage.multiranged.intersect.asset.stat_cat_entry.search.stat_cat';
    if ($self->api_name =~ /union/o) {
        $collector = ' UNION ';
        $entry_method = 'open-ils.storage.multiranged.union.asset.stat_cat_entry.search.stat_cat';
    }

    my $binds = join($collector, map { 'SELECT id FROM actor.org_unit_full_path(?)' } grep {defined} @$ous);
    $select =~ s/XXX/$binds/so;
    
        $fleshed = 0;
        $fleshed = 1 if ($self->api_name =~ /fleshed/o);

        my $sth = asset::stat_cat->db_Main->prepare_cached($select);
        $sth->execute(map { "$_" } grep {defined} @$ous);

        for my $sc ( map { asset::stat_cat->construct($_) } $sth->fetchall_hash ) {
                my $sc_fm = $sc->to_fieldmapper;
                $sc_fm->entries(
                        [ $self->method_lookup( $entry_method )->run($ous, $sc->id) ]
                ) if ($fleshed);
                $client->respond( $sc_fm );
        }

        return undef;
}
__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.multiranged.intersect.fleshed.asset.stat_cat.all',
        api_level       => 1,
        stream          => 1,
        method          => 'multiranged_asset_stat_cat',
);
__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.multiranged.union.fleshed.asset.stat_cat.all',
        api_level       => 1,
        stream          => 1,
        method          => 'multiranged_asset_stat_cat',
);

#XXX Fix stored proc calls
sub ranged_asset_stat_cat_entry {
        my $self = shift;
        my $client = shift;
        my $ou = ''.shift();
        my $sc = ''.shift();

        return undef unless ($ou);
        my $s_table = asset::stat_cat_entry->table;

        my $select = <<"        SQL";
                SELECT  s.*
                  FROM  $s_table s
                        JOIN actor.org_unit_full_path(?) p ON (p.id = s.owner)
                  WHERE stat_cat = ?
                  ORDER BY name
        SQL

        my $sth = asset::stat_cat->db_Main->prepare_cached($select);
        $sth->execute($ou,$sc);

        for my $sce ( map { asset::stat_cat_entry->construct($_) } $sth->fetchall_hash ) {
                $client->respond( $sce->to_fieldmapper );
        }

        return undef;
}
__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.ranged.asset.stat_cat_entry.search.stat_cat',
        api_level       => 1,
        stream          => 1,
        method          => 'ranged_asset_stat_cat_entry',
);

#XXX Fix stored proc calls
sub multiranged_asset_stat_cat_entry {
        my $self = shift;
        my $client = shift;
        my $ous = shift;
        my $sc = ''.shift();

        return undef unless (defined($ous) and @$ous);
        my $s_table = asset::stat_cat_entry->table;

    my $collector = ' INTERSECT ';
    $collector = ' UNION ' if ($self->api_name =~ /union/o);

        my $select = <<"        SQL";
                SELECT  s.*
                  FROM  $s_table s
          WHERE s.owner IN ( XXX ) and s.stat_cat = ?
                  ORDER BY value
        SQL

    my $binds = join($collector, map { 'SELECT id FROM actor.org_unit_full_path(?)' } grep {defined} @$ous);
    $select =~ s/XXX/$binds/so;
    
        my $sth = asset::stat_cat->db_Main->prepare_cached($select);
        $sth->execute(map {"$_"} @$ous,$sc);

        for my $sce ( map { asset::stat_cat_entry->construct($_) } $sth->fetchall_hash ) {
                $client->respond( $sce->to_fieldmapper );
        }

        return undef;
}
__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.multiranged.intersect.asset.stat_cat_entry.search.stat_cat',
        api_level       => 1,
        stream          => 1,
        method          => 'multiranged_asset_stat_cat_entry',
);
__PACKAGE__->register_method(
        api_name        => 'open-ils.storage.multiranged.union.asset.stat_cat_entry.search.stat_cat',
        api_level       => 1,
        stream          => 1,
        method          => 'multiranged_asset_stat_cat_entry',
);


sub cn_ranged_tree {
    my $self = shift;
    my $client = shift;
    my $cn = shift;
    my $ou = shift;
    my $depth = shift || 0;

    my $ou_list =
        actor::org_unit
            ->db_Main
            ->selectcol_arrayref(
                'SELECT id FROM actor.org_unit WHERE id NOT IN (SELECT id  FROM actor.org_unit_descendants(?,?))',
                {},
                $ou,
                $depth
            );

    return undef unless ($ou_list and @$ou_list);

    $cn = asset::call_number->retrieve( $cn );
    return undef unless ($cn);
    return undef if ($cn->deleted);

    my $call_number = $cn->to_fieldmapper;
    $call_number->copies([]);

    $call_number->record( $cn->record->to_fieldmapper );
    $call_number->record->fixed_fields( $cn->record->record_descriptor->next->to_fieldmapper );

    for my $cp ( $cn->copies(circ_lib => $ou_list) ) {
        next if ($cp->deleted);
        my $copy = $cp->to_fieldmapper;
        $copy->status( $cp->status->to_fieldmapper );
        $copy->location( $cp->location->to_fieldmapper );

        push @{ $call_number->copies }, $copy;
    }

    return $call_number;
}
__PACKAGE__->register_method(
    api_name    => 'open-ils.storage.asset.call_number.ranged_tree',
    method      => 'cn_ranged_tree',
    argc        => 1,
    api_level   => 1,
);


# XXX Since this is all we need in open-ils.storage for serial stuff ATM, just
# XXX putting it here instead of creating a whole new file.
sub issuance_ranged_tree {
    my $self = shift;
    my $client = shift;
    my $iss = shift;
    my $ou = shift;
    my $depth = shift || 0;

    my $ou_list =
        actor::org_unit
            ->db_Main
            ->selectcol_arrayref(
                'SELECT id FROM actor.org_unit WHERE id NOT IN (SELECT id  FROM actor.org_unit_descendants(?,?))',
                {},
                $ou,
                $depth
            );

    return undef unless ($ou_list and @$ou_list);

    $iss = serial::issuance->retrieve( $iss );
    return undef unless ($iss);

    my $issuance = $iss->to_fieldmapper;
    $issuance->items([]);

    # Now, gather issuances on the same bib, with the same label and date_published ...
    my @subs = map { $_->id } serial::subscription->search( record_entry => $iss->subscription->record_entry->id );

    my @similar_iss = serial::issuance->search_where(
        subscription => \@subs,
        label => $iss->label,
        date_published => $iss->date_published
    );

    # ... and add all /their/ items to the target issuance
    for my $i ( @similar_iss ) {
        for my $it ( $i->items() ) {
            next unless $it->unit and not $it->unit->deleted;
            next unless (grep { $it->unit->circ_lib eq $_ } @$ou_list);
    
            my $unit = $it->unit->to_fieldmapper;
            $unit->status( $it->unit->status->to_fieldmapper );
            $unit->location( $it->unit->location->to_fieldmapper );

            my $item = $it->to_fieldmapper;
            $item->unit( $unit );
    
            push @{ $issuance->items }, $item;
        }
    }

    return $issuance;
}
__PACKAGE__->register_method(
    api_name    => 'open-ils.storage.serial.issuance.ranged_tree',
    method      => 'issuance_ranged_tree',
    argc        => 1,
    api_level   => 1,
);

sub merge_record_assets {
    my $self = shift;
    my $client = shift;
    my $target = shift;
    my @sources = @_;

    my $count = 0;
    for my $source ( @sources ) {
        $count += asset::call_number
                ->db_Main
                ->selectcol_arrayref(
                    "SELECT asset.merge_record_assets(?,?);",
                    {},
                    $target,
                    $source
                )->[0];
    }

    return $count;
}
__PACKAGE__->register_method(
    api_name    => 'open-ils.storage.asset.merge_record_assets',
    method      => 'merge_record_assets',
    argc        => 2,
    api_level   => 1,
);

1;
