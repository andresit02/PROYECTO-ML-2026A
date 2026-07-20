#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use lib 'tools'; # For mock Tk.pm

use Market::MarketData;
use Market::ChartEngine;
use Market::Core::OverlaySettings;

package MockCanvas;
sub new { bless { drawn => {} }, shift }
sub createRectangle { shift->{drawn}{rect}++ }
sub createLine { shift->{drawn}{line}++ }
sub createText { shift->{drawn}{text}++ }
sub createPolygon { shift->{drawn}{poly}++ }
sub createOval { shift->{drawn}{oval}++ }
sub delete {}
sub raise {}
sub bbox { return (0,0,10,10) }
sub itemconfigure {}
sub find { return () }

package MockScale;
sub new {
    my ($class, %args) = @_;
    bless {
        min_val      => $args{min_val} // 90000,
        max_val      => $args{max_val} // 100000,
        height       => $args{height}  // 1000,
        candle_width => $args{cw}      // 8,
        offset       => $args{offset}  // 0,
        visible_bars => $args{vb}      // 500,
    }, $class;
}
sub index_to_center_x {
    my ($self, $idx) = @_;
    return ($idx - $self->{offset}) * $self->{candle_width};
}
sub index_to_x {
    my ($self, $idx) = @_;
    return ($idx - $self->{offset}) * $self->{candle_width};
}
sub value_to_y {
    my ($self, $val) = @_;
    my $range = $self->{max_val} - $self->{min_val};
    return 0 unless $range > 0;
    # Invertido: precio max -> y=0 (arriba), precio min -> y=height (abajo)
    return $self->{height} * (1 - ($val - $self->{min_val}) / $range);
}
sub value_in_range {
    my ($self, $val) = @_;
    return 0 unless defined $val;
    return ($val >= $self->{min_val} && $val <= $self->{max_val}) ? 1 : 0;
}
sub _plot_w { return $_[0]->{visible_bars} * $_[0]->{candle_width} }
sub _draw_y_scale {}

package main;

my $md = Market::MarketData->new();
my $csv_file = 'data/2026_03.csv';
open my $fh, '<', $csv_file or die "Cannot open $csv_file: $!";
my $header = <$fh>;
my $idx = 0;
while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /\S/;
    my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;
    my $ts = $idx++;
    $md->add_candle({
        timestamp => $ts,
        open      => $open  + 0,
        high      => $high  + 0,
        low       => $low   + 0,
        close     => $close + 0,
        volume    => $volume + 0,
    });
}
close $fh;

print "Loaded " . $md->size() . " candles.\n";

my $settings = Market::Core::OverlaySettings->new();
$settings->set('show_fvg', 1);
$settings->set('show_orderblocks', 1);
$settings->set('show_liquidity_levels', 1);
$settings->set('show_internal_swings', 1);

# Cargamos el CSV y buscamos el rango de precios para calibrar el MockScale
my @all_prices;
my @all_data;
open my $fh2, '<', $csv_file or die "Cannot open $csv_file: $!";
my $hdr2 = <$fh2>;
while (my $line = <$fh2>) {
    chomp $line;
    next unless $line =~ /\S/;
    my ($ts, $o, $h, $l, $c, $vol) = split /,/, $line;
    push @all_prices, $h+0, $l+0;
    push @all_data, [$o+0, $h+0, $l+0, $c+0, $vol+0];
}
close $fh2;
my $price_min = (sort { $a <=> $b } @all_prices)[0];
my $price_max = (sort { $b <=> $a } @all_prices)[0];
# Usar ventana central de 500 velas (donde esperamos ver datos)
my $total_candles = scalar @all_data;
my $view_start = int($total_candles * 0.6);  # 60% del dataset
my $view_end   = $view_start + 499;
$view_end = $total_candles - 1 if $view_end >= $total_candles;
# Rango de precios en la ventana visible
my @win_prices;
for my $i ($view_start .. $view_end) {
    push @win_prices, $all_data[$i][1], $all_data[$i][2] if $all_data[$i];
}
my $win_min = (sort { $a <=> $b } @win_prices)[0] // $price_min;
my $win_max = (sort { $b <=> $a } @win_prices)[0] // $price_max;
my $margin = ($win_max - $win_min) * 0.05;
$win_min -= $margin;
$win_max += $margin;

my $mock_scale = MockScale->new(
    min_val => $win_min,
    max_val => $win_max,
    height  => 1000,
    cw      => 8,
    offset  => $view_start,
    vb      => $view_end - $view_start + 1,
);

my $chart = Market::ChartEngine->new(
    market_data      => $md,
    canvas           => MockCanvas->new(),
    price_scale      => $mock_scale,
    price_height     => 1000,
    width            => ($view_end - $view_start + 1) * 8,
    overlay_settings => $settings,
);

$chart->{start_idx} = $view_start;
$chart->{end_idx}   = $view_end;

$chart->rebuild_analysis_cache();

my $cache = $chart->{analysis_cache};

print "\n--- CACHE ---\n";
for my $k (sort keys %$cache) {
    my $count = 0;
    my $data = $cache->{$k};
    if (ref($data) eq 'HASH') {
        if ($data->{gaps}) { $count = scalar(@{$data->{gaps}}); }
        elsif ($data->{blocks}) { $count = scalar(@{$data->{blocks}}); }
        elsif ($data->{levels}) { $count = scalar(@{$data->{levels}}); }
        elsif ($data->{swings}) { $count = scalar(@{$data->{swings}}); }
        elsif ($data->{active}) { $count = scalar(@{$data->{active}}); }
        elsif ($data->{zones}) { $count = scalar(@{$data->{zones}}); }
    }
    print sprintf("%-15s : %d items in cache\n", $k, $count);
}

$chart->_register_overlays();
$chart->_sync_overlay_layer_state();
$chart->_prepare_overlay_data();

print "\n--- OVERLAY MANAGER ---\n";
for my $k (sort keys %$cache) {
    my $overlay = $chart->{overlay_manager}->get($k);
    if ($overlay) {
        my $data = $overlay->{data};
        my $count = 0;
        if (ref($data) eq 'HASH') {
            if ($data->{gaps}) { $count = scalar(@{$data->{gaps}}); }
            elsif ($data->{blocks}) { $count = scalar(@{$data->{blocks}}); }
            elsif ($data->{levels}) { $count = scalar(@{$data->{levels}}); }
            elsif ($data->{swings}) { $count = scalar(@{$data->{swings}}); }
            elsif ($data->{active}) { $count = scalar(@{$data->{active}}); }
            elsif ($data->{zones}) { $count = scalar(@{$data->{zones}}); }
        }
        print sprintf("%-15s : %d items, Enabled: %d\n", $k, $count, $chart->{overlay_manager}->is_enabled($k));
    } else {
        print sprintf("%-15s : NOT registered\n", $k);
    }
}

print "\n--- RENDER ---\n";
$chart->_draw_overlays();

for my $k (sort keys %$cache) {
    my $overlay = $chart->{overlay_manager}->get($k);
    if ($overlay) {
        my $audit = $overlay->{smc_audit} || {};
        my $rendered = $audit->{rendered} // 0;
        my $received = $audit->{total_received} // 0;
        print sprintf("%-15s : Rendered %d / Received %d\n", $k, $rendered, $received);
        if ($k eq 'fvg' || $k eq 'structure' || $k eq 'orderblock' || $k eq 'liquidity') {
            use Data::Dumper;
            print Dumper($audit);
        }
    }
}
