package Market::Overlays::SMC_Structures;

# =============================================================================
# Market::Overlays::SMC_Structures
#
# Capa visual de BOS / iBOS ya calculados por Indicators/SMC_Structures.pm.
# NO calcula nada. FVG fue removido de este modulo (ver Indicators::SMC_Structures).
#
# Estilo de etiquetas: helper _chip:
#   - solid : texto blanco sobre chip de color (unico estilo usado aqui).
#   El chip se ancla a la coordenada X/precio reales (index_to_center_x /
#   value_to_y), con anti-solape que DESPLAZA la etiqueta verticalmente (no la
#   borra), redibujado cada frame -> estable en replay/zoom/desplazamiento.
#
#   BOS  (estructura principal) : linea horizontal SOLIDA y gruesa en el
#                                  nivel roto, color direccional (verde
#                                  alcista / rojo bajista).
#   iBOS (subestructura)        : linea horizontal PUNTEADA fina, mismo
#                                  color direccional pero mas tenue.
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Sub-toggles independientes: show_bos / show_ibos.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_smc';
use constant TAG_LABELS => 'overlay_smc_labels';
sub tag        { return TAG; }
sub tag_labels { return TAG_LABELS; }

use constant {
    C_UP   => '#26a69a',   # alcista - verde
    C_DOWN => '#ef5350',   # bajista - rojo
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source     => $args{source},
        show_bos   => $args{show_bos}   // 1,
        show_choch => $args{show_choch} // 1,
        show_fvg   => $args{show_fvg}   // 1,
        show_hhll  => $args{show_hhll}  // 1,   # antes sin default -> nunca se dibujaba si no se seteaba explicitamente
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}
# -----------------------------------------------------------------------------
# render (Modificado con interruptor de bandera)
# -----------------------------------------------------------------------------
sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    my @placed;
    $self->_render_fvgs( $canvas, $scale, $src, \@placed )
        if $self->{show_fvg} && $src->can('get_fvgs');
    $self->_render_events( $canvas, $scale, $src, \@placed )
        if $self->{show_bos} || $self->{show_choch};
    $self->_render_swing_labels( $canvas, $scale, $src, \@placed )
        if $self->{show_hhll};
}
# -----------------------------------------------------------------------------
# _render_swing_labels: Dibuja los chips HH, HL, LH, LL exclusivamente 
# en los picos confirmados por el ZigZagMTF, aplicando Frustum Culling.
# -----------------------------------------------------------------------------
sub _render_swing_labels {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    
    return unless $src->can('get_swing_labels');
    my $labels = $src->get_swing_labels();
    return unless $labels && %$labels;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    for my $idx ( keys %$labels ) {
        # FRUSTUM CULLING: Ignorar etiquetas que están fuera de la pantalla actual
        next if $idx < $off || $idx > $off + $vb;
        
        my $data = $labels->{$idx};
        next unless ref $data eq 'HASH'; # Validar que tenga el nuevo formato con precio

        my $x = $scale->index_to_center_x($idx);
        
        # Doble verificación para evitar dibujar fuera de los bordes del canvas
        next if $x < 0 || $x > $plot_w;

        my $y = $scale->value_to_y( $data->{price} );
        
        # Determinar el color y posición: Techos (H) arriba, Suelos (L) abajo
        my $is_high = ($data->{kind} eq 'H');
        my $color   = $is_high ? '#ff4a68' : '#00ffaa'; # Rojo para altos, Verde para bajos
        my $place   = $is_high ? 'above'   : 'below';

        # Aprovechamos el helper _chip que ya tiene tu código
        $self->_chip( $canvas, $x, $y, $data->{label},
            -color  => $color,
            -style  => 'solid',
            -place  => $place,
            -placed => $placed 
        );
    }
}

sub _render_fvgs {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $fvgs = $src->get_fvgs or return;
    my $last_known = $src->processed_last;
    my $max_age    = 50;
    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    for my $f (@$fvgs) {
        next if $f->{state} eq 'expired';
        my $age = $last_known - $f->{created};
        next if $age > $max_age;

        my $right_idx = ( $f->{state} eq 'mitigated' && defined $f->{mitig_at} )
            ? $f->{mitig_at} : $f->{created} + $max_age;
        $right_idx = $last_known if $right_idx > $last_known;

        next if $right_idx      < $off;
        next if $f->{idx_start} > $off + $vb;
        next unless $scale->value_in_range( $f->{top} )
                 || $scale->value_in_range( $f->{bottom} )
                 || ( $f->{bottom} < $scale->{min_val}
                   && $f->{top}    > $scale->{max_val} );

        my $fresh   = 1 - ($age / $max_age);
        $fresh      = 0 if $fresh < 0;
        my $base    = ($f->{dir} eq 'bull') ? C_UP : C_DOWN;
        my $fill_op = 0.18 + 0.17 * $fresh;
        $fill_op   *= 0.55 if $f->{state} eq 'mitigated';
        my $fill    = _mix($base, $fill_op);

        my $x1 = $scale->index_to_center_x( $f->{idx_start} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $f->{top} );
        my $yb = $scale->value_to_y( $f->{bottom} );

        $canvas->createRectangle( $x1, $yt, $x2, $yb,
            -fill => $fill, -outline => $fill, -width => 0, -tags => [TAG] );

        if ( ($yb - $yt) >= 12 && $age <= int($max_age * 0.5) ) {
            my $tx = ($x1 + $x2) / 2;
            $tx = 24 if $tx < 24;
            $self->_chip( $canvas, $tx, ($yt+$yb)/2, 'FVG',
                -color => $base, -place => 'center',
                -font  => 'TkDefaultFont 6 bold', -placed => $placed );
        }
    }
}

# -----------------------------------------------------------------------------
# BOS / iBOS: linea horizontal en el nivel roto, del pivote de origen a la
# vela de ruptura, con chip SOLIDO centrado.
#   BOS  : solida, gruesa (width 2).
#   iBOS : punteada, fina (width 1), mas tenue (mezclada con fondo).
# -----------------------------------------------------------------------------
sub _render_events {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_events;
    return unless $events && @$events;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    # De mas reciente a mas antiguo: si dos chips chocan, gana el mas nuevo.
    for ( my $k = $#$events ; $k >= 0 ; $k-- ) {
        my $e = $events->[$k];
        next unless defined $e;

        my $is_choch    = ( ( $e->{type}  // '' ) eq 'CHoCH' );
        my $is_internal = ( ( $e->{scope} // 'external' ) eq 'internal' );
        next if  $is_choch              && !$self->{show_choch};
        next if !$is_choch              && !$self->{show_bos};

        my $bi = $e->{index};
        next unless defined $bi;
        next if $bi < $off || $bi > $off + $vb;
        next unless defined $e->{price} && $scale->value_in_range( $e->{price} );

        my $oi = defined $e->{origin} ? $e->{origin} : $bi - 6;
        my $x1 = $scale->index_to_center_x($oi);
        my $x2 = $scale->index_to_center_x($bi);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $y     = $scale->value_to_y( $e->{price} );
        my $dir   = $e->{dir} // 'up';
        my $base  = ( $dir eq 'up' ) ? C_UP : C_DOWN;
        my $color = $is_internal ? _mix_line($base) : $base;
        my $width = $is_choch        ? 2
                : ( !$is_internal )  ? 2
                :                       1;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill => $color, -width => $width,
            ( $is_choch || $is_internal ? ( -dash => [5,3] ) : () ),
            -tags => [TAG] );
        my $up = ( $dir eq 'up' );
        my $label;
        if ($is_choch) {
            $label = $is_internal ? 'CHoCH (int)' : 'CHoCH';
        } else {
            $label = $is_internal ? 'iBOS' : 'BOS';
        }

        $self->_chip( $canvas, ( $x1 + $x2 ) / 2, $y, $label,
            -color => $color, -style => 'solid',
            -place => ( $up ? 'above' : 'below' ), -placed => $placed );
    }
}

# -----------------------------------------------------------------------------
# _mix_line: version tenue de un color base, para iBOS (subestructura menos
# relevante que la estructura principal, no debe competir visualmente).
# -----------------------------------------------------------------------------
sub _mix_line {
    my ($hex) = @_;
    return _mix( $hex, 0.55 );
}

# -----------------------------------------------------------------------------
# _chip: etiqueta tipo TradingView.
#   -place 'above'|'below'|'center' respecto a (cx,cy); -offset separacion.
#   Anti-solape: si choca con una etiqueta ya puesta, la DESPLAZA (no la borra).
#   $placed acumula las cajas [x1,y1,x2,y2] del frame actual.
# -----------------------------------------------------------------------------
sub _chip {
    my ( $self, $canvas, $cx, $cy, $text, %o ) = @_;
    my $color  = $o{-color} // '#d6dbe6';
    my $place  = $o{-place} // 'above';
    my $off    = defined $o{-offset} ? $o{-offset} : 9;
    my $font   = $o{-font} // 'TkDefaultFont 10 bold';
    my $placed = $o{-placed};
    my $pad    = 2;

    my $ty = $place eq 'below'  ? $cy + $off
           : $place eq 'center' ? $cy
           :                      $cy - $off;

    my $tid = $canvas->createText(
        $cx, $ty, -text => $text, -anchor => 'center', -font => $font,
        -fill => '#ffffff', -tags => [TAG, TAG_LABELS] );
    my @bb = $canvas->bbox($tid);
    return unless @bb;
    my ( $x1, $y1, $x2, $y2 ) = @bb;
    $x1 -= $pad; $x2 += $pad; $y1 -= 1; $y2 += 1;

    if ($placed) {
        my $dir   = $place eq 'below' ? 1 : -1;
        my $h     = ( $y2 - $y1 ) + 2;
        my $tries = 0;
        while ( $tries++ < 6 && _box_hits( [ $x1, $y1, $x2, $y2 ], $placed ) ) {
            my $shift = $dir * $h;
            $_ += $shift for ( $y1, $y2 );
            $canvas->move( $tid, 0, $shift );
        }
        push @$placed, [ $x1, $y1, $x2, $y2 ];
    }

    my $rid = $canvas->createRectangle(
        $x1, $y1, $x2, $y2,
        -fill => $color, -outline => $color, -width => 1,
        -stipple => 'gray50', -tags => [TAG, TAG_LABELS] );
    $canvas->lower( $rid, $tid );
    return [ $x1, $y1, $x2, $y2 ];
}

sub _box_hits {
    my ( $b, $list ) = @_;
    for my $o (@$list) {
        next if $b->[2] < $o->[0] || $b->[0] > $o->[2]
             || $b->[3] < $o->[1] || $b->[1] > $o->[3];
        return 1;
    }
    return 0;
}

# -----------------------------------------------------------------------------
# _mix: mezcla un color hex con el fondo oscuro. Simula opacidad en Tk Canvas.
# -----------------------------------------------------------------------------
sub _mix {
    my ( $hex, $op ) = @_;
    $op = 0 if $op < 0;
    $op = 1 if $op > 1;
    my ( $r, $g, $b ) = ( hex( substr( $hex, 1, 2 ) ),
                          hex( substr( $hex, 3, 2 ) ),
                          hex( substr( $hex, 5, 2 ) ) );
    my $f = 1 - $op;
    my ( $br, $bg, $bb ) = ( 214, 219, 230 );
    $r = int( $r + ( $br - $r ) * $f );
    $g = int( $g + ( $bg - $g ) * $f );
    $b = int( $b + ( $bb - $b ) * $f );
    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

1;