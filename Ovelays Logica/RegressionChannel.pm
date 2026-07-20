package Market::Overlays::RegressionChannel;

# =============================================================================
# Market::Overlays::RegressionChannel
#
# Capa visual de los canales de regresion lineal ya calculados por
# Indicators::RegressionChannel (uno por pierna del ZigZag externo, zzvp).
# NO calcula nada.
#
# Por cada canal dibuja:
#   - Banda superior  : linea solida  price = m*idx + b + upper_off
#   - Banda inferior  : linea solida  price = m*idx + b + lower_off
#   - Linea central   : punteada      price = m*idx + b
#   - Relleno semitransparente entre banda superior e inferior.
# Cada canal queda ACOTADO a su propia pierna (from_index..to_index), a
# diferencia de un canal global: no se extiende mas alla del tramo que le
# dio origen.
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Toggle: show (activar/desactivar toda la capa).
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_regchan';

use constant {
    C_LINE   => '#3f6ee0',   # bordes del canal - azul
    C_MID    => '#7c96e8',   # linea central - azul mas claro/tenue
    C_FILL   => '#3f6ee0',   # base del relleno (se mezcla con opacidad simulada)
    FILL_OP  => 0.16,        # opacidad simulada del relleno
    LINE_WIDTH => 2,
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source => $args{source},
        show   => $args{show} // 1,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    return unless $self->{show};

    my $src = $self->{source};
    return unless $src && $src->can('get_channels');

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $channels = $src->get_channels;
    if ( $channels && @$channels ) {
        for my $ch (@$channels) {
            $self->_draw_channel( $canvas, $scale, $off, $vb, $ch );
        }
    }

    if ( $src->can('get_tentative_channel') ) {
        my $tentative = $src->get_tentative_channel;
        $self->_draw_channel( $canvas, $scale, $off, $vb, $tentative, 1 ) if $tentative;
    }
}

# -----------------------------------------------------------------------------
# _draw_channel: dibuja UN canal acotado a [ch.from_index, ch.to_index].
# $tentative=1 -> pierna en formacion: bordes punteados y mas tenues, para
# distinguirla visualmente de los canales ya confirmados.
# -----------------------------------------------------------------------------
sub _draw_channel {
    my ( $self, $canvas, $scale, $off, $vb, $ch, $tentative ) = @_;
    return unless $ch;

    my $from_idx = $ch->{from_index};
    my $to_idx   = $ch->{to_index};
    return if $to_idx < $off || $from_idx > $off + $vb;

    my $clip_from = $from_idx < $off       ? $off       : $from_idx;
    my $clip_to   = $to_idx   > $off + $vb ? $off + $vb : $to_idx;
    return if $clip_to <= $clip_from;

    my $x1 = $scale->index_to_center_x($clip_from);
    my $x2 = $scale->index_to_center_x($clip_to);

    my $mid_y1 = $scale->value_to_y( $ch->{slope} * $clip_from + $ch->{intercept} );
    my $mid_y2 = $scale->value_to_y( $ch->{slope} * $clip_to   + $ch->{intercept} );
    my $up_y1  = $scale->value_to_y( $ch->{slope} * $clip_from + $ch->{intercept} + $ch->{upper_off} );
    my $up_y2  = $scale->value_to_y( $ch->{slope} * $clip_to   + $ch->{intercept} + $ch->{upper_off} );
    my $low_y1 = $scale->value_to_y( $ch->{slope} * $clip_from + $ch->{intercept} + $ch->{lower_off} );
    my $low_y2 = $scale->value_to_y( $ch->{slope} * $clip_to   + $ch->{intercept} + $ch->{lower_off} );

    my $fill_op = $tentative ? FILL_OP * 0.6 : FILL_OP;
    my $fill    = _mix( C_FILL, $fill_op );
    $canvas->createPolygon(
        $x1, $up_y1, $x2, $up_y2, $x2, $low_y2, $x1, $low_y1,
        -fill => $fill, -outline => '', -tags => [TAG] );

    my $line_color = $tentative ? _mix( C_LINE, 0.55 ) : C_LINE;
    my $dash       = $tentative ? [ 5, 3 ] : undef;

    $canvas->createLine( $x1, $up_y1,  $x2, $up_y2,
        -fill => $line_color, -width => LINE_WIDTH,
        ( $dash ? ( -dash => $dash ) : () ), -tags => [TAG] );
    $canvas->createLine( $x1, $low_y1, $x2, $low_y2,
        -fill => $line_color, -width => LINE_WIDTH,
        ( $dash ? ( -dash => $dash ) : () ), -tags => [TAG] );

    $canvas->createLine( $x1, $mid_y1, $x2, $mid_y2,
        -fill => C_MID, -width => 1, -dash => [ 4, 3 ], -tags => [TAG] );
}

# -----------------------------------------------------------------------------
# _mix: mezcla un color hex con el fondo, simulando opacidad en Tk Canvas
# (igual criterio que SMC_Structures::_mix).
# -----------------------------------------------------------------------------
sub _mix {
    my ( $hex, $op ) = @_;
    $op = 0 if $op < 0;
    $op = 1 if $op > 1;
    my ( $r, $g, $b ) = ( hex( substr( $hex, 1, 2 ) ),
                          hex( substr( $hex, 3, 2 ) ),
                          hex( substr( $hex, 5, 2 ) ) );
    my $f = 1 - $op;
    my ( $br, $bg, $bb ) = ( 214, 219, 230 );   # fondo claro de referencia
    $r = int( $r + ( $br - $r ) * $f );
    $g = int( $g + ( $bg - $g ) * $f );
    $b = int( $b + ( $bb - $b ) * $f );
    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

1;