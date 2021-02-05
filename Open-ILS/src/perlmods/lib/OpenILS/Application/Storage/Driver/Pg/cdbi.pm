{ # Based on the change to Class::DBI in OpenILS::Application::Storage.  This will
  # allow us to use TSearch2 via a simple cdbi "search" interface.
    #-------------------------------------------------------------------------------
    use UNIVERSAL::require; 
    BEGIN {                 
        'Class::DBI::Frozen::301'->use or 'Class::DBI'->use or die $@;
    }     
    package Class::DBI;

    sub search_fts {
        my $self = shift;
        my @args = @_;

        if (ref($args[-1]) eq 'HASH' && @args > 1) {
            $args[-1]->{_placeholder} = "to_tsquery('default',?)";
        } else {
            push @args, {_placeholder => "to_tsquery('default',?)"};
        }
        
        $self->_do_search("@@"  => @args);
    }

    sub search_regex {
        my $self = shift;
        my @args = @_;
        $self->_do_search("~*"  => @args);
    }

    sub search_ilike {
        my $self = shift;
        my @args = @_;
        $self->_do_search("ILIKE"  => @args);
    }

}

1;
