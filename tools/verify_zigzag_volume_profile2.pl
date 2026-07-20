#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";

use Market::Indicators::ZigZagVolumeProfile2;
use Market::Structure::StructureEngine;
use Market::Indicators::Liquidity;

package _FakeMD;
sub new {
    my ( $class, $candles ) = @_;
    return bless { c => $candles }, $class;
}
sub get_candle  { return $_[0]->{c}[ $_[1] ]; }
sub last_candle { return $_[0]->{c}[ -1 ]; }
sub size        { return scalar @{ $_[0]->{c} }; }
sub active_tf   { return '1m'; }

package main;

sub make_candles {
    my (@closes) = @_;
    my @candles;
    for my $i ( 0 .. $#closes ) {
        my $c = $closes[$i];
        push @candles, {
            timestamp => 1700000000 + $i * 60,
            open   => $i ? $closes[ $i - 1 ] : $c - 1,
            high   => $c + 1,
            low    => $c - 1,
            close  => $c,
            volume => 10 + ( $i % 5 ),
        };
    }
    return @candles;
}

# Serie con TRES piernas claras (sube-baja-sube) para producir al menos 2
# pivotes confirmados (el ultimo tramo siempre queda "tentativo"/vivo).
my @closes;
push @closes, ( 10 .. 30 );          # pierna alcista: 10 -> 30
push @closes, ( reverse 5 .. 29 );   # pierna bajista: 29 -> 5
push @closes, ( 6 .. 25 );           # pierna alcista: 6 -> 25
my @candles = make_candles(@closes);
my $md = _FakeMD->new( \@candles );

# Test 1: BUGFIX - el pivote alto debe anclarse al HIGH real de la vela pivote,
# no al low (bug presente en la version original).
{
    my $zz = Market::Indicators::ZigZagVolumeProfile2->new( swing_length => 5 );
    for my $i ( 0 .. $#candles ) {
        $zz->update_at_index( $md, $i );
    }
    my $pivots = $zz->pivots_as_swings();
    die "Test1: se esperaban pivotes\n" unless $pivots && @$pivots;

    for my $p (@$pivots) {
        next unless $p->{kind} eq 'H';
        my $candle = $candles[ $p->{index} ];
        die "Test1: pivote alto en idx=$p->{index} no coincide con el high real "
          . "de la vela (price=$p->{price}, high=$candle->{high})\n"
          unless abs( $p->{price} - $candle->{high} ) < 1e-9;
    }
    print "OK Test1 pivotes altos anclados al high real ("
        . scalar(@$pivots) . " pivotes)\n";
}

# Test 2: pivots_as_swings() no vacio y alterna H/L.
{
    my $zz = Market::Indicators::ZigZagVolumeProfile2->new( swing_length => 5 );
    for my $i ( 0 .. $#candles ) {
        $zz->update_at_index( $md, $i );
    }
    my $pivots = $zz->pivots_as_swings();
    die "Test2: se esperaban al menos 2 pivotes\n" unless @$pivots >= 2;
    for my $i ( 1 .. $#$pivots ) {
        die "Test2: pivotes consecutivos con el mismo kind en idx=$i\n"
            if $pivots->[$i]{kind} eq $pivots->[ $i - 1 ]{kind};
    }
    print "OK Test2 pivots_as_swings alterna H/L (" . scalar(@$pivots) . " pivotes)\n";
}

# Test 3: sync_to_index == procesar secuencialmente update_at_index.
{
    my $zz_seq = Market::Indicators::ZigZagVolumeProfile2->new( swing_length => 5 );
    for my $i ( 0 .. $#candles ) {
        $zz_seq->update_at_index( $md, $i );
    }
    my $seq_pivots = $zz_seq->pivots_as_swings();

    my $zz_sync = Market::Indicators::ZigZagVolumeProfile2->new( swing_length => 5 );
    $zz_sync->sync_to_index( $md, $#candles );
    my $sync_pivots = $zz_sync->pivots_as_swings();

    die "Test3: pivot count mismatch seq=@{[scalar @$seq_pivots]} sync=@{[scalar @$sync_pivots]}\n"
        unless @$seq_pivots == @$sync_pivots;
    for my $j ( 0 .. $#$seq_pivots ) {
        die "Test3: pivot $j index mismatch\n"
            unless $seq_pivots->[$j]{index} == $sync_pivots->[$j]{index};
        die "Test3: pivot $j price mismatch\n"
            unless abs( $seq_pivots->[$j]{price} - $sync_pivots->[$j]{price} ) < 1e-9;
    }

    # sync_to_index repetido al mismo indice no debe duplicar ni cambiar nada.
    $zz_sync->sync_to_index( $md, $#candles );
    my $sync_pivots_again = $zz_sync->pivots_as_swings();
    die "Test3: re-sync al mismo indice cambio los pivotes\n"
        unless @$sync_pivots_again == @$sync_pivots;

    print "OK Test3 sync_to_index coincide con update_at_index secuencial ("
        . scalar(@$sync_pivots) . " pivotes)\n";
}

# Test 4: integracion real con StructureEngine (perfil externo = ZZVP2).
{
    my $liquidity = Market::Indicators::Liquidity->new();
    my $zzvp2     = Market::Indicators::ZigZagVolumeProfile2->new( swing_length => 5 );
    my $engine    = Market::Structure::StructureEngine->new(
        liquidity       => $liquidity,
        zigzag_external => $zzvp2,
    );

    my $result = $engine->calculate($md);
    die "Test4: se esperaban external_swings no vacios usando ZZVP2\n"
        unless $result->{external_swings} && @{ $result->{external_swings} };
    die "Test4: metadata.zigzag.external.algorithm deberia ser zzvp2_window_swing\n"
        unless ( $result->{metadata}{zigzag}{external}{algorithm} // '' ) eq 'zzvp2_window_swing';

    print "OK Test4 StructureEngine + ZZVP2 -> "
        . scalar( @{ $result->{external_swings} } ) . " external_swings, "
        . "algorithm=" . $result->{metadata}{zigzag}{external}{algorithm} . "\n";
}

print "ALL ZigZagVolumeProfile2 tests passed.\n";
exit 0;

