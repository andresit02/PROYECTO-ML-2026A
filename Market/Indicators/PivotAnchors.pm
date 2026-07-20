package Market::Indicators::PivotAnchors;

# =============================================================================
# Market::Indicators::PivotAnchors
#
# Indicador PURAMENTE INFORMATIVO: expone el historial completo de pivotes
# ta.pivothigh(length,length) / ta.pivotlow(length,length) -- exactamente el
# MISMO criterio de deteccion que usan Indicators::AnchoredVolumeProfile y
# Indicators::AnchoredVWAP para decidir donde reanclar en modo 'auto'.
#
# No ancla nada ni acumula nada por si mismo: solo sirve para VISUALIZAR
# todos los pivotes candidatos (los que SI se usaron como ancla y los que
# se "saltaron" porque hubo uno mas reciente antes de que este se llegara
# a usar), a modo de referencia -- igual idea que los "Missed Pivots" (👻)
# del Pine "Pivot Points High Low & Missed Reversal Levels [LuxAlgo]".
#
# Al ser el MISMO algoritmo que AVP/AVWAP, si el usuario activa este
# indicador junto con AVP o AVWAP en modo 'auto', el marcador de pivote que
# coincide con el ancla activa de esos dos es, por construccion, el mismo
# punto -- este indicador simplemente muestra tambien los anteriores.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        pivot_length => $args{pivot_length} // 50,   # ta.pivothigh/low(length,length)

        _c      => [],   # velas procesadas (indice paralelo)
        _pivots => [],   # historial completo: { index, price, type: 'high'|'low' }
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_pivots} = [];
}

sub get_values { return []; }   # contrato IndicatorManager (no aplica aqui)

# -----------------------------------------------------------------------------
# update_at_index / update_last: contrato IndicatorManager.
# -----------------------------------------------------------------------------
sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_check_pivot($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_check_pivot($idx);
}

sub processed_last { return $#{ $_[0]->{_c} }; }

# -----------------------------------------------------------------------------
# get_pivots: historial completo, en orden de confirmacion.
# Cada elemento: { index => idx_de_la_vela_pivote, price => .., type => 'high'|'low' }
# -----------------------------------------------------------------------------
sub get_pivots { return $_[0]->{_pivots}; }

# -----------------------------------------------------------------------------
# _check_pivot: IDENTICO a AnchoredVolumeProfile::_check_pivot /
# AnchoredVWAP::_check_pivot, pero sin la parte de reanclaje -- aqui solo
# se registra el pivote en el historial.
# -----------------------------------------------------------------------------
sub _check_pivot {
    my ( $self, $idx ) = @_;
    my $L = $self->{pivot_length};
    return if $idx < 2 * $L;

    my $cand = $idx - $L;
    my $c    = $self->{_c};

    my ( $max_h, $min_l );
    for my $i ( ( $idx - 2 * $L ) .. $idx ) {
        my $cc = $c->[$i];
        next unless defined $cc;
        $max_h = $cc->{high} if !defined($max_h) || $cc->{high} > $max_h;
        $min_l = $cc->{low}  if !defined($min_l) || $cc->{low}  < $min_l;
    }
    return unless defined $max_h && defined $min_l;

    my $cand_c = $c->[$cand];
    return unless defined $cand_c;

    if ( $cand_c->{high} == $max_h ) {
        push @{ $self->{_pivots} }, { index => $cand, price => $max_h, type => 'high' };
    }
    if ( $cand_c->{low} == $min_l ) {
        push @{ $self->{_pivots} }, { index => $cand, price => $min_l, type => 'low' };
    }
}

1;