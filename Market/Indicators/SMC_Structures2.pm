package Market::Indicators::SMC_Structures2;

# =============================================================================
# Market::Indicators::SMC_Structures2
#
# PARTE 1 / 4 -- Motor puro de estructura SMC, replica 1:1 de la logica del
# script Pine "Smart Money Concepts Pro [Neon]" (LuxAlgo, v6), SECCIONES:
#   - leg() / startOfNewLeg() / startOfBullishLeg() / startOfBearishLeg()
#   - getCurrentStructure() (deteccion y almacenamiento de pivotes)
#   - displayStructure()    (cruce de precio -> BOS / CHoCH)
#
# DIFERENCIA CLAVE con el modulo SMC_Structures.pm anterior: este modulo NO
# recibe zzmtf ni zzvp. Tiene su propia deteccion de "leg" (pierna) igual
# que el Pine, totalmente autonoma, para dos tamanios de ventana en paralelo:
#   - swing   (size = swLen, default 50)  -> "estructura externa/swing"
#   - internal(size = 5)                  -> "estructura interna"
# Cada una tiene su propio pivot swingHigh/swingLow, internalHigh/internalLow
# y su propio trend.bias (BULLISH/BEARISH), tal como en el Pine original.
#
# FVG, Equal H/L y Order Blocks se agregan en partes posteriores.
# =============================================================================

use strict;
use warnings;
use Time::Moment;

use constant GMT_OFFSET_MIN => -300;   # mismo offset que Market::MarketData (UTC-5)

use constant {
    BULLISH_LEG => 1,
    BEARISH_LEG => 0,
    BULLISH     => 1,
    BEARISH     => -1,
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        swing_len   => $args{swing_len}   // 50,   # swLenInp
        internal_len=> $args{internal_len}// 5,    # tamanio fijo interno (Pine: getCurrentStructure(5,...))
        break_mode  => $args{break_mode}  // 'close', # 'close' (ta.crossover/under de close) -- el Pine SIEMPRE usa close

        # --- RONDA 2 / PARTE 2: Internal Confluence Filter (intConflInp) ---
        # Solo afecta la rama internal de displayStructure(). Cuando esta
        # activo, un BOS/CHoCH interno solo se confirma si ademas de cruzar
        # el nivel, el nivel interno difiere del nivel swing Y la vela actual
        # tiene la "forma" correcta (bullishBar/bearishBar, ver _confluence_ok).
        int_confluence => $args{int_confluence} // 0,   # intConflInp

        _c      => [],    # velas procesadas (array de {open,high,low,close,ts})
        _events => [],    # eventos BOS/CHoCH confirmados (swing + internal)

        # --- estado leg() por ventana (equivalente a "var int legState = 0") ---
        _leg_state_swing    => 0,
        _leg_state_internal => 0,
        _prev_leg_swing     => undef,   # para ta.change(legV)
        _prev_leg_internal  => undef,

        # --- pivotes (equivalente a "type pivot") ---
        # currentLevel, lastLevel, crossed, barIndex (indice de vela real)
        _swing_high    => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _swing_low     => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _internal_high => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _internal_low  => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },

        # --- trend bias por ventana ---
        _swing_bias    => undef,   # BULLISH | BEARISH | undef
        _internal_bias => undef,

        # --- swing labels HH/HL/LH/LL (solo lado "swing", igual que showSwingsInp) ---
        _swing_labels => {},   # idx_vela => { label, price, kind }

        # --- PARTE 2: Equal High / Low (equalHL branch de getCurrentStructure) ---
        eq_len     => $args{eq_len}     // 3,     # eqLenInp (size de la ventana equalHL)
        eq_thresh  => $args{eq_thresh}  // 0.1,   # eqThreshInp (mult. ATR)
        atr        => $args{atr},                  # objeto Indicators::ATR (opcional; ver _atr_at)
        _leg_state_eq => 0,
        _prev_leg_eq  => undef,
        _equal_high => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _equal_low  => { currentLevel => undef, lastLevel => undef, crossed => 0, barIndex => undef },
        _eq_events  => [],   # { kind=>'EQH'|'EQL', idx_from, idx_to, price, ts }

        # --- PARTE 2: Fair Value Gaps ---
        fvg_auto_thresh => $args{fvg_auto_thresh} // 1,   # fvgAutoTInp
        fvg_extend      => $args{fvg_extend}      // 1,   # fvgExtInp (en barras)
        _fvgs        => [],   # historial completo (para overlay / stats)
        _active_fvgs => [],   # aun no mitigados/borrados
        _fvg_delta_cum => 0,  # ta.cum(abs(deltaPct)) acumulado

        # --- PARTE 3: Order Blocks (storeOrderBlock / deleteOrderBlocks) ---
        ob_filter    => $args{ob_filter}    // 'atr',    # 'atr' | 'range' (obFilterInp)
        ob_mitig_src => $args{ob_mitig_src} // 'highlow',# 'close' | 'highlow' (obMitigInp)
        atr_len      => $args{atr_len}      // 200,      # atrLenInp
        swing_ob_max    => $args{swing_ob_max}    // 100, # obs.size() >= 100 -> pop() en el Pine
        internal_ob_max => $args{internal_ob_max} // 100,
        _swing_obs    => [],   # unshift -- mas reciente primero, igual que el Pine
        _internal_obs => [],
        _tr_cum       => 0,    # ta.cum(ta.tr) acumulado, para obFilterInp='range'
        _ob_mit_events => [],  # RONDA 2 / PARTE 7: eventos de mitigacion OB

        # --- RONDA 2 / PARTE 8: MTF Levels (Previous D/W/M High-Low) ---
        mtf_show_daily   => $args{mtf_show_daily}   // 1,   # showDInp
        mtf_show_weekly  => $args{mtf_show_weekly}  // 1,   # showWInp
        mtf_show_monthly => $args{mtf_show_monthly} // 1,   # showMInp
        _parsed_highs => [],
        _parsed_lows  => [],
        _internal_bias_hist => [],   # bias interno vigente tras procesar cada vela (Parte 3)

        # --- RONDA 2 / PARTE 5: Strong/Weak High & Low (trailingExtremes) ---
        # trailing.top/bottom se resetean al valor del pivote SWING recien
        # detectado (currentLevel) y luego, en cada vela, se extienden con
        # max(high, top) / min(low, bottom). El label (Strong/Weak) depende
        # del swingTrend.bias vigente en la ULTIMA vela procesada, por eso
        # se expone como accesor calculado on-demand (get_trailing_extremes)
        # en vez de guardarse como texto fijo.
        _trailing_top            => undef,
        _trailing_bottom         => undef,
        _trailing_bar_index      => undef,   # vela de origen del top actual (para 'trailing.barTime')
        _trailing_bar_index_bot  => undef,   # vela de origen del bottom actual
        _trailing_last_top_idx   => undef,   # ultima vela en que top fue igualado/extendido
        _trailing_last_bot_idx   => undef,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_events} = [];
    $self->{_leg_state_swing}    = 0;
    $self->{_leg_state_internal} = 0;
    $self->{_prev_leg_swing}     = undef;
    $self->{_prev_leg_internal}  = undef;
    $_->{currentLevel} = undef, $_->{lastLevel} = undef, $_->{crossed} = 0, $_->{barIndex} = undef
        for ( $self->{_swing_high}, $self->{_swing_low}, $self->{_internal_high}, $self->{_internal_low} );
    $self->{_swing_bias}    = undef;
    $self->{_internal_bias} = undef;
    $self->{_swing_labels}  = {};
    $self->{_internal_bias_hist} = [];
    $self->{_trailing_top} = undef;
    $self->{_trailing_bottom} = undef;
    $self->{_trailing_bar_index} = undef;
    $self->{_trailing_bar_index_bot} = undef;
    $self->{_trailing_last_top_idx} = undef;
    $self->{_trailing_last_bot_idx} = undef;
    $self->{_ob_mit_events} = [];

    # --- FIX: faltaba limpiar el estado de Equal High/Low, FVG y Order
    # Blocks al hacer reset(). Al cambiar de timeframe el motor se
    # recalcula desde _c=[] pero estos arrays/pivotes seguian con datos
    # del timeframe anterior, causando que las lineas EQH/EQL (y OB/FVG)
    # viejas quedaran dibujadas superpuestas con las nuevas.
    $self->{_leg_state_eq} = 0;
    $self->{_prev_leg_eq}  = undef;
    $_->{currentLevel} = undef, $_->{lastLevel} = undef, $_->{crossed} = 0, $_->{barIndex} = undef
        for ( $self->{_equal_high}, $self->{_equal_low} );
    $self->{_eq_events} = [];

    $self->{_fvgs}         = [];
    $self->{_active_fvgs}  = [];
    $self->{_fvg_delta_cum} = 0;

    $self->{_swing_obs}    = [];
    $self->{_internal_obs} = [];
    $self->{_tr_cum}       = 0;

    $self->{_parsed_highs} = [];
    $self->{_parsed_lows}  = [];
}

sub get_values { return []; }

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_process($c);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $c = $md->last_candle;
    return unless defined $c;
    $self->_process($c);
}

# Accesores de solo lectura para el Overlay (Parte 4).
sub get_events       { return $_[0]->{_events}; }
sub processed_last   { return $#{ $_[0]->{_c} }; }
sub get_swing_labels { return $_[0]->{_swing_labels}; }
sub get_candle_at    { return $_[0]->{_c}[ $_[1] ]; }

# -----------------------------------------------------------------------------
# _process: integra una vela nueva. i = indice de la vela recien agregada.
# -----------------------------------------------------------------------------
sub _process {
    my ( $self, $c ) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };

    # ---- PARTE 3: volatilidad / parsedHigh-Low (para Order Blocks) ----
    # highVolatilityBar = (high-low) >= 2*volMeasure ; si es vela muy volatil,
    # el Pine invierte high/low al buscar el extremo "limpio" del bloque OB.
    my $vol_measure = $self->{ob_filter} eq 'range'
        ? $self->_range_measure($i)
        : $self->_atr_at($i, $self->{atr_len});
    $vol_measure //= 0;
    my $high_vol_bar = ( $c->{high} - $c->{low} ) >= ( 2 * $vol_measure );
    my $parsed_high  = $high_vol_bar ? $c->{low}  : $c->{high};
    my $parsed_low   = $high_vol_bar ? $c->{high} : $c->{low};
    push @{ $self->{_parsed_highs} }, $parsed_high;
    push @{ $self->{_parsed_lows} },  $parsed_low;

    # Orden identico al Pine: getCurrentStructure(swing) -> getCurrentStructure(internal)
    # -> displayStructure(internal) -> displayStructure(swing).
    # (En el Pine el orden real de llamada es: getCurrentStructure(swLen,false,false),
    #  getCurrentStructure(5,false,true), luego displayStructure(true), displayStructure(false).
    #  Se respeta ese mismo orden aqui.)
    $self->_get_current_structure( $i, $self->{swing_len},    0, 0 );  # swing
    $self->_get_current_structure( $i, $self->{internal_len}, 0, 1 );  # internal
    $self->_get_current_structure( $i, $self->{eq_len},       1, 0 );  # equalHL (Parte 2)

    # RONDA 2 / PARTE 5: extension continua de trailing.top/bottom
    # (Pine: trailing.top := max(high, trailing.top), etc. -- corre en
    # CADA vela, no solo al detectar un pivote nuevo).
    if ( defined $self->{_trailing_top} ) {
        if ( $c->{high} >= $self->{_trailing_top} ) {
            $self->{_trailing_top}          = $c->{high};
            $self->{_trailing_last_top_idx} = $i;
        }
    }
    if ( defined $self->{_trailing_bottom} ) {
        if ( $c->{low} <= $self->{_trailing_bottom} ) {
            $self->{_trailing_bottom}       = $c->{low};
            $self->{_trailing_last_bot_idx} = $i;
        }
    }

    $self->_delete_order_blocks( $i, 1 );  # internal -- deleteOrderBlocks() corre ANTES del display en el Pine
    $self->_delete_order_blocks( $i, 0 );  # swing

    $self->_display_structure( $i, 1 );  # internal
    $self->_display_structure( $i, 0 );  # swing

    $self->_update_fvgs($i);   # deleteFairValueGaps() -- mitigar/expirar antes de detectar
    $self->_detect_fvg($i);    # drawFairValueGaps()   -- Parte 2

    push @{ $self->{_internal_bias_hist} }, $self->{_internal_bias};  # Parte 3
}

# -----------------------------------------------------------------------------
# leg(size): replica exacta de la funcion Pine "leg()".
#   bool newHigh = high[size] > ta.highest(size)   -- highest de las ULTIMAS
#                                                      `size` velas SIN contar high[size]
#   bool newLow  = low[size]  < ta.lowest(size)
# En Pine, dentro de una funcion definida con parametro size, "ta.highest(size)"
# usa el size como length: el maximo de las ultimas `size` velas (barras 0..size-1
# relativas a la vela actual, es decir [i-size+1 .. i]), y high[size] es el high
# de la vela ubicada `size` barras atras (i-size).
# -----------------------------------------------------------------------------
sub _leg_raw {
    my ( $self, $i, $size ) = @_;
    my $c = $self->{_c};
    return undef if $i - $size < 0;          # high[size] / low[size] no existen aun
    return undef if $i - $size + 1 < 0;

    my $ref_idx = $i - $size;                # high[size], low[size]
    my $win_from = $i - $size + 1;            # ventana de `size` velas: [i-size+1 .. i]
    my $win_to   = $i;
    return undef if $win_from < 0;

    my ( $hi_max, $lo_min );
    for my $k ( $win_from .. $win_to ) {
        my $h = $c->[$k]{high};
        my $l = $c->[$k]{low};
        $hi_max = $h if !defined $hi_max || $h > $hi_max;
        $lo_min = $l if !defined $lo_min || $l < $lo_min;
    }

    my $high_size = $c->[$ref_idx]{high};
    my $low_size  = $c->[$ref_idx]{low};

    my $new_high = $high_size > $hi_max;
    my $new_low  = $low_size  < $lo_min;

    return { new_high => $new_high, new_low => $new_low };
}

# -----------------------------------------------------------------------------
# _get_current_structure: replica "getCurrentStructure(size, equalHL, internal)"
# sin la parte equalHL (eso es Parte 2 / Equal High-Low). internal=0 -> swing.
# -----------------------------------------------------------------------------
sub _get_current_structure {
    my ( $self, $i, $size, $equal_hl, $internal ) = @_;

    my $raw = $self->_leg_raw( $i, $size );
    return unless $raw;   # todavia no hay suficientes velas

    my ( $state_key, $prev_key ) = $equal_hl
        ? ( '_leg_state_eq', '_prev_leg_eq' )
        : $internal
        ? ( '_leg_state_internal', '_prev_leg_internal' )
        : ( '_leg_state_swing',    '_prev_leg_swing' );

    my $leg_state = $self->{$state_key};
    if ( $raw->{new_high} ) {
        $leg_state = BEARISH_LEG;
    }
    elsif ( $raw->{new_low} ) {
        $leg_state = BULLISH_LEG;
    }
    my $prev_leg = $self->{$prev_key};
    $self->{$prev_key}  = $leg_state;
    $self->{$state_key} = $leg_state;

    return unless defined $prev_leg;               # ta.change() necesita valor previo
    my $changed = ( $leg_state != $prev_leg );
    return unless $changed;                          # startOfNewLeg()

    my $is_low  = ( $leg_state - $prev_leg ) == 1;   # startOfBullishLeg: change == +1
    my $is_high = ( $leg_state - $prev_leg ) == -1;  # startOfBearishLeg: change == -1

    my $ref_idx = $i - $size;   # indice real de la vela de referencia (equivalente a [size] en Pine)
    my $c = $self->{_c};

    if ($is_low) {
        my $p = $equal_hl ? $self->{_equal_low} : $internal ? $self->{_internal_low} : $self->{_swing_low};

        if ($equal_hl) {
            my $low_ref = $c->[$ref_idx]{low};
            if ( defined $p->{currentLevel} ) {
                my $atr_val = $self->_atr_at($i);
                if ( defined $atr_val && abs( $p->{currentLevel} - $low_ref ) < $self->{eq_thresh} * $atr_val ) {
                    push @{ $self->{_eq_events} }, {
                        kind     => 'EQL',
                        idx_from => $p->{barIndex},
                        idx_to   => $ref_idx,
                        price    => $low_ref,
                        level_from => $p->{currentLevel},
                        ts       => $c->[$i]{ts},
                    };
                }
            }
        }

        $p->{lastLevel}    = $p->{currentLevel};
        $p->{currentLevel} = $c->[$ref_idx]{low};
        $p->{crossed}      = 0;
        $p->{barIndex}     = $ref_idx;

        if ( !$internal && !$equal_hl ) {
            # RONDA 2 / PARTE 5: reset de trailing.bottom (Strong/Weak Low)
            $self->{_trailing_bottom}        = $p->{currentLevel};
            $self->{_trailing_bar_index_bot} = $ref_idx;
            $self->{_trailing_last_bot_idx}  = $ref_idx;

            my $label = ( defined $p->{lastLevel} && $p->{currentLevel} < $p->{lastLevel} ) ? 'LL' : 'HL';
            $self->{_swing_labels}{$ref_idx} = {
                label => $label, price => $p->{currentLevel}, kind => 'L',
            };
        }
    }
    elsif ($is_high) {
        my $p = $equal_hl ? $self->{_equal_high} : $internal ? $self->{_internal_high} : $self->{_swing_high};

        if ($equal_hl) {
            my $high_ref = $c->[$ref_idx]{high};
            if ( defined $p->{currentLevel} ) {
                my $atr_val = $self->_atr_at($i);
                if ( defined $atr_val && abs( $p->{currentLevel} - $high_ref ) < $self->{eq_thresh} * $atr_val ) {
                    push @{ $self->{_eq_events} }, {
                        kind     => 'EQH',
                        idx_from => $p->{barIndex},
                        idx_to   => $ref_idx,
                        price    => $high_ref,
                        level_from => $p->{currentLevel},
                        ts       => $c->[$i]{ts},
                    };
                }
            }
        }

        $p->{lastLevel}    = $p->{currentLevel};
        $p->{currentLevel} = $c->[$ref_idx]{high};
        $p->{crossed}      = 0;
        $p->{barIndex}     = $ref_idx;

        if ( !$internal && !$equal_hl ) {
            # RONDA 2 / PARTE 5: reset de trailing.top (Strong/Weak High)
            $self->{_trailing_top}       = $p->{currentLevel};
            $self->{_trailing_bar_index} = $ref_idx;
            $self->{_trailing_last_top_idx} = $ref_idx;

            my $label = ( defined $p->{lastLevel} && $p->{currentLevel} > $p->{lastLevel} ) ? 'HH' : 'LH';
            $self->{_swing_labels}{$ref_idx} = {
                label => $label, price => $p->{currentLevel}, kind => 'H',
            };
        }
    }
}

# -----------------------------------------------------------------------------
# _atr_at: ATR en la vela $i. Si se paso un objeto Indicators::ATR (con
# get_values devolviendo un array paralelo a las velas), se usa ese valor.
# Si no hay ATR inyectado, se calcula un ATR(14) simple internamente (fallback)
# para que Equal H/L funcione igual sin depender de un modulo externo.
# -----------------------------------------------------------------------------
sub _atr_at {
    my ( $self, $i, $period ) = @_;
    if ( !defined $period && $self->{atr} && $self->{atr}->can('get_values') ) {
        my $vals = $self->{atr}->get_values;
        return $vals->[$i] if $vals && defined $vals->[$i];
    }
    return $self->_fallback_atr( $i, $period );
}

sub _fallback_atr {
    my ( $self, $i, $period ) = @_;
    $period //= 14;
    return undef if $i < 1;
    my $c = $self->{_c};
    my $from = $i - $period + 1;
    $from = 1 if $from < 1;
    my $sum = 0; my $n = 0;
    for my $k ( $from .. $i ) {
        my $cur  = $c->[$k];
        my $prev = $c->[$k-1];
        my $tr = _true_range( $cur, $prev );
        $sum += $tr; $n++;
    }
    return $n > 0 ? $sum / $n : undef;
}

sub _true_range {
    my ( $cur, $prev ) = @_;
    my @vals = (
        $cur->{high} - $cur->{low},
        abs( $cur->{high} - $prev->{close} ),
        abs( $cur->{low}  - $prev->{close} ),
    );
    my $tr = $vals[0];
    for (@vals) { $tr = $_ if $_ > $tr; }
    return $tr;
}

# -----------------------------------------------------------------------------
# _display_structure: replica "displayStructure(internal)".
# Cruce de close contra el nivel activo (crossover = BOS/CHoCH alcista,
# crossunder = BOS/CHoCH bajista). Incluye intConflInp (Internal Confluence
# Filter, RONDA 2 / PARTE 2): solo aplica cuando $internal es verdadero.
# -----------------------------------------------------------------------------
sub _display_structure {
    my ( $self, $i, $internal ) = @_;
    my $c = $self->{_c};
    my $cur   = $c->[$i];
    my $prev  = $i > 0 ? $c->[ $i - 1 ] : undef;
    return unless $prev;   # ta.crossover/crossunder necesitan la vela anterior

    my $bias_key = $internal ? '_internal_bias' : '_swing_bias';

    # bullishBar / bearishBar (Pine): solo se calculan si intConflInp esta
    # activo; si no, ambas son 'true' (sin filtro extra).
    my ( $bullish_bar, $bearish_bar ) = ( 1, 1 );
    if ( $internal && $self->{int_confluence} ) {
        my $hi_minus_maxco = $cur->{high} - _max2( $cur->{close}, $cur->{open} );
        my $minco_minus_lo = _min2( $cur->{close}, $cur->{open} ) - $cur->{low};
        $bullish_bar = $hi_minus_maxco > $minco_minus_lo;
        $bearish_bar = $hi_minus_maxco < $minco_minus_lo;
    }

    # ---- rama alcista: pivot HIGH activo ----
    my $ph = $internal ? $self->{_internal_high} : $self->{_swing_high};
    if ( defined $ph->{currentLevel} && !$ph->{crossed} ) {
        my $crossover = ( $prev->{close} <= $ph->{currentLevel} ) && ( $cur->{close} > $ph->{currentLevel} );

        my $extra_bull = 1;
        if ($internal) {
            $extra_bull = $self->{int_confluence}
                ? ( $self->{_internal_high}{currentLevel} != $self->{_swing_high}{currentLevel} && $bullish_bar )
                : 1;
        }

        if ( $crossover && $extra_bull ) {
            my $tag = ( defined $self->{$bias_key} && $self->{$bias_key} == BEARISH ) ? 'CHoCH' : 'BOS';
            $ph->{crossed} = 1;
            $self->{$bias_key} = BULLISH;

            push @{ $self->{_events} }, {
                type      => $tag,
                scope     => $internal ? 'internal' : 'swing',
                dir       => 'up',
                index     => $i,
                origin    => $ph->{barIndex},
                price     => $ph->{currentLevel},
                ts        => $cur->{ts},
                confirmed => 1,
            };

            $self->_store_order_block( $ph, $internal, 'bull' );
        }
    }

    # ---- rama bajista: pivot LOW activo ----
    my $pl = $internal ? $self->{_internal_low} : $self->{_swing_low};
    if ( defined $pl->{currentLevel} && !$pl->{crossed} ) {
        my $crossunder = ( $prev->{close} >= $pl->{currentLevel} ) && ( $cur->{close} < $pl->{currentLevel} );

        my $extra_bear = 1;
        if ($internal) {
            $extra_bear = $self->{int_confluence}
                ? ( $self->{_internal_low}{currentLevel} != $self->{_swing_low}{currentLevel} && $bearish_bar )
                : 1;
        }

        if ( $crossunder && $extra_bear ) {
            my $tag = ( defined $self->{$bias_key} && $self->{$bias_key} == BULLISH ) ? 'CHoCH' : 'BOS';
            $pl->{crossed} = 1;
            $self->{$bias_key} = BEARISH;

            push @{ $self->{_events} }, {
                type      => $tag,
                scope     => $internal ? 'internal' : 'swing',
                dir       => 'down',
                index     => $i,
                origin    => $pl->{barIndex},
                price     => $pl->{currentLevel},
                ts        => $cur->{ts},
                confirmed => 1,
            };

            $self->_store_order_block( $pl, $internal, 'bear' );
        }
    }
}

sub _max2 { return $_[0] > $_[1] ? $_[0] : $_[1]; }
sub _min2 { return $_[0] < $_[1] ? $_[0] : $_[1]; }

# -----------------------------------------------------------------------------
# FAIR VALUE GAPS -- replica de deleteFairValueGaps() / drawFairValueGaps()
# para fvgTFInp = '' (timeframe del chart, caso por defecto: sin MTF/repaint).
# -----------------------------------------------------------------------------
sub _detect_fvg {
    my ( $self, $i ) = @_;
    return if $i < 2;
    my $c = $self->{_c};

    my $last_close = $c->[$i-1]{close};
    my $last_open  = $c->[$i-1]{open};
    my $cur_high   = $c->[$i]{high};
    my $cur_low    = $c->[$i]{low};
    my $last2_high = $c->[$i-2]{high};
    my $last2_low  = $c->[$i-2]{low};

    return unless $last_open;
    my $delta_pct = ( $last_close - $last_open ) / ( $last_open * 100 );

    $self->{_fvg_delta_cum} += abs($delta_pct);
    my $thresh = $self->{fvg_auto_thresh}
        ? ( $self->{_fvg_delta_cum} / ( $i > 0 ? $i : 1 ) * 2 )
        : 0;

    my $bull_fvg = ( $cur_low > $last2_high ) && ( $last_close > $last2_high ) && ( $delta_pct > $thresh );
    my $bear_fvg = ( $cur_high < $last2_low ) && ( $last_close < $last2_low ) && ( -$delta_pct > $thresh );

    if ($bull_fvg) {
        my $mid = ( $cur_low + $last2_high ) / 2;
        my $fvg = {
            dir => 'bull', idx_start => $i - 2, created => $i,
            top => $cur_low, bottom => $last2_high, mid => $mid,
            state => 'active', mitig_at => undef,
        };
        push @{ $self->{_fvgs} },        $fvg;
        push @{ $self->{_active_fvgs} }, $fvg;
    }
    if ($bear_fvg) {
        my $mid = ( $cur_high + $last2_low ) / 2;
        my $fvg = {
            dir => 'bear', idx_start => $i - 2, created => $i,
            top => $last2_low, bottom => $cur_high, mid => $mid,
            state => 'active', mitig_at => undef,
        };
        push @{ $self->{_fvgs} },        $fvg;
        push @{ $self->{_active_fvgs} }, $fvg;
    }
}

# -----------------------------------------------------------------------------
# _update_fvgs: replica deleteFairValueGaps().
#   bull mitigado si low < fvg.bottom ; bear mitigado si high > fvg.top.
# -----------------------------------------------------------------------------
sub _update_fvgs {
    my ( $self, $i ) = @_;
    return unless @{ $self->{_active_fvgs} };
    my $cur = $self->{_c}[$i];
    my @keep;
    for my $f ( @{ $self->{_active_fvgs} } ) {
        if ( $i <= $f->{created} ) { push @keep, $f; next; }
        if ( $f->{dir} eq 'bull' && $cur->{low} < $f->{bottom} ) {
            $f->{state} = 'mitigated'; $f->{mitig_at} = $i; next;
        }
        if ( $f->{dir} eq 'bear' && $cur->{high} > $f->{top} ) {
            $f->{state} = 'mitigated'; $f->{mitig_at} = $i; next;
        }
        push @keep, $f;
    }
    $self->{_active_fvgs} = \@keep;
}

# Accesores Parte 2.
sub get_fvgs      { return $_[0]->{_fvgs}; }
sub get_eq_events { return $_[0]->{_eq_events}; }

# -----------------------------------------------------------------------------
# PARTE 3: ORDER BLOCKS -- replica de storeOrderBlock() / deleteOrderBlocks().
#
# storeOrderBlock(pivot p, internal, bias):
#   Al confirmarse un BOS/CHoCH (bias BULLISH = origen del pivot LOW rota
#   hacia arriba en realidad NO -- ver nota abajo), el Pine busca, entre el
#   indice del pivote (p.barIndex) y la vela actual, el extremo "limpio"
#   (parsedHigh/parsedLow, ya ajustado por highVolatilityBar) que define la
#   vela de origen del Order Block:
#     - bias BEARISH -> arr = parsedHighs.slice(p.barIndex, bar_index); toma el
#       INDICE DEL MAXIMO de esa ventana (la ultima vela alcista antes de la
#       caida).
#     - bias BULLISH -> arr = parsedLows.slice(p.barIndex, bar_index); toma el
#       indice del MINIMO de esa ventana (la ultima vela bajista antes de la
#       subida).
#   NOTA IMPORTANTE: en el Pine, storeOrderBlock(p, internal, BULLISH) se
#   llama en la rama alcista (crossover, bias BULLISH) y storeOrderBlock(p,
#   internal, BEARISH) en la bajista -- el bias del OB coincide con la
#   direccion de la ruptura, no con el tipo de pivote. Se replica igual aqui:
#   _store_order_block($ph, $internal, 'bull') en la rama alcista.
#
#   El OB resultante guarda {barHigh, barLow, barIndex(=ts), bias} de la
#   vela encontrada, y se hace unshift (mas reciente primero), con tope de
#   tamanio (100 en el Pine via obs.size()>=100 -> pop()).
# -----------------------------------------------------------------------------
sub _store_order_block {
    my ( $self, $p, $internal, $bias ) = @_;
    return unless defined $p->{barIndex};

    my $from = $p->{barIndex};
    my $to   = $self->processed_last;   # bar_index actual (ya incluye la vela recien procesada)
    return if $from > $to;

    my $ph = $self->{_parsed_highs};
    my $pl = $self->{_parsed_lows};

    my $idx;
    if ( $bias eq 'bear' ) {
        # ultima vela alcista antes de la caida: indice del MAXIMO parsedHigh en [from..to]
        my $max_v; 
        for my $k ( $from .. $to ) {
            next unless defined $ph->[$k];
            if ( !defined $max_v || $ph->[$k] > $max_v ) { $max_v = $ph->[$k]; $idx = $k; }
        }
    }
    else {
        # ultima vela bajista antes de la subida: indice del MINIMO parsedLow en [from..to]
        my $min_v;
        for my $k ( $from .. $to ) {
            next unless defined $pl->[$k];
            if ( !defined $min_v || $pl->[$k] < $min_v ) { $min_v = $pl->[$k]; $idx = $k; }
        }
    }
    return unless defined $idx;

    my $c = $self->{_c}[$idx];
    my $ob = {
        barHigh  => $ph->[$idx],
        barLow   => $pl->[$idx],
        barIndex => $idx,
        ts       => $c->{ts},
        bias     => $bias,   # 'bull' | 'bear'
        origin_pivot_index => $p->{barIndex},
    };

    my $list_key = $internal ? '_internal_obs' : '_swing_obs';
    my $max_key  = $internal ? 'internal_ob_max' : 'swing_ob_max';
    my $obs = $self->{$list_key};

    pop @$obs if scalar(@$obs) >= $self->{$max_key};
    unshift @$obs, $ob;
}

# -----------------------------------------------------------------------------
# _delete_order_blocks: replica deleteOrderBlocks(internal).
#   obMitigInp = 'close' -> bearMitSrc=close, bullMitSrc=close
#   obMitigInp = 'highlow' (default HIGHLOW) -> bearMitSrc=high, bullMitSrc=low
#   Un OB 'bear' se mitiga (elimina) si bearMitSrc > ob.barHigh.
#   Un OB 'bull' se mitiga (elimina) si bullMitSrc < ob.barLow.
# Se ejecuta ANTES de displayStructure() en cada vela, igual que en el Pine
# (deleteOrderBlocks corre en el bloque MAIN EXECUTION antes de que se agregue
# un OB nuevo en la misma vela).
# -----------------------------------------------------------------------------
sub _delete_order_blocks {
    my ( $self, $i, $internal ) = @_;
    my $list_key = $internal ? '_internal_obs' : '_swing_obs';
    my $obs = $self->{$list_key};
    return unless @$obs;

    my $c = $self->{_c}[$i];
    my ( $bear_mit_src, $bull_mit_src ) = $self->{ob_mitig_src} eq 'close'
        ? ( $c->{close}, $c->{close} )
        : ( $c->{high},  $c->{low} );

    my @keep;
    for my $ob (@$obs) {
        my $crossed = 0;
        if ( $ob->{bias} eq 'bear' && $bear_mit_src > $ob->{barHigh} ) {
            $crossed = 1;
        }
        elsif ( $ob->{bias} eq 'bull' && $bull_mit_src < $ob->{barLow} ) {
            $crossed = 1;
        }
        if ($crossed) {
            # RONDA 2 / PARTE 7: evento de mitigacion (currentAlerts.*OBMit)
            push @{ $self->{_ob_mit_events} }, {
                scope => $internal ? 'internal' : 'swing',
                bias  => $ob->{bias},   # 'bull' | 'bear'
                index => $i,
                ts    => $c->{ts},
                ob    => $ob,
            };
        }
        push @keep, $ob unless $crossed;
    }
    $self->{$list_key} = \@keep;
}

# -----------------------------------------------------------------------------
# _range_measure: fallback de "ta.cum(ta.tr) / math.max(bar_index, 1)" usado
# cuando ob_filter = 'range' (Cumulative Mean Range) en vez de ATR.
# -----------------------------------------------------------------------------
sub _range_measure {
    my ( $self, $i ) = @_;
    my $c = $self->{_c};
    if ( $i >= 1 ) {
        $self->{_tr_cum} += _true_range( $c->[$i], $c->[$i-1] );
    }
    else {
        $self->{_tr_cum} += ( $c->[$i]{high} - $c->[$i]{low} );
    }
    my $n = $i > 0 ? $i : 1;
    return $self->{_tr_cum} / $n;
}

# Accesores Parte 3.
sub get_swing_order_blocks    { return $_[0]->{_swing_obs}; }
sub get_internal_order_blocks { return $_[0]->{_internal_obs}; }

# RONDA 2 / PARTE 3: Color Candles by Trend (colorBarsInp).
# El Pine usa "internalTrend.bias" (el bias INTERNO, no el swing) para
# colorear cada vela: candleCol = internalTrend.bias == BULLISH ? swBullCol : swBearCol.
# Aqui se expone el bias interno vigente en la vela $i (tal como estaba
# DESPUES de procesar esa vela), para que el overlay decida el color.
sub get_internal_bias_at {
    my ( $self, $i ) = @_;
    return $self->{_internal_bias_hist}[$i];
}

# RONDA 2 / PARTE 5: Strong/Weak High & Low.
sub get_trailing_extremes {
    my ($self) = @_;
    return undef unless defined $self->{_trailing_top} && defined $self->{_trailing_bottom};

    my $bias = $self->{_swing_bias};   # BULLISH(1) | BEARISH(-1) | undef

    return {
        top              => $self->{_trailing_top},
        bottom           => $self->{_trailing_bottom},
        top_origin_index => $self->{_trailing_bar_index},
        bot_origin_index => $self->{_trailing_bar_index_bot},
        top_last_index   => $self->{_trailing_last_top_idx},
        bot_last_index   => $self->{_trailing_last_bot_idx},
        top_label        => ( defined $bias && $bias == BEARISH ) ? 'Strong High' : 'Weak High',
        bot_label        => ( defined $bias && $bias == BULLISH ) ? 'Strong Low'  : 'Weak Low',
    };
}

# -----------------------------------------------------------------------------
# RONDA 2 / PARTE 7: Alertas -- replica las 14 alertcondition() del Pine.
# get_ob_mit_events(): historial crudo de mitigaciones de OB (analogo a
# get_events/get_eq_events/get_fvgs para las demas categorias).
#
# get_alerts_at($i): consolida, para la vela $i, cuales de las 14
# condiciones del Pine se cumplieron EN ESA VELA (equivalente a leer
# currentAlerts.* en esa barra). Devuelve un hashref con claves identicas
# a los nombres usados en alertcondition() del Pine, valor 1/0:
#   intBullBOS, intBearBOS, intBullCHoCH, intBearCHoCH,
#   swBullBOS,  swBearBOS,  swBullCHoCH,  swBearCHoCH,
#   intBullOBMit, intBearOBMit, swBullOBMit, swBearOBMit,
#   eqHighs, eqLows, bullFVG, bearFVG
# Uso tipico (market.pl): recorrer $i desde la ultima vela notificada hasta
# processed_last() y consultar get_alerts_at($i) para disparar avisos.
# -----------------------------------------------------------------------------
sub get_ob_mit_events { return $_[0]->{_ob_mit_events}; }

sub get_alerts_at {
    my ( $self, $i ) = @_;
    my %a = map { $_ => 0 } qw(
        intBullBOS intBearBOS intBullCHoCH intBearCHoCH
        swBullBOS  swBearBOS  swBullCHoCH  swBearCHoCH
        intBullOBMit intBearOBMit swBullOBMit swBearOBMit
        eqHighs eqLows bullFVG bearFVG
    );

    for my $e ( @{ $self->{_events} } ) {
        next unless $e->{index} == $i;
        my $scope = $e->{scope} eq 'internal' ? 'int' : 'sw';
        my $dir   = $e->{dir}  eq 'up' ? 'Bull' : 'Bear';
        my $kind  = $e->{type} eq 'CHoCH' ? 'CHoCH' : 'BOS';
        $a{ "$scope$dir$kind" } = 1;
    }

    for my $e ( @{ $self->{_ob_mit_events} } ) {
        next unless $e->{index} == $i;
        my $scope = $e->{scope} eq 'internal' ? 'int' : 'sw';
        my $dir   = $e->{bias}  eq 'bull' ? 'Bull' : 'Bear';
        $a{ "$scope${dir}OBMit" } = 1;
    }

    for my $e ( @{ $self->{_eq_events} } ) {
        next unless $e->{idx_to} == $i;
        $a{ $e->{kind} eq 'EQH' ? 'eqHighs' : 'eqLows' } = 1;
    }

    for my $f ( @{ $self->{_fvgs} } ) {
        next unless $f->{created} == $i;
        $a{ $f->{dir} eq 'bull' ? 'bullFVG' : 'bearFVG' } = 1;
    }

    return \%a;
}

# -----------------------------------------------------------------------------
# RONDA 2 / PARTE 8: MTF Levels -- Previous Day/Week/Month High & Low.
#
# Replica drawLevels()/higherTimeframe() sin depender de otro feed de datos:
# agrupa self->{_c} por periodo calendario (dia/semana/mes, mismo offset
# horario -300min que Market::MarketData) y calcula el H/L del periodo
# ANTERIOR completo respecto a la ultima vela procesada. Solo se calcula si
# el timeframe del chart es <= al periodo pedido (higherTimeframe check):
# aqui se aproxima comparando la duracion tipica entre velas (delta de ts)
# contra la duracion del periodo.
# -----------------------------------------------------------------------------
sub _period_key {
    my ( $self, $ts, $unit ) = @_;
    my $tm = Time::Moment->from_epoch($ts)->with_offset_same_instant(GMT_OFFSET_MIN);
    if ( $unit eq 'D' ) {
        return sprintf( '%04d-%02d-%02d', $tm->year, $tm->month, $tm->day_of_month );
    }
    elsif ( $unit eq 'W' ) {
        my $dow = $tm->day_of_week;   # 1=Mon..7=Sun
        my $monday = $tm->minus_days( $dow - 1 );
        return sprintf( '%04d-%02d-%02d', $monday->year, $monday->month, $monday->day_of_month );
    }
    elsif ( $unit eq 'M' ) {
        return sprintf( '%04d-%02d', $tm->year, $tm->month );
    }
    return undef;
}

# _chart_tf_seconds: aproxima timeframe.in_seconds() usando el delta modal
# entre timestamps de las ultimas velas procesadas.
sub _chart_tf_seconds {
    my ($self) = @_;
    my $c = $self->{_c};
    my $n = scalar @$c;
    return undef if $n < 2;
    my $from = $n > 20 ? $n - 20 : 1;
    my %count;
    for my $k ( $from .. $n - 1 ) {
        my $d = $c->[$k]{ts} - $c->[ $k - 1 ]{ts};
        $count{$d}++ if $d > 0;
    }
    return undef unless %count;
    my ($mode) = sort { $count{$b} <=> $count{$a} } keys %count;
    return $mode;
}

use constant {
    _SEC_DAY   => 86400,
    _SEC_WEEK  => 604800,
    _SEC_MONTH => 2592000,   # aproximado (30d), solo para el chequeo higherTimeframe
};

# get_mtf_levels(): devuelve { D => {...}, W => {...}, M => {...} } con el
# high/low/left_index/right_index del periodo ANTERIOR completo para cada
# unidad habilitada (mtf_show_daily/weekly/monthly), o undef por unidad si
# el chart timeframe es mayor al periodo pedido (higherTimeframe) o no hay
# suficiente historial. left_index/right_index son indices de vela reales,
# para que el overlay pueda ubicar el segmento igual que topTime/botTime.
sub get_mtf_levels {
    my ($self) = @_;
    my $c = $self->{_c};
    my $n = scalar @$c;
    return {} if $n < 2;

    my $tf_sec = $self->_chart_tf_seconds;
    my %out;

    my %want = (
        D => [ $self->{mtf_show_daily},   _SEC_DAY,   'D' ],
        W => [ $self->{mtf_show_weekly},  _SEC_WEEK,  'W' ],
        M => [ $self->{mtf_show_monthly}, _SEC_MONTH, 'M' ],
    );

    for my $unit ( sort keys %want ) {
        my ( $enabled, $period_sec, $u ) = @{ $want{$unit} };
        next unless $enabled;
        next if defined $tf_sec && $tf_sec > $period_sec;   # higherTimeframe('D'/'W'/'M') -> se omite

        my $last_key = $self->_period_key( $c->[ $n - 1 ]{ts}, $u );
        next unless defined $last_key;

        # ultima vela DEL PERIODO ANTERIOR (primer key distinto yendo hacia atras)
        my $prev_key;
        my $end_idx;
        for ( my $k = $n - 1 ; $k >= 0 ; $k-- ) {
            my $key = $self->_period_key( $c->[$k]{ts}, $u );
            if ( $key ne $last_key ) { $prev_key = $key; $end_idx = $k; last; }
        }
        next unless defined $prev_key;

        my ( $hi, $lo, $hi_idx, $lo_idx, $start_idx );
        for ( my $k = $end_idx ; $k >= 0 ; $k-- ) {
            my $key = $self->_period_key( $c->[$k]{ts}, $u );
            last if $key ne $prev_key;
            $start_idx = $k;
            if ( !defined $hi || $c->[$k]{high} > $hi ) { $hi = $c->[$k]{high}; $hi_idx = $k; }
            if ( !defined $lo || $c->[$k]{low}  < $lo ) { $lo = $c->[$k]{low};  $lo_idx = $k; }
        }
        next unless defined $hi;

        $out{$unit} = {
            top             => $hi,
            bottom          => $lo,
            top_index       => $hi_idx,
            bottom_index    => $lo_idx,
            period_start_index => $start_idx,
            period_end_index   => $end_idx,
        };
    }

    return \%out;
}

1;