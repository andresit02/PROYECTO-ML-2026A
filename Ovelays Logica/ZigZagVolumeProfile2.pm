package Market::Overlays::ZigZagVolumeProfile2;

# =============================================================================
# Market::Overlays::ZigZagVolumeProfile2
#
# Capa visual de ZZVP2. Dibuja:
#   - Polilinea del zigzag (segmentos + tramo abierto/tentativo).
#   - Canal de swing: lineas guia paralelas al segmento, desplazadas por
#     atrRange*i (igual que channelLineArray del Pine), si show_channel.
#   - Perfil de volumen: por cada nivel (bin) del segmento, una barra que
#     nace en (start_idx,start_price) y se extiende hacia el extremo segun
#     su volumen relativo (igual que profileLineArray/profileLabelArray).
#   - Lineas de POC: la del nivel con mayor volumen, coloreada distinto y
#     extendida un poco mas alla del borde derecho del segmento.
#
# NO calcula nada: lee get_segments()/get_tentative_segment()/get_profiles()
# de Indicators::ZigZagVolumeProfile2.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_zzvp2';

use constant {
    C_LINE     => '#4f8cff',   # zigzag - azul
    C_CHANNEL  => '#888888',   # canal guia - gris tenue (chart.fg_color 70% opacidad aprox)
    C_BIN_LOW  => '#00e676',   # binColorLow  (lime)
    C_BIN_HIGH => '#2979ff',   # binColorHigh (blue)
    C_POC      => '#ff1744',   # pocLineColor (red)
    LINE_WIDTH      => 2,
    POC_LINE_WIDTH  => 2,
    BIN_LINE_WIDTH  => 5,      # volumebinWidth (Pine default 5)
    POC_EXTEND_BARS => 15,     # pocLineArray se extiende 15 barras a la derecha
    MAX_PROFILES_DRAWN => 3,   # cuantas piernas recientes dibujan su histograma
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source              => $args{source},
        show_zigzag         => $args{show_zigzag}         // 1,
        show_channel        => $args{show_channel}        // 1,
        show_volume_profile => $args{show_volume_profile} // 1,
        show_poc            => $args{show_poc}            // 1,
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

    $self->_render_profiles( $canvas, $scale, $src )
        if $self->{show_channel} || $self->{show_volume_profile} || $self->{show_poc};
    $self->_render_zigzag( $canvas, $scale, $src ) if $self->{show_zigzag};
}

# -----------------------------------------------------------------------------
# Polilinea: segmentos confirmados + tramo abierto (el ultimo, aun mutable
# via set_xy2 en el indicador). Se dibuja igual (sin punteado) porque en el
# Pine tambien es una linea solida que se va extendiendo en vivo.
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

        my $x1 = $scale->index_to_center_x( $s->{from_index} );
        my $y1 = $scale->value_to_y( $s->{from_price} );
        my $x2 = $scale->index_to_center_x( $s->{to_index} );
        my $y2 = $scale->value_to_y( $s->{to_price} );

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill  => C_LINE,
            -width => LINE_WIDTH,
            -tags  => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# Canal + perfil de volumen + POC, por cada pierna (limitado a las mas
# recientes visibles, MAX_PROFILES_DRAWN, igual criterio que ZZVP1).
# -----------------------------------------------------------------------------
sub _render_profiles {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_profiles');
    my $profiles = $src->get_profiles;
    return unless $profiles && @$profiles;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $start = $#$profiles - MAX_PROFILES_DRAWN + 1;
    $start = 0 if $start < 0;

    for my $k ( $start .. $#$profiles ) {
        my $prof = $profiles->[$k];
        my ( $lo_idx, $hi_idx ) = $prof->{idx_from} < $prof->{idx_to}
            ? ( $prof->{idx_from}, $prof->{idx_to} )
            : ( $prof->{idx_to}, $prof->{idx_from} );
        next if $hi_idx < $off || $lo_idx > $off + $vb;

        $self->_render_one_profile( $canvas, $scale, $prof );
    }
}

sub _render_one_profile {
    my ( $self, $canvas, $scale, $prof ) = @_;

    my $start_idx   = $prof->{idx_from};
    my $start_price = $prof->{price_from};
    my $end_idx     = $prof->{idx_to};
    my $end_price   = $prof->{price_to};
    my $direction   = $prof->{direction};   # trendDirection del Pine

    my $x_start = $scale->index_to_center_x($start_idx);
    my $x_end   = $scale->index_to_center_x($end_idx);
    my $range_  = $end_idx - $start_idx;
    return if $range_ == 0;

    my $bins    = $prof->{bins} || [];
    my $max_vol = $prof->{max_volume} // 0;

    for my $b (@$bins) {
        my $y_start = $start_price + $b->{offset};
        my $y_end   = $end_price   + $b->{offset};

        if ( $self->{show_channel} ) {
            $canvas->createLine(
                $x_start, $scale->value_to_y($y_start),
                $x_end,   $scale->value_to_y($y_end),
                -fill => C_CHANNEL, -width => 1, -tags => [TAG] );
        }

        next unless $self->{show_volume_profile} || $self->{show_poc};
        next if $max_vol <= 0;

        # fillStart = startPrice + (direction ? +slope*k : -slope*k)
        # k = int(range_/100 * volumePercent) en unidades de barras
        my $k = int( abs($range_) / 100 * $b->{volume_pct} );
        $k = $range_ >= 0 ? $k : -$k;   # respeta el sentido del segmento
        my $bar_bar_idx = $start_idx + $k;

        my $fill_price = $direction
            ? $start_price + $b->{slope} * $k
            : $start_price - $b->{slope} * $k;
        my $fill_y = $fill_price + $b->{offset};

        my $is_poc = $b->{is_poc};

        if ( $self->{show_volume_profile} ) {
            my $bar_color = $is_poc
                ? C_POC
                : _gradient_color( $b->{volume}, 0, $max_vol, C_BIN_HIGH, C_BIN_LOW );

            my $x_bar = $scale->index_to_center_x($bar_bar_idx);
            $canvas->createLine(
                $x_bar,   $scale->value_to_y($fill_y),
                $x_start, $scale->value_to_y($y_start),
                -fill => $bar_color, -width => BIN_LINE_WIDTH, -tags => [TAG] );

            $canvas->createText(
                $x_start + 4, $scale->value_to_y($y_start),
                -text   => sprintf( "%.1f%%", $b->{volume_pct} ),
                -fill   => $bar_color,
                -anchor => 'w',
                -font   => [ '', 8 ],
                -tags   => [TAG] );
        }

        if ( $is_poc && $self->{show_poc} ) {
            my $x_end_extended = $scale->index_to_center_x( $end_idx + POC_EXTEND_BARS );
            $canvas->createLine(
                $x_end, $scale->value_to_y($y_end),
                $x_end_extended, $scale->value_to_y($y_end),
                -fill => C_POC, -width => POC_LINE_WIDTH, -tags => [TAG] );

            $canvas->createLine(
                $x_start, $scale->value_to_y($y_start),
                $x_end,   $scale->value_to_y($y_end),
                -fill => C_POC, -width => POC_LINE_WIDTH, -tags => [TAG] );
        }
    }
}

# color.from_gradient(value, bottom, top, colorA, colorB): interpola entre
# colorA (en bottom) y colorB (en top).
sub _gradient_color {
    my ( $val, $bottom, $top, $color_high, $color_low ) = @_;
    my $range = $top - $bottom;
    $range = 1e-9 if $range == 0;
    my $t = ( $val - $bottom ) / $range;
    $t = 0 if $t < 0;
    $t = 1 if $t > 1;

    my ( $r1, $g1, $b1 ) = _hex_to_rgb($color_low);
    my ( $r2, $g2, $b2 ) = _hex_to_rgb($color_high);

    my $r = int( $r1 + ( $r2 - $r1 ) * $t );
    my $g = int( $g1 + ( $g2 - $g1 ) * $t );
    my $b = int( $b1 + ( $b2 - $b1 ) * $t );

    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

sub _hex_to_rgb {
    my ($hex) = @_;
    $hex =~ s/^#//;
    return ( hex( substr( $hex, 0, 2 ) ), hex( substr( $hex, 2, 2 ) ), hex( substr( $hex, 4, 2 ) ) );
}

1;