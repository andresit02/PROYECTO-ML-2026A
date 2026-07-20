package Market::Overlays::SMC_Structures2;

# =============================================================================
# Market::Overlays::SMC_Structures2
#
# PARTE 4 / 4 -- Capa visual del motor Indicators::SMC_Structures2 (replica
# fiel del Pine "Smart Money Concepts Pro [Neon]"). NO calcula nada, solo
# dibuja lo que el indicador ya produjo.
#
# Diferencias frente al overlay viejo (Overlays/SMC_Structures.pm):
#   - Los eventos BOS/CHoCH ahora tienen scope 'swing' | 'internal' (antes
#     era 'external' | 'internal', ligado al ZigZag). 'swing' = estructura
#     principal (linea solida, gruesa). 'internal' = subestructura (linea
#     punteada, fina, color atenuado) -- mismo tratamiento visual que antes.
#   - Se agregan: EQH/EQL (linea punteada horizontal entre los dos pivotes
#     iguales + chip centrado) y Order Blocks (rectangulo desde la vela de
#     origen hasta el borde derecho visible, un color por bias).
#
# Sub-toggles independientes: show_bos_swing, show_bos_internal,
# show_choch_swing, show_choch_internal, show_fvg, show_hhll,
# show_eq, show_ob_swing, show_ob_internal.
# =============================================================================

use strict;
use warnings;

use constant TAG        => 'overlay_smc2';
use constant TAG_LABELS => 'overlay_smc2_labels';
sub tag        { return TAG; }
sub tag_labels { return TAG_LABELS; }

use constant {
    C_UP   => '#26a69a',   # alcista - verde
    C_DOWN => '#ef5350',   # bajista - rojo
    C_EQ   => '#d6b13a',   # EQH/EQL - amarillo/dorado
    C_PREM => '#ef5350',   # Premium  - mismo tono que bajista (premCol en el Pine)
    C_DISC => '#26a69a',   # Discount - mismo tono que alcista (discCol en el Pine)
    C_EQUI => '#787b86',   # Equilibrium - gris neutro (eqCol en el Pine)
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source           => $args{source},
        show_bos_swing      => $args{show_bos_swing}      // 1,
        show_bos_internal   => $args{show_bos_internal}   // 1,
        show_choch_swing    => $args{show_choch_swing}    // 1,
        show_choch_internal => $args{show_choch_internal} // 1,
        show_fvg         => $args{show_fvg}         // 1,
        show_hhll        => $args{show_hhll}        // 1,
        show_eq          => $args{show_eq}          // 1,
        show_ob_swing    => $args{show_ob_swing}    // 0,   # swOBCntInp por defecto false en el Pine
        show_ob_internal => $args{show_ob_internal} // 1,   # intOBCntInp por defecto true en el Pine
        ob_max_swing     => $args{ob_max_swing}     // 5,   # swOBCntInp
        ob_max_internal  => $args{ob_max_internal}  // 5,   # intOBCntInp

        # --- RONDA 2 / PARTE 1: filtros BOS/CHoCH por tipo y direccion ---
        # Equivalentes a intBullFilterInp/intBearFilterInp/swBullFilterInp/
        # swBearFilterInp en el Pine. Valores validos: 'all' | 'bos' | 'choch'.
        # Se aplican solo al DIBUJO (igual que en el Pine: 'show' se calcula
        # en displayStructure() pero no afecta bias/crossed), por eso viven
        # en el overlay y no en el motor.
        int_bull_filter => $args{int_bull_filter} // 'all',
        int_bear_filter => $args{int_bear_filter} // 'all',
        sw_bull_filter  => $args{sw_bull_filter}  // 'all',
        sw_bear_filter  => $args{sw_bear_filter}  // 'all',

        # --- RONDA 2 / PARTE 3: Color Candles by Trend (colorBarsInp) ---
        # No se pinta la vela real (eso vive en PricePanel, fuera del overlay);
        # se dibuja una marca vertical delgada a la izquierda de cada vela con
        # el color de tendencia interna vigente, igual informacion visual sin
        # tocar el panel de precio.
        show_trend_bars => $args{show_trend_bars} // 0,

        # --- RONDA 2 / PARTE 4: Modo Historical vs Present (modeInp) ---
        # 'historical' (default, igual que HISTORICAL en el Pine): se
        # dibujan todos los eventos/labels historicos.
        # 'present': solo el mas reciente de cada categoria (replica el
        # comportamiento de "var line/label" reutilizado en el Pine cuando
        # modeInp == PRESENT -- cada objeto se borra y se recrea, dejando
        # visible unicamente la ultima instancia).
        mode => $args{mode} // 'historical',   # 'historical' | 'present'

        # --- RONDA 2 / PARTE 5: Strong/Weak High & Low (showHLInp) ---
        show_hl => $args{show_hl} // 1,

        # --- RONDA 2 / PARTE 6: Premium/Discount/Equilibrium zones ---
        show_pd_zones => $args{show_pd_zones} // 0,   # showPDInp (false por defecto en el Pine)

        # --- RONDA 2 / PARTE 8: MTF Levels (Previous D/W/M High-Low) ---
        show_mtf => $args{show_mtf} // 0,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub set_filter {
    my ( $self, $key, $val ) = @_;
    $self->{$key} = $val;   # 'all' | 'bos' | 'choch'
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    my @placed;

    # Orden de dibujo (fondo -> frente): OB, FVG, EQH/EQL, eventos BOS/CHoCH,
    # swing labels. Asi los chips de estructura quedan por encima de las zonas.
    $self->_render_order_blocks( $canvas, $scale, $src, \@placed, 'swing' )
        if $self->{show_ob_swing} && $src->can('get_swing_order_blocks');
    $self->_render_order_blocks( $canvas, $scale, $src, \@placed, 'internal' )
        if $self->{show_ob_internal} && $src->can('get_internal_order_blocks');
    $self->_render_fvgs( $canvas, $scale, $src, \@placed )
        if $self->{show_fvg} && $src->can('get_fvgs');
    $self->_render_eq( $canvas, $scale, $src, \@placed )
        if $self->{show_eq} && $src->can('get_eq_events');
    $self->_render_events( $canvas, $scale, $src, \@placed )
        if $self->{show_bos_swing} || $self->{show_bos_internal}
        || $self->{show_choch_swing} || $self->{show_choch_internal};
    $self->_render_swing_labels( $canvas, $scale, $src, \@placed )
        if $self->{show_hhll} && $src->can('get_swing_labels');
    $self->_render_trend_bars( $canvas, $scale, $src )
        if $self->{show_trend_bars} && $src->can('get_internal_bias_at');
    $self->_render_trailing_extremes( $canvas, $scale, $src )
        if $self->{show_hl} && $src->can('get_trailing_extremes');
    $self->_render_pd_zones( $canvas, $scale, $src )
        if $self->{show_pd_zones} && $src->can('get_trailing_extremes');
    $self->_render_mtf_levels( $canvas, $scale, $src )
        if $self->{show_mtf} && $src->can('get_mtf_levels');
}

# -----------------------------------------------------------------------------
# _render_swing_labels: HH/HL/LH/LL sobre los pivotes 'swing' del motor.
# -----------------------------------------------------------------------------
sub _render_swing_labels {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;

    my $labels = $src->get_swing_labels();
    return unless $labels && %$labels;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    # RONDA 2 / PARTE 4: en modo 'present' solo se muestra el label mas
    # reciente de cada kind (H/L) -- equivalente al unico objeto label
    # reutilizado por drawLabel() en el Pine cuando modeInp == PRESENT.
    my %latest_idx_by_kind;
    if ( $self->{mode} eq 'present' ) {
        for my $idx ( keys %$labels ) {
            my $kind = $labels->{$idx}{kind} // '';
            $latest_idx_by_kind{$kind} = $idx
                if !defined $latest_idx_by_kind{$kind} || $idx > $latest_idx_by_kind{$kind};
        }
    }

    for my $idx ( keys %$labels ) {
        next if $idx < $off || $idx > $off + $vb;

        my $data = $labels->{$idx};
        next unless ref $data eq 'HASH';

        if ( $self->{mode} eq 'present' ) {
            my $kind = $data->{kind} // '';
            next unless defined $latest_idx_by_kind{$kind} && $latest_idx_by_kind{$kind} == $idx;
        }

        my $x = $scale->index_to_center_x($idx);
        next if $x < 0 || $x > $plot_w;

        my $y = $scale->value_to_y( $data->{price} );

        my $is_high = ( $data->{kind} eq 'H' );
        my $color   = $is_high ? '#ff4a68' : '#00ffaa';
        my $place   = $is_high ? 'above'   : 'below';

        $self->_chip( $canvas, $x, $y, $data->{label},
            -color  => $color,
            -style  => 'solid',
            -place  => $place,
            -placed => $placed );
    }
}

# -----------------------------------------------------------------------------
# _render_eq: EQH/EQL -- linea punteada horizontal desde el pivote anterior
# hasta el nuevo, con chip 'EQH'/'EQL' centrado (igual criterio visual que
# drawEqualHighLow() en el Pine: line.style_dotted + label centrado).
# -----------------------------------------------------------------------------
sub _render_eq {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_eq_events;
    return unless $events && @$events;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    # RONDA 2 / PARTE 4: en modo 'present' solo el mas reciente por kind
    # (EQH/EQL), igual criterio que equalHighDisplay/equalLowDisplay (un
    # unico objeto reutilizado) en el Pine.
    my %latest_k_by_kind;
    if ( $self->{mode} eq 'present' ) {
        for my $k ( 0 .. $#$events ) {
            my $kind = $events->[$k]{kind} // '';
            $latest_k_by_kind{$kind} = $k
                if !defined $latest_k_by_kind{$kind} || $events->[$k]{idx_to} > $events->[ $latest_k_by_kind{$kind} ]{idx_to};
        }
    }

    for my $k ( 0 .. $#$events ) {
        my $e = $events->[$k];
        if ( $self->{mode} eq 'present' ) {
            my $kind = $e->{kind} // '';
            next unless defined $latest_k_by_kind{$kind} && $latest_k_by_kind{$kind} == $k;
        }

        my $i1 = $e->{idx_from};
        my $i2 = $e->{idx_to};
        next unless defined $i1 && defined $i2;
        next if $i2 < $off || $i1 > $off + $vb;

        next unless $scale->value_in_range( $e->{price} )
                 || $scale->value_in_range( $e->{level_from} );

        my $x1 = $scale->index_to_center_x($i1);
        my $x2 = $scale->index_to_center_x($i2);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $y1 = $scale->value_to_y( $e->{level_from} );
        my $y2 = $scale->value_to_y( $e->{price} );

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill => C_EQ, -width => 1, -dash => [2,3],
            -tags => [TAG] );

        my $is_high = ( $e->{kind} eq 'EQH' );
        $self->_chip( $canvas, ( $x1 + $x2 ) / 2, ( $y1 + $y2 ) / 2, $e->{kind},
            -color => C_EQ, -style => 'solid',
            -place => ( $is_high ? 'above' : 'below' ), -placed => $placed );
    }
}

# -----------------------------------------------------------------------------
# _render_fvgs: identico criterio visual al overlay viejo (rectangulo con
# opacidad decreciente por antiguedad, chip 'FVG' si hay espacio).
# -----------------------------------------------------------------------------
sub _render_fvgs {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $fvgs = $src->get_fvgs or return;
    my $last_known = $src->processed_last;
    my $max_age    = 50;
    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    for my $f (@$fvgs) {
        # FVG mitigado: desaparece de inmediato (igual que TradingView por
        # defecto), en vez de seguir dibujandose atenuado.
        next if $f->{state} eq 'mitigated';

        my $age = $last_known - $f->{created};
        next if $age > $max_age;

        my $right_idx = $f->{created} + $max_age;
        $right_idx = $last_known if $right_idx > $last_known;

        next if $right_idx      < $off;
        next if $f->{idx_start} > $off + $vb;
        next unless $scale->value_in_range( $f->{top} )
                 || $scale->value_in_range( $f->{bottom} )
                 || ( $f->{bottom} < $scale->{min_val}
                   && $f->{top}    > $scale->{max_val} );

        my $fresh   = 1 - ( $age / $max_age );
        $fresh      = 0 if $fresh < 0;
        my $base    = ( $f->{dir} eq 'bull' ) ? C_UP : C_DOWN;
        my $fill_op = 0.18 + 0.17 * $fresh;
        my $fill    = _mix( $base, $fill_op );

        my $x1 = $scale->index_to_center_x( $f->{idx_start} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $f->{top} );
        my $yb = $scale->value_to_y( $f->{bottom} );

        $canvas->createRectangle( $x1, $yt, $x2, $yb,
            -fill => $fill, -outline => $fill, -width => 0, -tags => [TAG] );

        if ( ( $yb - $yt ) >= 12 && $age <= int( $max_age * 0.5 ) ) {
            my $tx = ( $x1 + $x2 ) / 2;
            $tx = 24 if $tx < 24;
            $self->_chip( $canvas, $tx, ( $yt + $yb ) / 2, 'FVG',
                -color => $base, -place => 'center',
                -font  => 'TkDefaultFont 6 bold', -placed => $placed );
        }
    }
}

# -----------------------------------------------------------------------------
# _render_order_blocks: rectangulo desde la vela de origen (barIndex) hasta
# el borde derecho visible, igual que drawOrderBlocks() en el Pine (extend
# a la derecha). $scope = 'swing' | 'internal'.
# -----------------------------------------------------------------------------
sub _render_order_blocks {
    my ( $self, $canvas, $scale, $src, $placed, $scope ) = @_;
    my $obs = $scope eq 'swing' ? $src->get_swing_order_blocks : $src->get_internal_order_blocks;
    return unless $obs && @$obs;

    my $max = $scope eq 'swing' ? $self->{ob_max_swing} : $self->{ob_max_internal};
    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $right_idx = $off + $vb;   # extend.right -> hasta el borde visible

    my $n = 0;
    for my $ob (@$obs) {
        last if ++$n > $max;
        next unless defined $ob->{barIndex};
        next if $ob->{barIndex} > $off + $vb;

        next unless $scale->value_in_range( $ob->{barHigh} )
                 || $scale->value_in_range( $ob->{barLow} )
                 || ( $ob->{barLow} < $scale->{min_val} && $ob->{barHigh} > $scale->{max_val} );

        my $x1 = $scale->index_to_center_x( $ob->{barIndex} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $ob->{barHigh} );
        my $yb = $scale->value_to_y( $ob->{barLow} );

        my $base = ( $ob->{bias} eq 'bull' ) ? C_UP : C_DOWN;
        my $op   = $scope eq 'internal' ? 0.10 : 0.16;
        my $fill = _mix( $base, $op );

        $canvas->createRectangle( $x1, $yt, $x2, $yb,
            -fill => $fill, -outline => $base, -width => 1, -tags => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# _render_events: BOS/CHoCH swing (linea solida gruesa) e internal (punteada
# fina, color atenuado). Mismo criterio visual que el overlay viejo.
# -----------------------------------------------------------------------------
sub _render_events {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_events;
    return unless $events && @$events;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    # RONDA 2 / PARTE 4: en modo 'present' solo se dibuja el evento mas
    # reciente de cada combinacion scope|dir (equivalente a que el Pine
    # reutilice un unico "var line/label" por rama de displayStructure()).
    my $latest_idx;
    if ( $self->{mode} eq 'present' ) {
        $latest_idx = {};
        for my $k ( 0 .. $#$events ) {
            my $e = $events->[$k];
            next unless defined $e && defined $e->{index};
            my $key = ( $e->{scope} // 'swing' ) . '|' . ( $e->{dir} // 'up' );
            $latest_idx->{$key} = $k
                if !defined $latest_idx->{$key} || $e->{index} > $events->[ $latest_idx->{$key} ]{index};
        }
    }

    for ( my $k = $#$events ; $k >= 0 ; $k-- ) {
        my $e = $events->[$k];
        next unless defined $e;

        my $is_choch    = ( ( $e->{type}  // '' ) eq 'CHoCH' );
        my $is_internal = ( ( $e->{scope} // 'swing' ) eq 'internal' );
        if ($is_choch) {
            next if  $is_internal && !$self->{show_choch_internal};
            next if !$is_internal && !$self->{show_choch_swing};
        } else {
            next if  $is_internal && !$self->{show_bos_internal};
            next if !$is_internal && !$self->{show_bos_swing};
        }

        if ( $self->{mode} eq 'present' ) {
            my $key = ( $e->{scope} // 'swing' ) . '|' . ( $e->{dir} // 'up' );
            next unless defined $latest_idx->{$key} && $latest_idx->{$key} == $k;
        }

        my $dir_up = ( ( $e->{dir} // 'up' ) eq 'up' );
        my $filter_key = $is_internal
            ? ( $dir_up ? 'int_bull_filter' : 'int_bear_filter' )
            : ( $dir_up ? 'sw_bull_filter'  : 'sw_bear_filter' );
        my $filt = $self->{$filter_key} // 'all';
        my $tag_choch = $is_choch ? 'choch' : 'bos';
        next unless $filt eq 'all'
                 || ( $filt eq 'bos'   && $tag_choch eq 'bos' )
                 || ( $filt eq 'choch' && $tag_choch eq 'choch' );

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
            ( $is_internal ? ( -dash => [5,3] ) : () ),
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

sub _mix_line {
    my ($hex) = @_;
    return _mix( $hex, 0.55 );
}

# -----------------------------------------------------------------------------
# _render_mtf_levels: RONDA 2 / PARTE 8 -- Previous D/W/M High/Low.
# Linea horizontal desde la vela de origen (top_index/bottom_index) hasta el
# borde derecho visible, con chip 'PDH'/'PDL', 'PWH'/'PWL', 'PMH'/'PML'.
# -----------------------------------------------------------------------------
sub _render_mtf_levels {
    my ( $self, $canvas, $scale, $src ) = @_;
    my $levels = $src->get_mtf_levels;
    return unless $levels && %$levels;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $right_idx = $off + $vb;
    my $col = '#c9a24b';   # accentCol aproximado del Pine

    my @placed;

    for my $unit (qw(D W M)) {
        my $lv = $levels->{$unit} or next;

        for my $side (qw(top bottom)) {
            my $price = $lv->{$side};
            next unless defined $price && $scale->value_in_range($price);

            my $origin_idx = $side eq 'top' ? $lv->{top_index} : $lv->{bottom_index};
            my $x1 = $scale->index_to_center_x($origin_idx);
            my $x2 = $scale->index_to_center_x($right_idx);
            $x1 = 0       if $x1 < 0;
            $x2 = $plot_w if $x2 > $plot_w;
            next if $x2 <= $x1;

            my $y = $scale->value_to_y($price);
            $canvas->createLine( $x1, $y, $x2, $y,
                -fill => $col, -width => 1, -dash => [3,2], -tags => [TAG] );

            my $label = 'P' . $unit . ( $side eq 'top' ? 'H' : 'L' );
            $self->_chip( $canvas, $x2 - 22, $y, $label,
                -color => $col, -place => ( $side eq 'top' ? 'above' : 'below' ),
                -placed => \@placed, -font => 'TkDefaultFont 7 bold' );
        }
    }
}

# -----------------------------------------------------------------------------
# _render_pd_zones: RONDA 2 / PARTE 6 -- Premium / Discount / Equilibrium.
# Replica drawPremiumDiscountZones() del Pine:
#   Premium:     top..(0.95*top+0.05*bottom)          desde trailing.barIndex hasta ultima vela
#   Equilibrium: (0.525*top+0.475*bottom)..(0.525*bottom+0.475*top)  idem
#   Discount:    (0.95*bottom+0.05*top)..bottom        idem
# Las 3 zonas comparten el mismo borde izquierdo: trailing.barIndex (origen
# del ultimo pivote swing HIGH, igual que en el Pine -- un solo campo
# compartido, no el origen del bottom).
# -----------------------------------------------------------------------------
sub _render_pd_zones {
    my ( $self, $canvas, $scale, $src ) = @_;
    my $t = $src->get_trailing_extremes;
    return unless $t && defined $t->{top_origin_index};

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $last   = $src->processed_last;

    my $x1 = $scale->index_to_center_x( $t->{top_origin_index} );
    my $x2 = $scale->index_to_center_x($last);
    $x1 = 0       if $x1 < 0;
    $x2 = $plot_w if $x2 > $plot_w;
    return if $x2 <= $x1;

    my $top = $t->{top};
    my $bot = $t->{bottom};

    my @zones = (
        [ $top,                              0.95 * $top + 0.05 * $bot, C_PREM, 'Premium'     ],
        [ 0.525 * $top + 0.475 * $bot,        0.525 * $bot + 0.475 * $top, C_EQUI, 'Equilibrium' ],
        [ 0.95 * $bot + 0.05 * $top,          $bot,                      C_DISC, 'Discount'    ],
    );

    for my $z (@zones) {
        my ( $ztop, $zbot, $col, $label ) = @$z;
        next unless $scale->value_in_range($ztop) || $scale->value_in_range($zbot)
                 || ( $zbot < $scale->{min_val} && $ztop > $scale->{max_val} );

        my $yt = $scale->value_to_y($ztop);
        my $yb = $scale->value_to_y($zbot);

        $canvas->createRectangle( $x1, $yt, $x2, $yb,
            -fill => _mix( $col, 0.08 ), -outline => '', -width => 0, -tags => [TAG] );

        if ( ( $yb - $yt ) >= 10 ) {
            $canvas->createText( $x1 + 4, ( $yt + $yb ) / 2,
                -text => $label, -anchor => 'w', -fill => $col,
                -font => 'TkDefaultFont 7 bold', -tags => [TAG] );
        }
    }
}

# -----------------------------------------------------------------------------
# _render_trailing_extremes: RONDA 2 / PARTE 5 -- Strong/Weak High & Low.
# Linea horizontal punteada desde la ultima vela en que se extendio el
# extremo (trailing.lastTopTime / lastBottomTime en el Pine) hasta el borde
# derecho visible, con chip 'Strong High'/'Weak High' y 'Strong Low'/'Weak Low'.
# -----------------------------------------------------------------------------
sub _render_trailing_extremes {
    my ( $self, $canvas, $scale, $src ) = @_;
    my $t = $src->get_trailing_extremes;
    return unless $t;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $right_idx = $off + $vb;

    my @placed;   # anti-solape local entre los dos chips (top/bottom)

    if ( defined $t->{top_last_index} && $scale->value_in_range( $t->{top} ) ) {
        my $x1 = $scale->index_to_center_x( $t->{top_last_index} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        if ( $x2 > $x1 ) {
            my $y = $scale->value_to_y( $t->{top} );
            $canvas->createLine( $x1, $y, $x2, $y,
                -fill => C_DOWN, -width => 1, -dash => [4,3], -tags => [TAG] );
            $self->_chip( $canvas, $x2 - 30, $y, $t->{top_label},
                -color => C_DOWN, -place => 'above', -placed => \@placed,
                -font => 'TkDefaultFont 8 bold' );
        }
    }

    if ( defined $t->{bot_last_index} && $scale->value_in_range( $t->{bottom} ) ) {
        my $x1 = $scale->index_to_center_x( $t->{bot_last_index} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        if ( $x2 > $x1 ) {
            my $y = $scale->value_to_y( $t->{bottom} );
            $canvas->createLine( $x1, $y, $x2, $y,
                -fill => C_UP, -width => 1, -dash => [4,3], -tags => [TAG] );
            $self->_chip( $canvas, $x2 - 30, $y, $t->{bot_label},
                -color => C_UP, -place => 'below', -placed => \@placed,
                -font => 'TkDefaultFont 8 bold' );
        }
    }
}

# -----------------------------------------------------------------------------
# _render_trend_bars: RONDA 2 / PARTE 3 -- marca vertical delgada a la
# izquierda de cada vela visible, coloreada segun internalTrend.bias
# (BULLISH=1 -> verde, BEARISH=-1 -> rojo). Ancho fijo pequeno, no interfiere
# con el cuerpo de la vela real dibujada por PricePanel.
# -----------------------------------------------------------------------------
sub _render_trend_bars {
    my ( $self, $canvas, $scale, $src ) = @_;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $last   = $src->processed_last;

    my $bar_w  = $plot_w / ( $vb > 0 ? $vb : 1 );

    my $from = $off < 0 ? 0 : int($off);
    my $to   = $off + $vb;
    $to = $last if $to > $last;

    for my $idx ( $from .. $to ) {
        my $bias = $src->get_internal_bias_at($idx);
        next unless defined $bias;

        my $c = $src->get_candle_at($idx);
        next unless $c;

        my $cx = $scale->index_to_center_x($idx);
        next if $cx < 0 || $cx > $plot_w;

        next unless $scale->value_in_range( $c->{high} ) || $scale->value_in_range( $c->{low} )
                 || ( $c->{low} < $scale->{min_val} && $c->{high} > $scale->{max_val} );

        my $y_high = $scale->value_to_y( $c->{high} );
        my $y_low  = $scale->value_to_y( $c->{low} );

        my $color = ( $bias == 1 ) ? C_UP : C_DOWN;
        my $x = $cx - $bar_w * 0.45;

        $canvas->createLine( $x, $y_high, $x, $y_low,
            -fill => $color, -width => 2, -tags => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# _chip: etiqueta tipo TradingView (identico al overlay viejo).
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