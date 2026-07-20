package Market::Overlays::ZigZagMTF;

# =============================================================================
# Market::Overlays::ZigZagMTF
#
# Capa visual del ZigZag Multi Time Frame (direccion INTERNA). Dibuja la
# polilinea de segmentos ya calculados por Indicators::ZigZagMTF, en verde
# (tramo alcista) o rojo (tramo bajista), igual que el indicador de
# referencia ZZMTF de TradingView. NO calcula nada.
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Toggle: show (activar/desactivar toda la capa).
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_zzmtf';

use constant {
    C_UP   => '#26a69a',   # tramo alcista - verde
    C_DOWN => '#ef5350',   # tramo bajista - rojo
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
    return unless $src && $src->can('get_segments');

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $segments = $src->get_segments;
    if ( $segments && @$segments ) {
        for my $s (@$segments) {
            $self->_draw_segment( $canvas, $scale, $off, $vb, $s, 0 );
        }
    }

    if ( $src->can('get_tentative_segment') ) {
        my $tentative = $src->get_tentative_segment;
        $self->_draw_segment( $canvas, $scale, $off, $vb, $tentative, 1 ) if $tentative;
    }
}

# -----------------------------------------------------------------------------
# _draw_segment: dibuja un tramo del zigzag. $tentative=1 lo pinta punteado
# y mas tenue (tramo provisional hacia la vela mas reciente, aun sin
# confirmar por fractalidad), $tentative=0 lo pinta solido (tramo confirmado).
# -----------------------------------------------------------------------------
sub _draw_segment {
    my ( $self, $canvas, $scale, $off, $vb, $s, $tentative ) = @_;

    return if $s->{to_index} < $off || $s->{from_index} > $off + $vb;
    return unless $scale->value_in_range( $s->{from_price} )
               || $scale->value_in_range( $s->{to_price} );

    my $x1 = $scale->index_to_center_x( $s->{from_index} );
    my $y1 = $scale->value_to_y( $s->{from_price} );
    my $x2 = $scale->index_to_center_x( $s->{to_index} );
    my $y2 = $scale->value_to_y( $s->{to_price} );

    my $color = ( $s->{dir} eq 'up' ) ? C_UP : C_DOWN;

    $canvas->createLine( $x1, $y1, $x2, $y2,
        -fill  => $color,
        -width => $tentative ? 1 : LINE_WIDTH,
        ( $tentative ? ( -dash => [ 4, 3 ] ) : () ),
        -tags  => [TAG] );
}

1;