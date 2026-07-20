package Market::Indicators::RegressionChannel;

# =============================================================================
# Market::Indicators::RegressionChannel
#
# Canal(es) de regresion lineal (Linear Regression Channel), UNO POR CADA
# PIERNA del ZigZag externo (Indicators::ZigZagVolumeProfile). Esto es
# distinto de un canal global sobre toda la serie: cada pierna (tramo entre
# un pivote y el siguiente giro de tendencia) recibe su propio ajuste,
# igual que el indicador de referencia de TradingView (canal corto, pegado
# a una sola subida o bajada, no a todo el historico mezclando subidas y
# bajadas).
#
# Algoritmo (por cada segmento from_index..to_index del zigzag externo):
#   1. Tomar las VELAS reales de MarketData dentro de ese rango (no solo los
#      2 pivotes que delimitan la pierna) como pares (index, precio_medio),
#      usando (high+low)/2 de cada vela para que el ajuste refleje el
#      cuerpo de la pierna y no solo close.
#   2. Ajuste por minimos cuadrados -> pendiente (m) e intercepto (b) de la
#      linea central: price = m*index + b.
#   3. Para cada vela del tramo, calcular el residual (distancia vertical
#      firmada a la linea central) usando high para el lado superior y low
#      para el lado inferior. El mayor residual-high fija el offset de la
#      banda superior; el menor residual-low fija el offset de la banda
#      inferior. Asi el canal envuelve TODAS las mechas del tramo, no solo
#      los pivotes.
#
# Se recalculan solo los segmentos NUEVOS que reporte zzvp (por indice de
# segmento), mas el tramo tentativo (provisional, hacia la vela mas
# reciente) para que el ultimo canal no se quede "cortado" varias velas
# antes del borde derecho.
#
# NO se dibuja nada aqui. Ver Overlays::RegressionChannel.
#
# Contrato de Indicador (IndicatorManager): update_last / update_at_index /
# get_values / reset. Ademas expone get_channels() (arrayref de canales,
# uno por pierna) para el Overlay.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        # Fuente de pivotes/segmentos externos (Indicators::ZigZagVolumeProfile).
        zzvp     => $args{zzvp},
        # Cuantas piernas recientes conservar y dibujar. undef/0 = todas.
        max_legs => $args{max_legs} // 0,

        _channels          => [],   # un canal confirmado por segmento
        _last_segment_count => -1,
        _md                => undef,   # referencia a MarketData (para leer velas)
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_channels} = [];
    $self->{_last_segment_count} = -1;
    $self->{_md} = undef;
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    $self->{_md} = $md;
    $self->_recompute;
}

sub update_last {
    my ( $self, $md ) = @_;
    $self->{_md} = $md;
    $self->_recompute;
}

sub get_values    { return []; }
sub get_channels  { return $_[0]->{_channels}; }

# -----------------------------------------------------------------------------
# get_tentative_channel: canal sobre el tramo provisional (ultimo pivote
# confirmado -> vela mas reciente), igual criterio que
# ZigZagVolumeProfile::get_tentative_segment, para que el canal de la
# pierna en formacion se vea en vivo y no solo tras confirmarse el giro.
# -----------------------------------------------------------------------------
sub get_tentative_channel {
    my ($self) = @_;
    my $zz = $self->{zzvp};
    my $md = $self->{_md};
    return undef unless $zz && $md && $zz->can('get_tentative_segment');

    my $seg = $zz->get_tentative_segment;
    return undef unless $seg;

    return $self->_fit_channel_over_range( $md, $seg->{from_index}, $seg->{to_index} );
}

# -----------------------------------------------------------------------------
# _recompute: solo vuelve a ajustar los segmentos NUEVOS que zzvp reporte
# (evita recalcular piernas ya cerradas en cada vela).
# -----------------------------------------------------------------------------
sub _recompute {
    my ($self) = @_;
    my $zz = $self->{zzvp};
    my $md = $self->{_md};
    return unless $zz && $md && $zz->can('get_segments');

    my $segments = $zz->get_segments;
    return unless $segments;

    my $n = scalar @$segments;
    return if $n == $self->{_last_segment_count};

    my $start = $self->{_last_segment_count};
    $start = 0 if $start < 0;

    for my $k ( $start .. $n - 1 ) {
        my $seg = $segments->[$k];
        my $ch  = $self->_fit_channel_over_range( $md, $seg->{from_index}, $seg->{to_index} );
        push @{ $self->{_channels} }, $ch if $ch;
    }
    $self->{_last_segment_count} = $n;

    if ( $self->{max_legs} && $self->{max_legs} > 0 ) {
        my $keep = $self->{max_legs};
        splice( @{ $self->{_channels} }, 0, @{ $self->{_channels} } - $keep )
            if @{ $self->{_channels} } > $keep;
    }
}

# -----------------------------------------------------------------------------
# _fit_channel_over_range: minimos cuadrados sobre el precio medio de cada
# vela en [from_index, to_index], mas envolvente de mechas (high/low) para
# los offsets de banda. Devuelve undef si el rango es degenerado.
# -----------------------------------------------------------------------------
sub _fit_channel_over_range {
    my ( $self, $md, $from_index, $to_index ) = @_;
    return undef if $to_index <= $from_index;

    my @candles;
    for my $i ( $from_index .. $to_index ) {
        my $c = $md->get_candle($i);
        push @candles, [ $i, $c ] if defined $c;
    }
    return undef if @candles < 2;

    my ( $sum_x, $sum_y, $sum_xy, $sum_xx ) = ( 0, 0, 0, 0 );
    my $n = scalar @candles;
    for my $pair (@candles) {
        my ( $i, $c ) = @$pair;
        my $mid = ( $c->{high} + $c->{low} ) / 2;
        $sum_x  += $i;
        $sum_y  += $mid;
        $sum_xy += $i * $mid;
        $sum_xx += $i * $i;
    }

    my $denom = ( $n * $sum_xx ) - ( $sum_x * $sum_x );
    return undef if abs($denom) < 1e-9;

    my $m = ( ( $n * $sum_xy ) - ( $sum_x * $sum_y ) ) / $denom;
    my $b = ( $sum_y - $m * $sum_x ) / $n;

    my ( $max_res, $min_res ) = ( 0, 0 );
    for my $pair (@candles) {
        my ( $i, $c ) = @$pair;
        my $fitted = $m * $i + $b;
        my $res_high = $c->{high} - $fitted;
        my $res_low  = $c->{low}  - $fitted;
        $max_res = $res_high if $res_high > $max_res;
        $min_res = $res_low  if $res_low  < $min_res;
    }

    # Margen de seguridad (2% del rango total del canal): sin esto, la mecha
    # que fija el offset queda EXACTAMENTE sobre el borde matematico de la
    # banda, y como la linea se dibuja con ancho > 1px centrado en ese
    # borde, la mitad del trazo cae "hacia adentro" y la otra mitad "hacia
    # afuera" -- visualmente parece que la mecha se sale del canal aunque
    # el calculo sea correcto. Separando un poco el borde de su punto de
    # contacto real, el trazo queda claramente por fuera de cualquier mecha.
    my $range  = $max_res - $min_res;
    my $margin = $range > 0 ? $range * 0.02 : 0;
    $max_res += $margin;
    $min_res -= $margin;

    return {
        slope      => $m,
        intercept  => $b,
        upper_off  => $max_res,   # >= 0
        lower_off  => $min_res,   # <= 0
        from_index => $from_index,
        to_index   => $to_index,
        n_points   => $n,
    };
}

1;