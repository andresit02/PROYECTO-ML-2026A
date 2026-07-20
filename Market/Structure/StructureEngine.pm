package Market::Structure::StructureEngine;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Indicators::Liquidity;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagVolumeProfile;
use Market::Structure::BOSDetector;
use Market::Structure::CHOCHDetector;

sub new {
    my ($class, %args) = @_;
    my $self = {
        liquidity => $args{liquidity} || Market::Indicators::Liquidity->new(),
        bos_detector => $args{bos_detector} || Market::Structure::BOSDetector->new(),
        choch_detector => $args{choch_detector} || Market::Structure::CHOCHDetector->new(),
        zigzag_internal => $args{zigzag_internal}
            || Market::Indicators::ZigZagMTF->new(),
        zigzag_external => $args{zigzag_external}
            || Market::Indicators::ZigZagVolumeProfile->new(),
        _zigzag_synced_to => -1,
        swings => [],
        internal_swings => [],
        external_swings => [],
        trend => 'neutral',
        breaks => [],
        changes => [],
        metadata => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{swings} = [];
    $self->{internal_swings} = [];
    $self->{external_swings} = [];
    $self->{trend} = 'neutral';
    $self->{breaks} = [];
    $self->{changes} = [];
    $self->{metadata} = {};
    $self->{_zigzag_synced_to} = -1;
    $self->{zigzag_internal}->reset() if $self->{zigzag_internal};
    $self->{zigzag_external}->reset() if $self->{zigzag_external};
    $self->{liquidity}->reset() if $self->{liquidity} && $self->{liquidity}->can('reset');
    $self->{bos_detector}->reset() if $self->{bos_detector} && $self->{bos_detector}->can('reset');
    $self->{choch_detector}->reset() if $self->{choch_detector} && $self->{choch_detector}->can('reset');
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $replay_controller = $args{replay_controller};
    my $liquidity_result  = $args{liquidity_result};
    if (!$liquidity_result || ref $liquidity_result ne 'HASH') {
        $liquidity_result = $self->{liquidity}->calculate($market_data, %args);
    }
    my $total = $market_data->size();
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit : ($total - 1);

    my $candles = [];
    for (my $i = 0; $i <= $last_index; $i++) {
        my $c = $market_data->get_candle($i);
        push @$candles, $c if $c;
    }

    my $tol = 1e-6;
    if ($liquidity_result->{metadata} && defined $liquidity_result->{metadata}{tolerance}) {
        $tol = $liquidity_result->{metadata}{tolerance};
    }

    my $raw_source_swings = $liquidity_result->{swings} || [];
    $self->_sync_zigzag_engines( $market_data, $last_index );
    return $self->_finalize_structure_from_zigzag(
        $candles, $last_index, $visible_limit, $tol,
        timeframe       => $args{timeframe} || $market_data->active_tf(),
        raw_swing_count => scalar(@$raw_source_swings),
    );
}

# _scan_structure_breaks($swings, $candles, $last_index) -> \@events
# Solo swings con scope=external definen niveles de referencia para BOS/CHoCH.
sub _scan_structure_breaks {
    my ($self, $swings, $candles, $last_index, %args) = @_;
    my @events;
    return \@events unless $swings && @$swings && $candles && @$candles;
    my $scope = $args{scope} || 'external';

    my @sorted = sort { $a->{index} <=> $b->{index} }
        grep {
            ($_->{scope} // $scope) eq $scope
            && ($scope eq 'external' || (($_->{hierarchy} || '') ne 'Minor'))
        } @$swings;
    return \@events unless @sorted;

    my $si = 0;
    my ($rh, $rhi, $rh_hierarchy, $rl, $rli, $rl_hierarchy);
    my $trend = 0;
    my $id = 0;

    for (my $i = 0; $i <= $last_index; $i++) {
        while ($si <= $#sorted && $sorted[$si]{index} <= $i) {
            my $s = $sorted[$si];
            if ($s->{kind} eq 'high') {
                $rh = $s->{price}; $rhi = $s->{index}; $rh_hierarchy = $s->{hierarchy};
            }
            else {
                $rl = $s->{price}; $rli = $s->{index}; $rl_hierarchy = $s->{hierarchy};
            }
            $si++;
        }
        my $c = $candles->[$i];
        next unless $c;
        my $close = $c->{close};
        next unless defined $close;

        if (defined $rh && defined $rhi && $rhi < $i && $close > $rh) {
            my $kind = ($trend < 0) ? 'CHoCH' : 'BOS';
            push @events, {
                event_id     => ++$id,
                kind         => $kind,
                direction    => 'bullish',
                trend_before => $trend,
                level        => $rh,
                index        => $i,
                swing_index  => $rhi,
                scope        => $scope,
                hierarchy    => $rh_hierarchy,
            };
            $trend = 1;
            $rh = undef; $rhi = undef; $rh_hierarchy = undef;
        }
        elsif (defined $rl && defined $rli && $rli < $i && $close < $rl) {
            my $kind = ($trend > 0) ? 'CHoCH' : 'BOS';
            push @events, {
                event_id     => ++$id,
                kind         => $kind,
                direction    => 'bearish',
                trend_before => $trend,
                level        => $rl,
                index        => $i,
                swing_index  => $rli,
                scope        => $scope,
                hierarchy    => $rl_hierarchy,
            };
            $trend = -1;
            $rl = undef; $rli = undef; $rl_hierarchy = undef;
        }
    }
    return \@events;
}

sub structure {
    my ($self) = @_;
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
sub events { my ($self) = @_; return [ @{ $self->{breaks} }, @{ $self->{changes} } ]; }

# refresh_zigzag_structure($market_data, %args)
# Actualiza ZigZag incrementalmente hasta el indice actual (replay o live)
# y reconstruye swings/BOS/CHoCH sin recalcular Liquidity.
sub refresh_zigzag_structure {
    my ( $self, $market_data, %args ) = @_;
    return {} unless $market_data;

    my $replay_controller = $args{replay_controller};
    my $liquidity_result  = $args{liquidity_result};
    my $total = $market_data->size();
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = ( defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total )
        ? $visible_limit
        : ( $total - 1 );
    $last_index = 0 if $last_index < 0;

    my $candles = [];
    for ( my $i = 0 ; $i <= $last_index ; $i++ ) {
        my $c = $market_data->get_candle($i);
        push @$candles, $c if $c;
    }

    my $tol = 1e-6;
    if ( $liquidity_result
        && $liquidity_result->{metadata}
        && defined $liquidity_result->{metadata}{tolerance} )
    {
        $tol = $liquidity_result->{metadata}{tolerance};
    }
    elsif ( $self->{metadata} && defined $self->{metadata}{tolerance} ) {
        $tol = $self->{metadata}{tolerance};
    }

    $self->_sync_zigzag_engines( $market_data, $last_index );
    return $self->_finalize_structure_from_zigzag(
        $candles, $last_index, $visible_limit, $tol,
        timeframe => $args{timeframe} || $market_data->active_tf(),
        raw_swing_count => $liquidity_result
        ? scalar( @{ $liquidity_result->{swings} || [] } )
        : ( $self->{metadata}{raw_swing_count} // 0 ),
    );
}

sub _filter_structural_swings {
    my ($self, $source_swings, $candles, $tol) = @_;
    return $self->_build_zigzag_from_engine( $tol, profile => 'external' );
}

sub _swing_candidates {
    my ($self, $source_swings) = @_;
    return [] unless $source_swings && ref $source_swings eq 'ARRAY' && @$source_swings;

    return [
        sort { ($a->{index} // 0) <=> ($b->{index} // 0) }
        grep {
            $_ && ref $_ eq 'HASH'
            && defined $_->{index}
            && defined $_->{price}
            && (($_->{type} || '') eq 'swing_high' || ($_->{type} || '') eq 'swing_low')
        } @$source_swings
    ];
}

# Modulos SRP de Market::Structure::StructureEngine (misma API).
require 'Market/Structure/StructureEngine/ZigZagBridge.pm';
require 'Market/Structure/StructureEngine/Finalize.pm';
require 'Market/Structure/StructureEngine/Metrics.pm';

1;
