#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More;

use Market::Indicators::TrendChannel;

{
    package Local::MarketData;
    sub new {
        my ($class, $size) = @_;
        my @candles = map {
            +{
                open => 105,
                high => 112,
                low => 98,
                close => 105,
                volume => 1,
                timestamp => $_,
            }
        } 0 .. $size - 1;
        return bless { candles => \@candles }, $class;
    }
    sub size { scalar @{ $_[0]->{candles} } }
    sub get_candle { $_[0]->{candles}[ $_[1] ] }
    sub active_tf { '1m' }
}

my $market_data = Local::MarketData->new(140);
my @swings;
for my $i (0 .. 15) {
    my $idx = 8 + ($i * 7);
    push @swings, {
        index => $idx,
        price => 100 + ($idx * 0.03) + (($i % 2) * 0.01),
        type  => 'low',
    };
    push @swings, {
        index => $idx + 3,
        price => 110 + (($idx + 3) * 0.03) + (($i % 2) * 0.01),
        type  => 'high',
    };
}

my $engine = Market::Indicators::TrendChannel->new();
my $max = Market::Indicators::TrendChannel::MAX_ACTIVE_CHANNELS();

my $first = $engine->calculate($market_data, end_index => 139, source_swings => \@swings);
ok(@{ $first->{channels} } <= $max, 'first calculation respects MAX_ACTIVE_CHANNELS');
my $stored_after_first = scalar @{ $engine->{channels} || [] };

for (1 .. 5) {
    my $again = $engine->calculate($market_data, end_index => 139, source_swings => \@swings);
    ok(@{ $again->{channels} } <= $max, "repeat $_ respects MAX_ACTIVE_CHANNELS");
}

is(scalar @{ $engine->{channels} || [] }, $stored_after_first, 'repeated calculate() does not grow channel state');

done_testing();
