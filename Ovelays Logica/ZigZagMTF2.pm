package Market::Overlays::ZigZagMTF2;

# =============================================================================
# Market::Overlays::ZigZagMTF2
#
# Capa visual de ZZMTF2. Dibuja:
#   - Polilinea del zigzag (verde tramo alcista, rojo tramo bajista), igual
#     criterio de color que el Pine (upcol/dncol).
#   - Niveles de Fibonacci (get_fibo_levels): lineas horizontales extendidas
#     a la derecha + etiqueta con ratio y precio, igual que el Pine.
#
# NO calcula nada: lee get_segments()/get_fibo_levels()/get_dir() de
# Indicators::ZigZagMTF2.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_zzmtf2';

use constant {
    C_UP     => '#00e676',   # upcol (lime)
    C_DOWN   => '#ff1744',   # dncol (red)
    C_FIBO   => '#00e676',   # fibolinecol (lime)
    C_LABEL  => '#2979ff',   # labelcol (blue)
    LINE_WIDTH => 2,
    FIBO_LINE_WIDTH => 1,
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source      => $args{source},
        show_zigzag => $args{show_zigzag} // 1,
        show_fibo   => $args{show_fibo}   // 1,
        label_left  => $args{label_left}  // 1,   # "Left" (Pine) vs "Right"
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
    my $src = $self->{source};
    return unless $src;

    $self->_render_zigzag( $canvas, $scale, $src ) if $self->{show_zigzag};
    $self->_render_fibo( $canvas, $scale, $src )    if $self->{show_fibo};
}

# -----------------------------------------------------------------------------
# Polilinea: cada segmento coloreado segun su propia direccion (up/down),
# igual que dir == 1 ? upcol : dncol en el Pine (dir se aplica por tramo).
# -----------------------------------------------------------------------------
sub _render_zigzag {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_segments');

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $segments = $src->get_segments;
    return unless $segments && @$segments;

    for my $s (@$segments) {
        next if $s->{to_index} < $off || $s->{from_index} > $off + $vb;
        next unless $scale->value_in_range( $s->{from_price} )
                 || $scale->value_in_range( $s->{to_price} );

        my $x1 = $scale->index_to_center_x( $s->{from_index} );
        my $y1 = $scale->value_to_y( $s->{from_price} );
        my $x2 = $scale->index_to_center_x( $s->{to_index} );
        my $y2 = $scale->value_to_y( $s->{to_price} );

        my $color = ( $s->{dir} eq 'up' ) ? C_UP : C_DOWN;

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => LINE_WIDTH,
            -tags  => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# Fibonacci: cada nivel es una linea horizontal desde from_index hasta
# to_index (bar actual), con label de ratio + precio. extend=right en el
# Pine -> aqui se extiende visualmente hasta el borde derecho visible.
# -----------------------------------------------------------------------------
sub _render_fibo {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_fibo_levels');
    my $levels = $src->get_fibo_levels;
    return unless $levels && @$levels;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};
    my $x_right_edge = $scale->index_to_center_x( $off + $vb );

    for my $lvl (@$levels) {
        next unless $scale->value_in_range( $lvl->{price} );

        my $x1 = $scale->index_to_center_x( $lvl->{from_index} );
        my $y  = $scale->value_to_y( $lvl->{price} );

        # extend.right: la linea sigue hasta el borde derecho visible, no
        # solo hasta to_index (que es la ultima vela conocida).
        my $x2 = $x_right_edge > $x1 ? $x_right_edge : $x1;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill  => C_FIBO,
            -width => FIBO_LINE_WIDTH,
            -tags  => [TAG] );

        my $label = sprintf( "%.3f (%.2f)", $lvl->{ratio}, $lvl->{price} );
        my ( $lx, $anchor ) = $self->{label_left}
            ? ( $x1 - 4, 'e' )
            : ( $x2 + 4, 'w' );

        $canvas->createText( $lx, $y,
            -text   => $label,
            -fill   => C_LABEL,
            -anchor => $anchor,
            -font   => [ '', 8 ],
            -tags   => [TAG] );
    }
}

1;