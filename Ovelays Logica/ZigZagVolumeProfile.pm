package Market::Overlays::ZigZagVolumeProfile;

# =============================================================================
# Market::Overlays::ZigZagVolumeProfile
#
# Capa visual del ZigZag Volume Profile (direccion EXTERNA). Dibuja:
#   - La polilinea de segmentos en AZUL (identifica visualmente la direccion
#     externa, distinta del verde/rojo del ZigZag interno), igual que el
#     indicador de referencia ZigZag Volume Profile [ChartPrime].
#   - Opcionalmente, el histograma de volumen (barras horizontales por bin)
#     de la ULTIMA pierna, y una linea marcando el POC.
#
# NO calcula nada: lee get_segments() / get_profiles() de
# Indicators::ZigZagVolumeProfile.
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Sub-toggles: show_zigzag / show_volume_profile / show_poc.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_zzvp';

use constant {
    C_LINE  => '#4f8cff',   # zigzag externo - azul
    C_VOL   => '#7e57c2',   # barras de volumen - violeta tenue
    C_POC   => '#ff9800',   # POC - naranja
    LINE_WIDTH => 2,
    MAX_PROFILES_DRAWN => 3,   # cuantas piernas recientes dibujan su histograma
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source              => $args{source},
        show_zigzag         => $args{show_zigzag}         // 1,
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

    $self->_render_zigzag( $canvas, $scale, $src ) if $self->{show_zigzag};
    $self->_render_profiles( $canvas, $scale, $src )
        if $self->{show_volume_profile} || $self->{show_poc};
}

# -----------------------------------------------------------------------------
# Polilinea azul: direccion externa. Incluye el tramo tentativo (provisional,
# punteado) hacia la vela mas reciente, para que la linea no quede cortada
# varias velas antes del borde derecho mientras el ultimo pivote real aun
# no se confirma.
# -----------------------------------------------------------------------------
sub _render_zigzag {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_segments');

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $segments = $src->get_segments;
    if ( $segments && @$segments ) {
        for my $s (@$segments) {
            $self->_draw_zigzag_segment( $canvas, $scale, $off, $vb, $s, 0 );
        }
    }

    if ( $src->can('get_tentative_segment') ) {
        my $tentative = $src->get_tentative_segment;
        $self->_draw_zigzag_segment( $canvas, $scale, $off, $vb, $tentative, 1 ) if $tentative;
    }
}

sub _draw_zigzag_segment {
    my ( $self, $canvas, $scale, $off, $vb, $s, $tentative ) = @_;

    # Recorte SOLO por indice (eje horizontal). Antes tambien se exigia que
    # from_price/to_price cayeran dentro del rango vertical visible
    # (value_in_range), pero eso es incorrecto para una polilinea: un
    # segmento puede estar horizontalmente dentro de la ventana visible y
    # aun asi tener sus extremos de precio fuera de la escala vertical
    # actual (p.ej. tramos antiguos, cuando el precio todavia no habia
    # alcanzado los niveles extremos que fijan la escala actual). Ese
    # filtro descartaba en silencio segmentos validos, dando la impresion
    # de que el zigzag externo "solo aparece al final" del grafico. Tk
    # recorta lineas fuera del canvas sin problema, asi que no hace falta
    # filtrar por precio para dibujar correctamente.
    return if $s->{to_index} < $off || $s->{from_index} > $off + $vb;

    my $x1 = $scale->index_to_center_x( $s->{from_index} );
    my $y1 = $scale->value_to_y( $s->{from_price} );
    my $x2 = $scale->index_to_center_x( $s->{to_index} );
    my $y2 = $scale->value_to_y( $s->{to_price} );

    $canvas->createLine( $x1, $y1, $x2, $y2,
        -fill  => C_LINE,
        -width => $tentative ? 1 : LINE_WIDTH,
        ( $tentative ? ( -dash => [ 4, 3 ] ) : () ),
        -tags  => [TAG] );
}

# -----------------------------------------------------------------------------
# Histograma de volumen + POC: solo las piernas mas recientes (MAX_PROFILES_DRAWN)
# que caigan dentro de la ventana visible, para no saturar el grafico.
# Cada bin se dibuja como una barra horizontal semitransparente que arranca
# desde el borde derecho de la pierna hacia la izquierda, proporcional al
# volumen relativo dentro de esa pierna.
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
        next if $prof->{idx_to} < $off || $prof->{idx_from} > $off + $vb;

        my $x_right = $scale->index_to_center_x( $prof->{idx_to} );
        my $x_left  = $scale->index_to_center_x( $prof->{idx_from} );
        my $pierna_w = $x_right - $x_left;
        next if $pierna_w <= 0;

        if ( $self->{show_volume_profile} ) {
            my $max_vol = 0;
            for my $b ( @{ $prof->{bins} } ) { $max_vol = $b->{volume} if $b->{volume} > $max_vol; }
            $max_vol = 1e-9 if $max_vol <= 0;

            my $bar_max_w = $pierna_w * 0.35;   # las barras ocupan como maximo 35% del ancho de la pierna

            for my $b ( @{ $prof->{bins} } ) {
                next unless $scale->value_in_range( $b->{low} ) || $scale->value_in_range( $b->{high} );

                my $y_top    = $scale->value_to_y( $b->{high} );
                my $y_bottom = $scale->value_to_y( $b->{low} );
                my $bar_w    = $bar_max_w * ( $b->{volume} / $max_vol );

                $canvas->createRectangle(
                    $x_right - $bar_w, $y_top, $x_right, $y_bottom,
                    -fill => C_VOL, -outline => '', -stipple => 'gray50',
                    -tags => [TAG] );
            }
        }

        if ( $self->{show_poc} && $scale->value_in_range( $prof->{poc_price} ) ) {
            my $y = $scale->value_to_y( $prof->{poc_price} );
            $canvas->createLine( $x_left, $y, $x_right, $y,
                -fill => C_POC, -width => 1, -dash => [ 3, 2 ], -tags => [TAG] );
        }
    }
}

1;