package Market::Structure::StructureEngine;

# =============================================================================
# StructureEngine::Finalize
# =============================================================================
# Finalizacion y clasificacion de swings desde ZigZag.
# Continuacion del paquete Market::Structure::StructureEngine (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _finalize_structure_from_zigzag {
    my ( $self, $candles, $last_index, $visible_limit, $tol, %meta ) = @_;

    my $internal_source_swings = $self->_build_zigzag_from_engine( $tol, profile => 'internal' );
    my $external_source_swings = $self->_build_zigzag_from_engine( $tol, profile => 'external' );

    my $internal_swings = $self->_classify_zigzag_swings(
        $internal_source_swings, $visible_limit, $tol, 'internal'
    );
    my $external_swings = $self->_classify_zigzag_swings(
        $external_source_swings, $visible_limit, $tol, 'external'
    );

    $self->_assign_swing_scopes($external_swings);
    $self->_reclassify_vs_external( $external_swings, $tol );
    $self->_assign_swing_scopes($external_swings);
    for my $s (@$external_swings) { $s->{scope} = 'external'; }
    for my $s (@$internal_swings) { $s->{scope} = 'internal'; }

    $self->{swings}          = $external_swings;
    $self->{internal_swings} = $internal_swings;
    $self->{external_swings} = $external_swings;
    $self->{trend}           = $self->_derive_trend($external_swings);

    my $break_seq = $self->_scan_structure_breaks(
        $external_swings, $candles, $last_index, scope => 'external'
    );
    my $micro_break_seq = $self->_scan_structure_breaks(
        $internal_swings, $candles, $last_index, scope => 'internal'
    );
    push @$break_seq, @$micro_break_seq;
    $self->{breaks}  = $self->{bos_detector}->detect($break_seq);
    $self->{changes} = $self->{choch_detector}->detect($break_seq);

    $self->{metadata} = {
        timeframe       => $meta{timeframe} || 'unknown',
        raw_swing_count => $meta{raw_swing_count} // 0,
        candidate_count => $meta{raw_swing_count} // 0,
        internal_count  => scalar(@$internal_swings),
        swing_count     => scalar(@$external_swings),
        external_count  => scalar(@$external_swings),
        visible_limit   => $visible_limit,
        bos_count       => scalar( @{ $self->{breaks} } ),
        choch_count     => scalar( @{ $self->{changes} } ),
        tolerance       => $tol,
        structural_filter => $self->{_structural_filter_metadata} || {},
        zigzag          => $self->{_zigzag_metadata} || {},
        zigzag_tentative => $self->{_zigzag_tentative} || {},
        show_internal   => 0,
    };

    return {
        swings          => $self->{swings},
        internal_swings => $self->{internal_swings},
        external_swings => $self->{external_swings},
        trend           => $self->{trend},
        breaks          => $self->{breaks},
        changes         => $self->{changes},
        metadata        => $self->{metadata},
    };
}

sub _classify_zigzag_swings {
    my ($self, $source_swings, $visible_limit, $tol, $scope) = @_;
    my $swings = [];
    return $swings unless $source_swings && ref $source_swings eq 'ARRAY';

    for my $swing (@$source_swings) {
        next if defined $visible_limit && $swing->{index} > $visible_limit;
        my $st = $swing->{type} || '';
        my $class = $self->_classify_swing($swings, $swing, $tol);
        push @$swings, {
            index       => $swing->{index},
            price       => $swing->{price},
            previous    => $swing->{previous},
            source_type => $st,
            kind        => ($st eq 'swing_high' ? 'high' : 'low'),
            type        => $class,
            label       => $self->_swing_label($class),
            zigzag      => $scope,
            prominence  => $swing->{prominence},
            distance    => $swing->{distance},
            depth       => $swing->{depth},
            structurally_confirmed => $swing->{structurally_confirmed},
            hierarchy   => $swing->{structure_rank}
                || 'Minor',
        };
    }

    return $swings;
}


1;
