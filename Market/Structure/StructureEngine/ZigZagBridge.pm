package Market::Structure::StructureEngine;

# =============================================================================
# StructureEngine::ZigZagBridge
# =============================================================================
# Sync/build de engines ZigZag internos/externos.
# Continuacion del paquete Market::Structure::StructureEngine (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _sync_zigzag_engines {
    my ( $self, $market_data, $target_index ) = @_;
    return unless $market_data && defined $target_index && $target_index >= 0;

    if ( defined $self->{_zigzag_synced_to}
        && $self->{_zigzag_synced_to} > $target_index )
    {
        $self->{zigzag_internal}->reset() if $self->{zigzag_internal};
        $self->{zigzag_external}->reset() if $self->{zigzag_external};
        $self->{_zigzag_synced_to} = -1;
    }

    my $from = ( $self->{_zigzag_synced_to} // -1 ) + 1;
    $from = 0 if $from < 0;

    for my $i ( $from .. $target_index ) {
        my $c = $market_data->get_candle($i);
        next unless $c;
        $self->{zigzag_internal}->update_at_index( $market_data, $i )
            if $self->{zigzag_internal};
        $self->{zigzag_external}->update_at_index( $market_data, $i )
            if $self->{zigzag_external};
    }

    $self->{_zigzag_synced_to} = $target_index;

    $self->{_zigzag_tentative} = {
        internal => $self->{zigzag_internal}
            ? $self->{zigzag_internal}->get_tentative_segment()
            : undef,
        external => $self->{zigzag_external}
            ? $self->{zigzag_external}->get_tentative_segment()
            : undef,
    };
    return $self;
}

sub _zigzag_engine_for {
    my ( $self, $profile ) = @_;
    return $profile eq 'internal'
        ? $self->{zigzag_internal}
        : $self->{zigzag_external};
}

sub _build_zigzag_from_engine {
    my ( $self, $tol, %args ) = @_;
    my $profile = $args{profile} || 'external';
    $self->{_structural_filter_metadata} = {};
    $self->{_zigzag_metadata} ||= {};

    my $engine = $self->_zigzag_engine_for($profile);
    return [] unless $engine;

    my $source_swings = [];
    if ($engine->can('pivots_as_swings')) {
        $source_swings = $engine->pivots_as_swings();
    }
    elsif ($engine->can('get_swings')) {
        $source_swings = $engine->get_swings();
    }
    elsif ($engine->can('get_pivots')) {
        $source_swings = $engine->get_pivots();
    }
    return [] unless $source_swings && @$source_swings;

    my @filtered = map { 
        my $s = +{%$_};
        # Ensure type is set if only kind is provided
        if (!defined $s->{type} && defined $s->{kind}) {
            $s->{type} = ($s->{kind} eq 'H') ? 'swing_high' : 'swing_low';
        }
        $s;
    } @$source_swings;
    for my $i (0 .. $#filtered) {
        my $s = $filtered[$i];
        $s->{prominence} = _pivot_prominence(\@filtered, $i);
        $s->{distance} = _adjacent_distance(\@filtered, $i);
        $s->{depth} = _swing_depth(\@filtered, $i);
        $s->{structurally_confirmed} = ($i > 0 && $i < $#filtered) ? 1 : 0;
    }

    my %hierarchy_thresholds = _hierarchy_thresholds($tol, @filtered);
    for my $s (@filtered) {
        $s->{structure_rank} = _swing_hierarchy(
            $profile,
            $s->{prominence},
            $s->{distance},
            $s->{depth},
            $s->{structurally_confirmed},
            \%hierarchy_thresholds,
        );
    }

    my $metadata;
    if ( $profile eq 'internal' && $engine->isa('Market::Indicators::ZigZagMTF') ) {
        $metadata = {
            algorithm            => 'zzmtf_pivothigh_pivotlow',
            resolution_minutes   => $engine->{resolution_minutes}
                // Market::Indicators::ZigZagMTF::DEFAULT_RESOLUTION_MINUTES(),
            period               => $engine->{period}
                // Market::Indicators::ZigZagMTF::DEFAULT_PERIOD(),
            pivot_count          => scalar(@filtered),
            intermediate_prominence => $hierarchy_thresholds{intermediate},
            major_prominence        => $hierarchy_thresholds{major},
            tolerance_floor      => $tol,
        };
    }
    elsif ( $profile eq 'external' && $engine->isa('Market::Indicators::ZigZagVolumeProfile') ) {
        $metadata = {
            algorithm            => 'zzvp_deviation_fsm',
            deviation_pct        => $engine->{deviation_pct}
                // Market::Indicators::ZigZagVolumeProfile::DEFAULT_DEVIATION_PCT(),
            pivot_count          => scalar(@filtered),
            intermediate_prominence => $hierarchy_thresholds{intermediate},
            major_prominence        => $hierarchy_thresholds{major},
            tolerance_floor      => $tol,
        };
    }
    elsif ( $profile eq 'external' && $engine->isa('Market::Indicators::ZigZagVolumeProfile2') ) {
        # ZZVP2: motor alternativo (ventana highest/lowest, replica
        # "ChartPrime"), seleccionable via
        # StructureEngine->new(zigzag_external => ZigZagVolumeProfile2->new(...))
        # sin tocar el resto de esta clase.
        $metadata = {
            algorithm            => 'zzvp2_window_swing',
            swing_length         => $engine->{swing_length}         // 150,
            channel_width_factor => $engine->{channel_width_factor} // 1,
            atr_period           => $engine->{atr_period}           // 200,
            pivot_count          => scalar(@filtered),
            intermediate_prominence => $hierarchy_thresholds{intermediate},
            major_prominence        => $hierarchy_thresholds{major},
            tolerance_floor      => $tol,
        };
    }
    else {
        $metadata = {
            algorithm            => 'zigzag_engine',
            pivot_count          => scalar(@filtered),
            intermediate_prominence => $hierarchy_thresholds{intermediate},
            major_prominence        => $hierarchy_thresholds{major},
            tolerance_floor      => $tol,
        };
    }
    $self->{_zigzag_metadata}{$profile} = $metadata;
    $self->{_structural_filter_metadata} = $metadata if $profile eq 'external';

    return \@filtered;
}


1;
