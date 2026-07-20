#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use lib "$FindBin::Bin"; # For mock Tk.pm
use Test::More;

use Market::ChartEngine;
use Market::Indicators::Liquidity;

{
    package Local::MarketData;
    sub new {
        my ($class) = @_;
        my @candles = map {
            +{
                open => 100,
                high => $_ == 5 || $_ == 12 ? 110 : 102,
                low => $_ == 8 || $_ == 18 ? 90 : 98,
                close => 100,
                volume => 1,
                timestamp => $_,
            }
        } 0 .. 24;
        return bless { candles => \@candles }, $class;
    }
    sub size { scalar @{ $_[0]->{candles} } }
    sub get_candle { $_[0]->{candles}[ $_[1] ] }
    sub active_tf { '1m' }
}

my $liquidity = Market::Indicators::Liquidity->new(k => 1, tolerance => 100);
my $liq_data = $liquidity->calculate(Local::MarketData->new());
is_deeply($liq_data->{eq_levels}, [], 'Liquidity engine no longer emits internal EQH/EQL levels');

my $chart = bless {}, 'Market::ChartEngine';
my $mapped = $chart->_eq_levels_from_smc_structure({
    eqh => [
        {
            index => 15,
            swing_index => 12,
            level => 110,
            start_index => 15,
            end_index => 21,
            is_open => 0,
        },
    ],
    eql => [
        {
            index => 20,
            swing_index => 18,
            level => 90,
            start_index => 20,
            end_index => 24,
            is_open => 1,
        },
    ],
});

is(scalar @$mapped, 2, 'SMC EQH/EQL events are mapped into overlay eq_levels');
is_deeply(
    $mapped->[0],
    {
        first_index  => 12,
        second_index => 15,
        level        => 110,
        type         => 'EQH',
        start_index  => 15,
        end_index    => 21,
        is_open      => 0,
        source       => 'SMCStructureEngine',
    },
    'EQH shape uses swing_index/index and preserves real end_index',
);
is($mapped->[1]{source}, 'SMCStructureEngine', 'EQL source is SMCStructureEngine');
is($mapped->[1]{end_index}, 24, 'EQL preserves open projection end_index');

done_testing();
