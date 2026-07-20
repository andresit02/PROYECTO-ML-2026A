package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::LegacyRegistry
# =============================================================================
# Retrocompatibilidad: construye EngineRegistry desde args legacy de new().
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

sub _build_legacy_engine_registry {
    my ($indicator_manager, %args) = @_;

    require Market::Core::EngineRegistry;
    require Market::Indicators::Liquidity;
    require Market::Concepts::FVGEngine;
    require Market::Concepts::OrderBlockEngine;
    require Market::Concepts::SMCStructureEngine;
    require Market::Volume::VolumeProfileEngine;
    require Market::Volume::AnchoredVWAP;
    require Market::Concepts::FibonacciEngine;
    require Market::Strategies::Indicators::SupplyDemand;
    require Market::Indicators::TrendChannel;
    require Market::Indicators::TrailingExtremes;
    require Market::Concepts::PremiumDiscountZones;
    require Market::Concepts::MTFLevels;

    my $registry = Market::Core::EngineRegistry->new();

    my $atr_indicator = ($indicator_manager && $indicator_manager->can('get'))
        ? $indicator_manager->get('atr') : undef;

    my $liquidity_engine = $args{liquidity_engine}
        || Market::Indicators::Liquidity->new(atr_indicator => $atr_indicator);
    $registry->register('liquidity', $liquidity_engine);

    my $smc_structure_engine = $args{smc_structure_engine}
        || Market::Concepts::SMCStructureEngine->new(
            swing_length    => $args{smc_swing_length}    // 50,
            internal_length => $args{smc_internal_length} //  5,
            eq_length       => $args{smc_eq_length}       //  3,
            eq_threshold    => $args{smc_eq_threshold}    //  0.1,
        );
    $registry->register('smc_structure', $smc_structure_engine);

    my $fvg_eng = $args{fvg_engine} || Market::Concepts::FVGEngine->new();
    $registry->register('fvg', $fvg_eng,
        calc => sub {
            my ($eng, $market_data, $cache, %a) = @_;
            return $eng->calculate($market_data, $smc_structure_engine, %a);
        },
    );

    my $ob_eng = $args{orderblock_engine} || Market::Concepts::OrderBlockEngine->new();
    $registry->register('orderblock', $ob_eng,
        calc => sub {
            my ($eng, $market_data, $cache, %a) = @_;
            return $eng->calculate($market_data, $cache->{smc_structure}, %a);
        },
    );

    my $fib_eng = $args{fibonacci_engine} || Market::Concepts::FibonacciEngine->new();
    $registry->register('fibonacci', $fib_eng,
        calc => sub {
            my ($eng, $market_data, $cache, %a) = @_;
            return $eng->calculate($market_data, $cache->{smc_structure}, %a);
        },
    );

    my $tc_eng = $args{trend_channel_engine} || Market::Indicators::TrendChannel->new();
    $registry->register('trend_channel', $tc_eng,
        calc => sub {
            my ($eng, $market_data, $cache, %a) = @_;
            my $smc = $cache->{smc_structure} || {};
            my @raw = (@{ $smc->{swing_highs} || [] }, @{ $smc->{swing_lows} || [] });
            my @sw = map {
                my $s = $_;
                my $lbl = $s->{label} // '';
                { index => $s->{index}, price => $s->{level},
                  type => ($lbl eq 'HH' || $lbl eq 'LH') ? 'high' : 'low',
                  label => $lbl }
            } grep { ref $_ eq 'HASH' && defined $_->{index} && defined $_->{level} } @raw;
            return $eng->calculate($market_data, source_swings => \@sw, %a);
        },
    );

    my $te_eng = $args{trailing_extremes_engine} || Market::Indicators::TrailingExtremes->new();
    $registry->register('trailing_extremes', $te_eng,
        calc => sub {
            my ($eng, $market_data, $cache, %a) = @_;
            return $eng->calculate($market_data, $cache->{smc_structure}, %a);
        },
    );

    my $pd_eng = $args{premium_discount_engine} || Market::Concepts::PremiumDiscountZones->new();
    $registry->register('premium_discount', $pd_eng,
        calc => sub {
            my ($eng, $market_data, $cache, %a) = @_;
            return $eng->calculate($market_data, $cache->{trailing_extremes}, %a);
        },
    );

    my $vp_eng = $args{volume_profile_engine} || Market::Volume::VolumeProfileEngine->new();
    $registry->register('volume_profile', $vp_eng);

    my $avwap_eng = $args{anchored_vwap} || Market::Volume::AnchoredVWAP->new();
    $registry->register('anchored_vwap', $avwap_eng);

    my $sd_eng = $args{supply_demand_engine} || Market::Strategies::Indicators::SupplyDemand->new();
    $registry->register('supply_demand', $sd_eng,
        calc => sub {
            my ($eng, $market_data, $cache, %a) = @_;
            my $result = $eng->calculate($market_data, %a);
            return { active => $result->{zones} };
        },
    );

    my $mtf_eng = $args{mtf_levels_engine} || Market::Concepts::MTFLevels->new();
    $registry->register('mtf_levels', $mtf_eng);

    return $registry;
}


1;
