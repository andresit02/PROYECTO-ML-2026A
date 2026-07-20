package Market::Overlays::PivotAnchors;

# =============================================================================
# Market::Overlays::PivotAnchors
#
# Capa visual de Indicators::PivotAnchors. NO calcula nada: solo dibuja un
# marcador triangular en cada pivote ta.pivothigh/low ya detectado (mismo
# criterio que usan AVP/AVWAP para reanclar en modo 'auto'), a modo de
# referencia de "todas las anclas candidatas" -- estilo visual identico a
# los pivotes regulares (▼/▲) del Pine "Pivot Points High Low & Missed
# Reversal Levels [LuxAlgo]" que sirvio de base a AVP/AVWAP.
#
# Solo dibuja el marcador (sin linea vertical ni etiqueta de precio, para
# no saturar el grafico con potencialmente decenas de pivotes a la vez).
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Toggle: show (activar/desactivar toda la capa).
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_pivot_anchors';

use constant {
    C_HIGH => '#ef5350',   # pivote alto - rojo (igual criterio de color que AVP: sell)
    C_LOW  => '#26a69a',   # pivote bajo - verde (igual criterio de color que AVP: buy)
    MARKER_R      => 4,
    MARKER_OFFSET => 10,   # separacion vertical del marcador respecto al precio del pivote
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
    return unless $src && $src->can('get_pivots');

    my $pivots = $src->get_pivots;
    return unless $pivots && @$pivots;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};
    my $view_from = $off;
    my $view_to   = $off + $vb;

    for my $p (@$pivots) {
        next if $p->{index} < $view_from || $p->{index} > $view_to;
        next unless $scale->value_in_range( $p->{price} );

        my $x = $scale->index_to_center_x( $p->{index} );
        my $y = $scale->value_to_y( $p->{price} );

        if ( $p->{type} eq 'high' ) {
            $self->_draw_triangle_down( $canvas, $x, $y - MARKER_OFFSET, C_HIGH );
        } else {
            $self->_draw_triangle_up( $canvas, $x, $y + MARKER_OFFSET, C_LOW );
        }
    }
}

# -----------------------------------------------------------------------------
# _draw_triangle_down: marcador ▼ centrado en ($x,$y), apuntando hacia el
# precio del pivote alto (igual idea visual que style_label_down del Pine).
# -----------------------------------------------------------------------------
sub _draw_triangle_down {
    my ( $self, $canvas, $x, $y, $color ) = @_;
    my $r = MARKER_R;
    $canvas->createPolygon(
        $x - $r, $y - $r,
        $x + $r, $y - $r,
        $x,      $y + $r,
        -fill => $color, -outline => $color, -tags => [TAG],
    );
}

# -----------------------------------------------------------------------------
# _draw_triangle_up: marcador ▲ centrado en ($x,$y), apuntando hacia el
# precio del pivote bajo (igual idea visual que style_label_up del Pine).
# -----------------------------------------------------------------------------
sub _draw_triangle_up {
    my ( $self, $canvas, $x, $y, $color ) = @_;
    my $r = MARKER_R;
    $canvas->createPolygon(
        $x - $r, $y + $r,
        $x + $r, $y + $r,
        $x,      $y - $r,
        -fill => $color, -outline => $color, -tags => [TAG],
    );
}

1;