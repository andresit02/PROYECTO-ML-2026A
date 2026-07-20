#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..');

use Market::MarketData;
use Market::Concepts::SMCStructureEngine;
use Market::Indicators::TrailingExtremes;
use Market::Concepts::PremiumDiscountZones;
use Market::Concepts::MTFLevels;

print "============================================================\n";
print "VERIFICANDO MOTORES FASE 2 (TrailingExtremes, PDZones, MTF) \n";
print "============================================================\n\n";

# 1. Crear MarketData falso con 10 velas de 1m, y agregar 1D
my $md = Market::MarketData->new();
for my $i (1..10) {
    $md->merge_delta_row({
        timestamp => $i * 60,
        open  => 10,
        high  => 10 + $i,     # subiendo de 11 a 20
        low   => 5 + $i,      # subiendo de 6 a 15
        close => 8 + $i,
        volume => 100,
    });
}
# Simulando data 1D (para MTFLevels)
$md->{data}{'1D'} = [
    { timestamp => 0, open => 5, high => 25, low => 2, close => 10 },
];
$md->{data}{'1W'} = [
    { timestamp => 0, open => 5, high => 30, low => 1, close => 10 },
];

print "[OK] MarketData creado con 10 velas (1m) y previas D/W.\n";

# 2. SMCStructureEngine mock data
my $smc_data = {
    swing_trend => 'bullish',
    swing_highs => [ { index => 5, level => 15, label => 'HH' } ],
    swing_lows  => [ { index => 2, level => 7,  label => 'HL' } ],
};

# 3. TrailingExtremes
my $trailing = Market::Indicators::TrailingExtremes->new();
my $te_data = $trailing->calculate($md, $smc_data);
print "TrailingExtremes:\n";
print "  Top:    $te_data->{top}{price} at $te_data->{top}{index} ($te_data->{top}{label})\n";
print "  Bottom: $te_data->{bottom}{price} at $te_data->{bottom}{index} ($te_data->{bottom}{label})\n";
print "  Trend:  $te_data->{swing_trend}\n";
if ($te_data->{top}{price} == 20 && $te_data->{bottom}{price} == 6) {
    print "  -> [PASS] Valores Top/Bottom correctos.\n";
} else {
    print "  -> [FAIL] Valores Top/Bottom incorrectos.\n";
}

# 4. PremiumDiscountZones
my $pdz = Market::Concepts::PremiumDiscountZones->new();
my $pdz_data = $pdz->calculate($md, $te_data);
print "\nPremiumDiscountZones:\n";
print "  Premium: $pdz_data->{premium}{low} - $pdz_data->{premium}{high}\n";
print "  Equilib: $pdz_data->{equilibrium}{low} - $pdz_data->{equilibrium}{high}\n";
print "  Discoun: $pdz_data->{discount}{low} - $pdz_data->{discount}{high}\n";
if ($pdz_data->{premium}{high} == 20 && $pdz_data->{discount}{low} == 6) {
    print "  -> [PASS] Zonas PD calculadas correctamente en base al rango.\n";
} else {
    print "  -> [FAIL] Zonas PD incorrectas.\n";
}

# 5. MTFLevels
my $mtf = Market::Concepts::MTFLevels->new();
my $mtf_data = $mtf->calculate($md);
print "\nMTFLevels:\n";
print "  Daily:  High=$mtf_data->{daily}{high} Low=$mtf_data->{daily}{low}\n";
print "  Weekly: High=$mtf_data->{weekly}{high} Low=$mtf_data->{weekly}{low}\n";
if ($mtf_data->{daily}{high} == 25 && $mtf_data->{weekly}{high} == 30) {
    print "  -> [PASS] Niveles MTF D/W leídos correctamente.\n";
} else {
    print "  -> [FAIL] Niveles MTF incorrectos.\n";
}

print "\nPruebas Fase 2 completadas.\n";
