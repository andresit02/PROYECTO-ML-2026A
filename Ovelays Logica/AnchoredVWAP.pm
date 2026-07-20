package Market::Overlays::AnchoredVWAP;
use strict;
use warnings;

use constant TAG        => 'overlay_avwap';
use constant TAG_LABELS => 'overlay_avwap_labels';

use constant {
    C_VWAP    => '#2962ff',   # linea azul de precio justo
    C_ANCHOR  => '#4f8cff',
    C_BAND1   => '#2962ff',
    C_BAND2   => '#5b8def',
    C_BAND3   => '#8fb3f5',
    VWAP_WIDTH => 2,
};

sub tag        { return TAG; }
sub tag_labels { return TAG_LABELS; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source      => $args{source},
        show        => $args{show}        // 1,
        show_band1  => $args{show_band1}  // 1,
        show_band2  => $args{show_band2}  // 1,
        show_band3  => $args{show_band3}  // 0,
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
    $canvas->delete(TAG_LABELS);
    return unless $self->{show};

    my $src = $self->{source} or return;
    my $series = $src->get_series or return;
    my $points = $series->{points};
    return unless $points && @$points;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};
    my $view_from = $off;
    my $view_to   = $off + $vb;

    # --- Marca vertical del ancla + puntito en el precio de ancla ---
    my $anchor_idx   = $series->{anchor_index};
    my $anchor_price = $series->{anchor_price};
    if ( defined $anchor_idx ) {
        my $ax = $scale->index_to_center_x($anchor_idx);
        my $plot_w = $scale->_plot_w;
        if ( $ax >= 0 && $ax <= $plot_w ) {
            $canvas->createLine(
                $ax, $scale->_plot_y_top, $ax, $scale->_plot_y_bottom,
                -fill => C_ANCHOR, -width => 1, -dash => [ 3, 3 ],
                -tags => [TAG],
            );
            if ( defined $anchor_price ) {
                my $ay = $scale->value_to_y($anchor_price);
                my $r  = 6;
                $canvas->createOval(
                    $ax - $r, $ay - $r, $ax + $r, $ay + $r,
                    -fill => C_ANCHOR, -outline => '#ffffff', -width => 2,
                    -tags => [TAG],
                );
            }
            $canvas->createText(
                $ax + 4, $scale->_plot_y_top + 10,
                -text => 'AVWAP', -anchor => 'w', -fill => C_ANCHOR,
                -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
            );
        }
    }

    # --- Filtrar puntos visibles (con 1 de margen a cada lado para que las
    #     lineas no se corten justo en el borde del viewport) ---
    my @visible = grep { $_->{index} >= $view_from - 1 && $_->{index} <= $view_to + 1 } @$points;
    return unless @visible;

    # --- Bandas de desviacion (dibujar antes que la linea central para que
    #     esta quede siempre encima) ---
    $self->_draw_band( $canvas, $scale, \@visible, 'upper1', 'lower1', C_BAND1, 1 )
        if $self->{show_band1};
    $self->_draw_band( $canvas, $scale, \@visible, 'upper2', 'lower2', C_BAND2, 1 )
        if $self->{show_band2};
    $self->_draw_band( $canvas, $scale, \@visible, 'upper3', 'lower3', C_BAND3, 1 )
        if $self->{show_band3};

    # --- Linea central VWAP (precio justo) ---
    $self->_draw_line( $canvas, $scale, \@visible, 'vwap', C_VWAP, VWAP_WIDTH );

    # --- Etiqueta con el ultimo valor del VWAP, al final de la linea ---
    my $last_pt = $visible[-1];
    if ( defined $last_pt->{vwap} ) {
        my $lx = $scale->index_to_center_x( $last_pt->{index} );
        my $ly = $scale->value_to_y( $last_pt->{vwap} );
        $canvas->createText(
            $lx + 4, $ly,
            -text => sprintf( '%.4f', $last_pt->{vwap} ),
            -anchor => 'w', -fill => C_VWAP,
            -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
        );
    }

    $canvas->raise(TAG);
    $canvas->raise(TAG_LABELS);
}

# -----------------------------------------------------------------------------
# _draw_line: polilinea continua uniendo point.index -> point.{$field} para
# cada punto visible consecutivo.
# -----------------------------------------------------------------------------
sub _draw_line {
    my ( $self, $canvas, $scale, $points, $field, $color, $width ) = @_;
    my @coords;
    for my $p (@$points) {
        next unless defined $p->{$field};
        push @coords, $scale->index_to_center_x( $p->{index} ), $scale->value_to_y( $p->{$field} );
    }
    return if @coords < 4;
    $canvas->createLine( @coords, -fill => $color, -width => $width, -tags => [TAG] );
}

# -----------------------------------------------------------------------------
# _draw_band: dibuja las dos lineas (upper/lower) de un desvio. Sin relleno
# para no saturar el grafico cuando se activan los 3 pares a la vez.
# -----------------------------------------------------------------------------
sub _draw_band {
    my ( $self, $canvas, $scale, $points, $upper_field, $lower_field, $color, $width ) = @_;
    $self->_draw_line( $canvas, $scale, $points, $upper_field, $color, $width );
    $self->_draw_line( $canvas, $scale, $points, $lower_field, $color, $width );
}

1;