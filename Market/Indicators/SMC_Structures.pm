package Market::Indicators::SMC_Structures;

# =============================================================================
# Market::Indicators::SMC_Structures
#
# Calculo de BOS (Break of Structure) e iBOS (Internal Break of Structure)
# a partir de los pivotes ya confirmados por Indicators/ZigZagMTF.pm
# (direccion interna, remuestreo OHLC + fractalidad por periodo). SOLO
# calcula: el dibujo es de Overlays/SMC_Structures.pm.
#
# FASE 2: BOS/iBOS y la clasificacion HH/HL/LH/LL comparten ahora la MISMA
# fuente de swings (Indicators::ZigZagMTF). Antes BOS/iBOS leian los swings
# crudos de Liquidity (fractal_n + ATR + desplazamiento) mientras HH/HL/LH/LL
# ya leia del ZigZagMTF -- dos criterios distintos sobre el mismo grafico
# hacian que las lineas BOS/iBOS no coincidieran con los pivotes del zigzag
# visible, y que un nivel se rompiera "antes" o "despues" de lo esperado
# segun el criterio con el que se comparara visualmente. Unificar la fuente
# resuelve esa desincronizacion.
#
# FASE 3: FILTRO JERARQUICO DE RELEVANCIA (anti-saturacion).
# Unificar la fuente (Fase 2) resolvio la desincronizacion visual, pero dejo
# expuesto un problema distinto: CADA pivote que entrega ZigZagMTF, sin
# importar cuan pequenio sea, se promueve automaticamente a nivel BOS o iBOS,
# y CADA cruce de ese nivel, sin importar cuan minimo sea el exceso de precio,
# se emite como evento confirmado. No existia ningun criterio de "tamanio
# minimo de movimiento" ni de "margen minimo de ruptura": el indicador era
# tan sensible como el detector fractal subyacente, lo cual en timeframes
# ruidosos genera decenas de BOS/iBOS por sesion, la mayoria irrelevantes
# para una lectura estrategica. Se agregan dos filtros configurables:
#
#   1) min_swing_pct / min_swing_points: un pivote nuevo solo se promueve a
#      nivel BOS/iBOS (o a etiqueta HH/HL/LH/LL) si su distancia respecto al
#      ultimo pivote SIGNIFICATIVO del lado opuesto supera este umbral. Los
#      pivotes que no lo superan se descartan como ruido: no generan linea,
#      no generan etiqueta, y no se usan como referencia futura. Esto es un
#      "re-filtrado" jerarquico sobre el zigzag ya confirmado, analogo a
#      exigir una retraccion minima antes de considerar un swing valido.
#
#   2) break_margin_pct / break_margin_points: una ruptura solo se confirma
#      si el precio supera el nivel por al menos este margen, no con
#      cualquier exceso marginal (p.ej. 1 tick). Evita BOS/iBOS disparados
#      por "wicks" o cierres que apenas retocan el nivel.
#
# Ambos filtros son opcionales (por defecto conservadores pero no nulos) y
# configurables por instancia, para poder ajustar la sensibilidad por
# simbolo/timeframe sin tocar la logica.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        liquidity   => $args{liquidity},          # YA NO se usa para BOS/iBOS (ver _ingest_new_swings); se conserva solo por compatibilidad de firma si algo externo la pasa.
        zzmtf       => $args{zzmtf},              # FUENTE UNICA de swings para BOS/iBOS y para HH/HL/LH/LL: Indicators::ZigZagMTF
        zzvp => $args{zzvp},
        break_mode  => $args{break_mode} // 'close',   # 'close' | 'wick'

        # --- FASE 3: filtros de relevancia / anti-saturacion ---
        # Umbral minimo de amplitud para que un pivote sea "significativo".
        # Si min_swing_points esta definido (>0) tiene prioridad sobre el pct.
        min_swing_pct    => $args{min_swing_pct}    // 0.0025,  # 0.25% por defecto
        min_swing_points => $args{min_swing_points} // 0,       # 0 = usar pct

        # Margen minimo para confirmar una ruptura (evita rupturas "por 1 tick").
        # Si break_margin_points esta definido (>0) tiene prioridad sobre el pct.
        break_margin_pct    => $args{break_margin_pct}    // 0.0005, # 0.05% por defecto
        break_margin_points => $args{break_margin_points} // 0,      # 0 = usar pct

        _c      => [],    # velas procesadas
        _events => [],    # eventos BOS / iBOS confirmados
        _fvgs        => [],
        _active_fvgs => [],

        # Niveles activos (precio) aun no rotos.
        _bos_high  => undef,
        _bos_low   => undef,
        _ibos_high => undef,
        _ibos_low  => undef,
        max_age => $args{max_age} // 50,

        # Indice del swing que sostiene cada nivel activo.
        _bos_high_index  => undef,
        _bos_low_index   => undef,
        _ibos_high_index => undef,
        _ibos_low_index  => undef,

        # Ultimo swing high/low PRINCIPAL confirmado.
        _principal_high_index => undef,
        _principal_low_index  => undef,

        # Anti-duplicado: ids de swings ya consumidos.
        _seen_swing_id => {},

        # --- NUEVAS VARIABLES PARA ESTRUCTURA ZZMTF (Fase 2) ---
        _swing_labels  => {},
        _seen_pivot_id => {},
        _last_high     => undef,
        _last_low      => undef,
        _bias          => undef,

        # --- FASE 3: referencias de amplitud (para filtro jerarquico) ---
        # Precio del ultimo pivote SIGNIFICATIVO de cada lado, usado como
        # referencia para medir la amplitud del proximo pivote del lado
        # opuesto. Separado de _last_high/_last_low (que son para el label
        # HH/HL/LH/LL) para no acoplar ambos usos.
        _sig_ref_high => undef,
        _sig_ref_low  => undef,
        _ext_bh_idx => -1,      # ultimo pivot H externo ya roto
        _ext_bl_idx => -1,      # ultimo pivot L externo ya roto
        _int_high => undef, _int_low => undef,
        _int_high_index => undef, _int_low_index => undef,
        _int_bias => undef,
        _seen_swing_id => {},
        _sig_ref_high => undef, _sig_ref_low => undef,

        # Estructura EXTERNA (ZigZag Volume Profile)
        _ext_high => undef, _ext_low => undef,
        _ext_high_index => undef, _ext_low_index => undef,
        _ext_bias => undef,
        _seen_ext_id => {},
        _ext_sig_ref_high => undef, _ext_sig_ref_low => undef, 
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_events} = [];
    $self->{_bos_high}  = undef;
    $self->{_bos_low}   = undef;
    $self->{_ibos_high} = undef;
    $self->{_ibos_low}  = undef;
    $self->{_bos_high_index}  = undef;
    $self->{_bos_low_index}   = undef;
    $self->{_ibos_high_index} = undef;
    $self->{_ibos_low_index}  = undef;
    $self->{_principal_high_index} = undef;
    $self->{_principal_low_index}  = undef;
    $self->{_seen_swing_id} = {};

    # Reset Estructura ZZMTF
    $self->{_swing_labels}  = {};
    $self->{_seen_pivot_id} = {};
    $self->{_last_high}     = undef;
    $self->{_last_low}      = undef;
    $self->{_bias}          = undef;
    $self->{_int_bias}          = undef;

    # Reset referencias de amplitud (Fase 3)
    $self->{_sig_ref_high} = undef;
    $self->{_sig_ref_low}  = undef;
}

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

# Accesores de solo lectura para el Overlay.
sub get_events       { return $_[0]->{_events}; }
sub processed_last   { return $#{ $_[0]->{_c} }; }
sub get_swing_labels { return $_[0]->{_swing_labels}; } # NUEVO ACCESOR PARA OVERLAY
sub get_fvgs      { return $_[0]->{_fvgs}; }
sub get_candle_at { return $_[0]->{_c}[ $_[1] ]; }

# -----------------------------------------------------------------------------
# _process: integra la vela en el indice i = $#_c.
# -----------------------------------------------------------------------------
sub _process {
     my ( $self, $c ) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };
    
    $self->_update_fvgs($i);       # Actualiza o mitiga FVGs previos con la vela actual
    $self->_detect_fvg($i);

    $self->_ingest_internal($i);   # zzmtf -> _int_high/_int_low
    $self->_ingest_external($i);   # zzvp  -> _ext_high/_ext_low

    $self->_check_break_scope( $i, $c, 'internal' );
    $self->_check_break_scope( $i, $c, 'external' );

    $self->_classify_zzmtf_pivots();
}

# -----------------------------------------------------------------------------
# _is_significant: FASE 3 -- determina si la distancia entre $price y el
# ultimo pivote de referencia del lado opuesto ($ref_price) alcanza el
# umbral minimo configurado. Si no hay referencia previa (primer pivote de
# la serie), se acepta siempre: no hay nada contra que comparar todavia.
# -----------------------------------------------------------------------------
sub _is_significant {
    my ( $self, $price, $ref_price ) = @_;
    return 1 unless defined $ref_price;

    my $delta = abs( $price - $ref_price );

    if ( $self->{min_swing_points} && $self->{min_swing_points} > 0 ) {
        return $delta >= $self->{min_swing_points};
    }

    my $base = abs($ref_price) > 0 ? abs($ref_price) : abs($price);
    return 0 unless $base > 0;
    return ( $delta / $base ) >= ( $self->{min_swing_pct} // 0 );
}

# -----------------------------------------------------------------------------
# _ingest_new_swings: FASE 2 -- BOS/iBOS ahora se alimentan de los swings del
# ZigZagMTF (Indicators::ZigZagMTF::get_swings), NO de Indicators::Liquidity.
# Esto es necesario porque el zigzag dibujado en pantalla (overlay) y la
# clasificacion HH/HL/LH/LL ya vienen de esa fuente; si BOS/iBOS siguieran
# leyendo los swings crudos de Liquidity (fractal_n + ATR + desplazamiento),
# los niveles rotos no coincidirian con los pivotes visibles del zigzag,
# produciendo lineas BOS/iBOS ancladas a un swing que el usuario ni siquiera
# ve dibujado.
#
# DOS DIFERENCIAS CRITICAS frente a los swings de Liquidity que este metodo
# debia tener en cuenta:
#
#   1) LLEGAN CON RETRASO ESTRUCTURAL. Un pivote del ZigZagMTF solo se
#      confirma cuando cierra el bloque agregado (period+1)*resolution_min
#      despues del extremo real. Por eso el filtro "next if $sw->{index} >=
#      $i" de la version anterior no alcanza aqui: el indice base del swing
#      YA es pasado respecto a la vela actual en el momento en que aparece,
#      pero puede referirse a una zona de velas que este metodo ya proceso
#      en llamadas anteriores sin haber "visto" ese swing todavia. Esto es
#      correcto y esperado -- el swing simplemente entra tarde, en cuanto
#      el ZigZagMTF lo confirma.
#
#   2) PUEDEN LLEGAR FUERA DE ORDEN POR INDICE BASE. Un mismo bloque
#      agregado puede producir un pivote High Y un pivote Low a la vez
#      (vela envolvente, ver ZigZagMTF::_try_confirm_pivot), y el orden en
#      que _consolidate() los agrega a la secuencia depende de cual extremo
#      ocurrio primero DENTRO del bloque (high_index vs low_index), no del
#      orden de llegada a este metodo. Ademas, entre llamadas sucesivas a
#      _process(), get_swings() puede devolver pivotes nuevos cuyo indice
#      base cae ANTES del indice base de un pivote ya consumido en una
#      llamada previa (p.ej. si el bloque que lo contiene tardo mas en
#      cerrar). Sin ordenar explicitamente por indice base antes de
#      procesarlos, un pivote podria sobreescribir el nivel BOS/iBOS de
#      otro que en la linea de tiempo real es posterior, invirtiendo
#      accidentalmente cual nivel es "principal" (bos) y cual es
#      "subestructura" (ibos).
#
#   Por eso aqui: (a) se toman SOLO pivotes nuevos (por id, igual que antes)
#   y (b) se ordenan por indice base ANTES de alimentar _bos_high/_bos_low/
#   _ibos_high/_ibos_low, garantizando que la promocion principal/interno
#   siga la cronologia real del grafico y no el orden de confirmacion.
#
#   FASE 3: (c) ademas, cada pivote debe superar _is_significant() respecto
#   al ultimo pivote de referencia del lado opuesto para poder promoverse a
#   nivel BOS/iBOS. Un pivote que no alcanza el umbral se marca como visto
#   (para no reevaluarlo) pero NO genera nivel ni se usa como nueva
#   referencia: es ruido, y el ruido no debe alimentar mas ruido.
# -----------------------------------------------------------------------------
sub _ingest_internal {
    my ( $self, $i ) = @_;
    my $zz = $self->{zzmtf};
    return unless $zz;

    my $swings = $zz->get_swings;
    return unless $swings && @$swings;

    my @new = grep {
        !$self->{_seen_swing_id}{ $_->{id} } && $_->{index} < $i
    } @$swings;
    return unless @new;

    @new = sort { $a->{index} <=> $b->{index} } @new;

    for my $sw (@new) {
        $self->{_seen_swing_id}{ $sw->{id} } = 1;

        if ( $sw->{kind} eq 'H' ) {
            next unless $self->_is_significant( $sw->{price}, $self->{_sig_ref_low} );
            $self->{_sig_ref_high}   = $sw->{price};
            $self->{_int_high}       = $sw->{price};
            $self->{_int_high_index} = $sw->{index};
        }
        else {
            next unless $self->_is_significant( $sw->{price}, $self->{_sig_ref_high} );
            $self->{_sig_ref_low}   = $sw->{price};
            $self->{_int_low}       = $sw->{price};
            $self->{_int_low_index} = $sw->{index};
        }
    }
}
sub _ingest_external {
    my ( $self, $i ) = @_;
    my $zz = $self->{zzvp};
    return unless $zz;

    my $pivots = $zz->get_pivots;
    return unless $pivots && @$pivots;

    my @new = grep {
        !$self->{_seen_ext_id}{ $_->{id} } && $_->{index} < $i
    } @$pivots;
    return unless @new;

    @new = sort { $a->{index} <=> $b->{index} } @new;

    for my $sw (@new) {
        $self->{_seen_ext_id}{ $sw->{id} } = 1;

        if ( $sw->{kind} eq 'H' ) {
            next unless $self->_is_significant( $sw->{price}, $self->{_ext_sig_ref_low} );
            $self->{_ext_sig_ref_high} = $sw->{price};
            $self->{_ext_high}         = $sw->{price};
            $self->{_ext_high_index}   = $sw->{index};
        }
        else {
            next unless $self->_is_significant( $sw->{price}, $self->{_ext_sig_ref_high} );
            $self->{_ext_sig_ref_low} = $sw->{price};
            $self->{_ext_low}         = $sw->{price};
            $self->{_ext_low_index}   = $sw->{index};
        }
    }
}

# -----------------------------------------------------------------------------
# _break_threshold: FASE 3 -- calcula el nivel efectivo que el precio debe
# superar para confirmar una ruptura, sumando/restando el margen minimo
# configurado (break_margin_points tiene prioridad sobre break_margin_pct).
# $dir es 'up' o 'down'.
# -----------------------------------------------------------------------------
sub _break_threshold {
    my ( $self, $level, $dir ) = @_;
    my $margin;
    if ( $self->{break_margin_points} && $self->{break_margin_points} > 0 ) {
        $margin = $self->{break_margin_points};
    }
    else {
        $margin = abs($level) * ( $self->{break_margin_pct} // 0 );
    }
    return $dir eq 'up' ? $level + $margin : $level - $margin;
}

# -----------------------------------------------------------------------------
# _check_break (Fase 3: ahora exige superar el nivel + margen minimo, no
# cualquier exceso marginal, para confirmar la ruptura).
# -----------------------------------------------------------------------------
sub _check_break_scope {
    my ( $self, $i, $c, $scope ) = @_;

    my ( $high_key, $low_key, $high_idx_key, $low_idx_key, $bias_key ) =
        $scope eq 'internal'
        ? ( '_int_high', '_int_low', '_int_high_index', '_int_low_index', '_int_bias' )
        : ( '_ext_high', '_ext_low', '_ext_high_index', '_ext_low_index', '_ext_bias' );

    if ( defined $self->{$high_key} ) {
        my $ref_price = ( $self->{break_mode} eq 'wick' ) ? $c->{high} : $c->{close};
        my $threshold = $self->_break_threshold( $self->{$high_key}, 'up' );
        if ( $ref_price > $threshold ) {
            $self->_emit( $scope, 'up', $i, $self->{$high_key}, $self->{$high_idx_key}, $bias_key );
            $self->{$high_key}     = undef;
            $self->{$high_idx_key} = undef;
            return;
        }
    }

    if ( defined $self->{$low_key} ) {
        my $ref_price = ( $self->{break_mode} eq 'wick' ) ? $c->{low} : $c->{close};
        my $threshold = $self->_break_threshold( $self->{$low_key}, 'down' );
        if ( $ref_price < $threshold ) {
            $self->_emit( $scope, 'down', $i, $self->{$low_key}, $self->{$low_idx_key}, $bias_key );
            $self->{$low_key}     = undef;
            $self->{$low_idx_key} = undef;
            return;
        }
    }
}

sub _reset_ibos_on_bos {
    my ($self) = @_;
    $self->{_ibos_high}       = undef;
    $self->{_ibos_low}        = undef;
    $self->{_ibos_high_index} = undef;
    $self->{_ibos_low_index}  = undef;
}

sub _emit {
    my ( $self, $scope, $dir, $i, $price, $origin, $bias_key ) = @_;

    my $type = ( defined $self->{$bias_key} && $self->{$bias_key} ne $dir )
        ? 'CHoCH' : 'BOS';
    $self->{$bias_key} = $dir;

    push @{ $self->{_events} }, {
        type      => $type,
        scope     => $scope,   # 'internal' (zzmtf) | 'external' (zzvp)
        dir       => $dir,
        index     => $i,
        origin    => $origin,
        ts        => $self->{_c}[$i]{ts},
        price     => $price,
        confirmed => 1,
    };
}

# -----------------------------------------------------------------------------
# _classify_zzmtf_pivots: Genera las etiquetas HH/HL/LH/LL exclusivamente
# a partir de los pivotes confirmados por el ZigZagMTF.
#
# FASE 3: se aplica el mismo filtro _is_significant() que en BOS/iBOS antes
# de etiquetar. Un pivote que no supera el umbral minimo de amplitud NO se
# guarda en _swing_labels (no se dibuja) y no actualiza _last_high/_last_low
# ni las referencias de sesgo: es ruido y se descarta por completo, en lugar
# de generar una etiqueta HH/HL/LH/LL espurea por cada micro-pivote del
# fractal subyacente.
# -----------------------------------------------------------------------------
sub _classify_zzmtf_pivots {
    my ($self) = @_;
    my $zzmtf = $self->{zzmtf};
    return unless $zzmtf;

    my $pivots = $zzmtf->get_pivots();
    return unless $pivots && @$pivots;

    for my $piv (@$pivots) {
        # Evitar re-procesar pivotes usando el ID propio del ZigZag
        next if $self->{_seen_pivot_id}{ $piv->{id} };
        $self->{_seen_pivot_id}{ $piv->{id} } = 1;

        if ( $piv->{kind} eq 'H' ) {
            # FASE 3: descartar micro-pivotes que no se alejan lo suficiente
            # del ultimo minimo relevante.
            my $ref_low = defined $self->{_last_low} ? $self->{_last_low}{price} : undef;
            next unless $self->_is_significant( $piv->{price}, $ref_low );
        }
        else {
            my $ref_high = defined $self->{_last_high} ? $self->{_last_high}{price} : undef;
            next unless $self->_is_significant( $piv->{price}, $ref_high );
        }

        # Traducir el índice del bloque agregado al índice de la vela de 1 minuto
        my $base_index = $zzmtf->_base_index_for_pivot($piv);

        if ( $piv->{kind} eq 'H' ) {
            my $label;
            if ( !defined $self->{_last_high} ) {
                $label = 'HH';
            } elsif ( $piv->{price} > $self->{_last_high}{price} ) {
                $label = 'HH';
                $self->{_bias} = 'bull'; # Actualizamos tendencia
            } else {
                $label = 'LH';
            }

            # Guardar el hash completo para el Overlay
            $self->{_swing_labels}{ $base_index } = {
                label => $label,
                price => $piv->{price},
                kind  => 'H'
            };

            # Si la tendencia macro es bajista ('bear'), un LH es un máximo válido.
            # Si es alcista, evitamos que un LH (ruido) borre el techo estructural.
            if ( !defined $self->{_bias} || $self->{_bias} ne 'bull' || $label eq 'HH' ) {
                $self->{_last_high} = { index => $base_index, price => $piv->{price} };
            }
        }
        else {   # 'L' (Valle)
            my $label;
            if ( !defined $self->{_last_low} ) {
                $label = 'LL';
            } elsif ( $piv->{price} > $self->{_last_low}{price} ) {
                $label = 'HL';
            } else {
                $label = 'LL';
                $self->{_bias} = 'bear'; # Actualizamos tendencia
            }

            $self->{_swing_labels}{ $base_index } = {
                label => $label,
                price => $piv->{price},
                kind  => 'L'
            };

            if ( !defined $self->{_bias} || $self->{_bias} ne 'bear' || $label eq 'LL' ) {
                $self->{_last_low} = { index => $base_index, price => $piv->{price} };
            }
        }
    }
}

sub _detect_fvg {
    my ( $self, $i ) = @_;
    return if $i < 2;
    my $c = $self->{_c};
    my $a = $c->[$i - 2];
    my $z = $c->[$i];
    my $fvg;
    if ( $z->{low} > $a->{high} ) {
        $fvg = { dir=>'bull', idx_start=>$i-2, created=>$i,
                 bottom=>$a->{high}, top=>$z->{low},
                 state=>'active', mitig_at=>undef };
    } elsif ( $z->{high} < $a->{low} ) {
        $fvg = { dir=>'bear', idx_start=>$i-2, created=>$i,
                 bottom=>$z->{high}, top=>$a->{low},
                 state=>'active', mitig_at=>undef };
    }
    if ($fvg) {
        push @{ $self->{_fvgs} },        $fvg;
        push @{ $self->{_active_fvgs} }, $fvg;
    }
}

sub _update_fvgs {
    my ( $self, $i ) = @_;
    my $cur = $self->{_c}[$i];
    my @keep;
    for my $f ( @{ $self->{_active_fvgs} } ) {
        if ( $i <= $f->{created} ) { push @keep, $f; next; }
        
        if ( $f->{dir} eq 'bull' && $cur->{low} <= $f->{top} )
            { $f->{state}='mitigated'; $f->{mitig_at}=$i; next; }
            
        if ( $f->{dir} eq 'bear' && $cur->{high} >= $f->{bottom} )
            { $f->{state}='mitigated'; $f->{mitig_at}=$i; next; }
            
        if ( ($i - $f->{created}) > $self->{max_age} )
            { $f->{state}='expired'; next; }
        push @keep, $f;
    }
    $self->{_active_fvgs} = \@keep
}

sub _detect_external {
    my ( $self, $i ) = @_;
    my $zzvp = $self->{zzvp};
    return unless $zzvp;
    my $pivots = $zzvp->get_pivots;
    return unless $pivots && @$pivots;
    my $cur = $self->{_c}[$i];

    my ($last_h, $last_l);
    for my $pv ( reverse @$pivots ) {
        $last_h //= $pv if $pv->{kind} eq 'H' && $pv->{index} < $i;
        $last_l //= $pv if $pv->{kind} eq 'L' && $pv->{index} < $i;
        last if $last_h && $last_l;
    }

    if ( $last_h && $last_h->{index} != $self->{_ext_bh_idx} ) {
        my $threshold = $self->_break_threshold( $last_h->{price}, 'up' );
        my $ref = $self->{break_mode} eq 'wick' ? $cur->{high} : $cur->{close};
        if ( $ref > $threshold ) {
            my $type = ( defined $self->{_ext_bias} && $self->{_ext_bias} eq 'bear' )
                ? 'CHoCH' : 'BOS';
            $self->_emit_typed( $type, 'external', 'up', $i,
                                $last_h->{price}, $last_h->{index} );
            $self->{_ext_bias}   = 'bull';
            $self->{_ext_bh_idx} = $last_h->{index};
        }
    }

    if ( $last_l && $last_l->{index} != $self->{_ext_bl_idx} ) {
        my $threshold = $self->_break_threshold( $last_l->{price}, 'down' );
        my $ref = $self->{break_mode} eq 'wick' ? $cur->{low} : $cur->{close};
        if ( $ref < $threshold ) {
            my $type = ( defined $self->{_ext_bias} && $self->{_ext_bias} eq 'bull' )
                ? 'CHoCH' : 'BOS';
            $self->_emit_typed( $type, 'external', 'down', $i,
                                $last_l->{price}, $last_l->{index} );
            $self->{_ext_bias}   = 'bear';
            $self->{_ext_bl_idx} = $last_l->{index};
        }
    }
}

# _emit_typed: version que recibe el type ya resuelto (usado por _detect_external)
sub _emit_typed {
    my ( $self, $type, $scope, $dir, $i, $price, $origin ) = @_;
    push @{ $self->{_events} }, {
        type      => $type,
        scope     => $scope,
        dir       => $dir,
        index     => $i,
        origin    => $origin,
        ts        => $self->{_c}[$i]{ts},
        price     => $price,
        label     => $type,
        confirmed => 1,
    };
}

1;