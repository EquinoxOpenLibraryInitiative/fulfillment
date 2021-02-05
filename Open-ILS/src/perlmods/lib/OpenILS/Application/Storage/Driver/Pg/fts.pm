{ # Every driver needs to provide a 'compile()' method to OpenILS::Application::Storage::FTS.
  # If that driver wants to support FTI, that is...
    #-------------------------------------------------------------------------------
    package OpenILS::Application::Storage::FTS;
    use OpenSRF::Utils::Logger qw/:level/;
    use Unicode::Normalize;
    my $log = 'OpenSRF::Utils::Logger';

    sub compile {
        my $self = shift;
        my $class = shift;
        my $term = NFD(shift());

        $log->debug("Raw term: $term",DEBUG);
        $log->debug("Search class: $class",DEBUG);

        $term =~ s/\&//go;
        $term =~ s/\|//go;

        $self = ref($self) || $self;
        $self = bless {} => $self;
        $self->{class} = $class;

        $term =~ s/(\pM+)//gos;
        $term =~ s/(\b\.\b)//gos;

        # hack to normalize ratio-like strings
        while ($term =~ /\b\d{1}:[, ]?\d+(?:[ ,]\d+[^:])+/o) {
            $term = $` . join ('', split(/[, ]/, $&)) . $';
        }

        $self->decompose($term);

        my $newterm = '';
        $newterm = join('&', $self->words) if ($self->words);

        if (@{$self->nots}) {
            $newterm = '('.$newterm.')&' if ($newterm);
            $newterm .= '!('. join('|', $self->nots) . ')';
        }

        $log->debug("Compiled term is [$newterm]", DEBUG);
        $newterm = OpenILS::Application::Storage::Driver::Pg->quote($newterm);
        $log->debug("Quoted term is [$newterm]", DEBUG);

        $self->{fts_query} = ["to_tsquery('$$self{class}',$newterm)"];
        $self->{fts_query_nots} = [];
        $self->{fts_op} = '@@';
        $self->{text_col} = shift;
        $self->{fts_col} = shift;

        return $self;
    }

    sub sql_where_clause {
        my $self = shift;
        my $column = $self->fts_col;
        my @output;
    
        my @ranks;
        for my $fts ( $self->fts_query ) {
            push @output, join(' ', $self->fts_col, $self->{fts_op}, $fts);
            push @ranks, "ts_rank($column, $fts)";
        }
        $self->{fts_rank} = \@ranks;
    
        my $phrase_match = $self->sql_exact_phrase_match();
        return join(' AND ', @output) . $phrase_match;
    }

    sub sql_exact_phrase_match {
        my $self = shift;
        my $column = $self->text_col;
        my $output = '';
        for my $phrase ( $self->phrases ) {
            $phrase =~ s/\*/\\*/go;
            $phrase =~ s/\./\\./go;
            $phrase =~ s/'/\\'/go;
            $phrase =~ s/\s+/\\s+/go;
            $log->debug("Adding phrase [$phrase] to the match list", DEBUG);
            $output .= " AND $column ~* \$\$(^|\\W+)$phrase(\\W+|\$)\$\$";
        }
        $log->debug("Phrase list is [$output]", DEBUG);
        return $output;
    }

}

1;
