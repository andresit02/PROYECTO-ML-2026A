package Market::Indicators::ZigZagMTF2;

use strict;
use warnings;
use Time::Moment;

# =============================================================================
# Market::Indicators::ZigZagMTF2 (ZZMTF2)
#
# Replica fiel de "ZigZag Multi Time Frame with Fibonacci Retracement" de
# LonesomeTheBlue (Pine v4), sobre las velas base (temporalidad del grafico).
#
# --- Logica del ZigZag (lineas 22-59 del Pine) ---
#   newbar   = cambia change(time(tf)): true cuando el bucket de resolucion
#              "tf" de la vela actual es distinto al de la vela anterior.
#   bi       = bar_index de la newbar numero (prd-1) hacia atras (valuewhen).
#              Equivale a: el indice de la newbar que abrio la ventana de
#              "prd" bloques de resolucion "tf" atras.
#   len      = bar_index - bi + 1  (tama\xF1o de esa ventana en velas BASE).
#   ph       = high actual, SOLO si es el maximo de esa ventana (posicion 0
#              en highestbars). Si no, na.
#   pl       = low actual, SOLO si es el minimo de esa ventana. Si no, na.
#   dir      = 1 si aparecio ph sin pl; -1 si aparecio pl sin ph; si no,
#              mantiene el valor anterior (var).
#   zigzag   = array plano [value0, bindex0, value1, bindex1, ...] (mas
#              reciente primero). Si cambio dir respecto a la barra anterior,
#              se agrega un punto nuevo (add_to_zigzag); si no, se actualiza
#              en vivo el punto 0 solo si el nuevo extremo es "mas extremo"
#              en la direccion vigente (update_zigzag).
#
# --- Logica de Fibonacci (lineas 73-142 del Pine) ---
#   Ratios: 0, 0.236, 0.382, 0.5, 0.618, 0.786 (togglable) + para x=1..5:
#   x, x+0.272, x+0.414, x+0.618 (extensiones, siempre activas).
#   diff = zigzag[4] - zigzag[2]  (precio del pivote en zigzag[2] hasta
#          zigzag[4]; son los DOS pivotes mas antiguos del ultimo tramo de 3
#          puntos, ya que zigzag[0..1] es el extremo AUN en formacion).
#   level(x) = zigzag[2] + diff * ratio(x), dibujado desde zigzag[5]
#          (bar_index del pivote en zigzag[4]) hasta la barra actual.
#   Se detiene (stopit) una vez que un nivel cruza mas alla del extremo
#   vigente (zigzag[0]) en la direccion de dir, incluyendo un nivel extra
#   despues del corte (igual que el Pine: "if stopit and x > shownlevels ->
#   break", es decir, corta un ratio despues de activarse stopit).
#
# Solo se recalculan/reexponen aqui los DATOS; el overlay decide que dibujar
# (zigzag, fibo, o ambos) via flags.
# =============================================================================

use constant GMT_OFFSET_MIN => -300;   # GMT-5, consistente con el resto del sistema

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        resolution => $args{resolution} // 'D',   # ver _bucket_ts_for
        period     => $args{period}     // 2,      # prd

        enable_236 => $args{enable_236} // 1,
        enable_382 => $args{enable_382} // 1,
        enable_500 => $args{enable_500} // 1,
        enable_618 => $args{enable_618} // 1,
        enable_786 => $args{enable_786} // 1,

        _c => [],   # velas base

        # newbar tracking
        _prev_bucket_ts => undef,
        _newbar_bar_indices => [],   # historico de indices donde newbar fue true

        # ph/pl/dir (equivalentes 'var')
        _dir      => 0,
        _prev_dir => 0,

        # zigzag array plano, MAS RECIENTE PRIMERO: [value0,bindex0,value1,bindex1,...]
        _zigzag => [],

        _fibo_ratios => undef,   # se construye lazy la 1ra vez (barstate.isfirst)
    };
    bless $self, $class;
    $self->_build_fibo_ratios;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c} = [];
    $self->{_prev_bucket_ts} = undef;
    $self->{_newbar_bar_indices} = [];
    $self->{_dir}      = 0;
    $self->{_prev_dir} = 0;
    $self->{_zigzag}   = [];
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_process_candle($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_process_candle($idx);
}

# -----------------------------------------------------------------------------
# get_segments: expone el zigzag como lista de segmentos consecutivos
# {from_index,from_price,to_index,to_price,dir}, mas facil de dibujar que el
# array plano crudo. Incluye el punto 0 (extremo en formacion, "en vivo").
# -----------------------------------------------------------------------------
sub get_segments {
    my ($self) = @_;
    my $zz = $self->{_zigzag};
    my $n  = @$zz / 2;   # cantidad de puntos (value,bindex por punto)
    return [] if $n < 2;

    my @segments;
    for my $i ( 0 .. $n - 2 ) {
        # zz esta en orden "mas reciente primero": el punto i es mas nuevo que i+1
        my $v_new = $zz->[ 2 * $i ];
        my $b_new = $zz->[ 2 * $i + 1 ];
        my $v_old = $zz->[ 2 * ( $i + 1 ) ];
        my $b_old = $zz->[ 2 * ( $i + 1 ) + 1 ];

        unshift @segments, {
            from_index => $b_old,
            from_price => $v_old,
            to_index   => $b_new,
            to_price   => $v_new,
            dir        => ( $v_new > $v_old ) ? 'up' : 'down',
        };
    }
    return \@segments;
}

# -----------------------------------------------------------------------------
# get_fibo_levels: replica el bloque de Fibonacci del Pine. Devuelve undef si
# no hay suficientes puntos (zigzag necesita al menos 6 valores = 3 pivotes).
# Cada nivel: { ratio, price, from_index (x1 = zigzag[5]), to_index (bar
#   actual = ultima vela conocida), label }
# -----------------------------------------------------------------------------
sub get_fibo_levels {
    my ($self) = @_;
    my $zz = $self->{_zigzag};
    return undef if @$zz < 6;

    my $y_from  = $zz->[2];   # zigzag[2] (price)
    my $y_to    = $zz->[4];   # zigzag[4] (price)
    my $x_from  = $zz->[5];   # zigzag[5] (bindex del pivote en zigzag[4])
    my $diff    = $y_to - $y_from;

    my $last_bar_idx = $#{ $self->{_c} };
    my $dir = $self->{_dir};
    my $ref_extreme = $zz->[0];   # zigzag[0]: extremo vigente (en formacion)

    my @out;
    my $stopit = 0;
    my $shown  = $self->_shown_levels_count;

    my $ratios = $self->{_fibo_ratios};
    for my $x ( 0 .. $#$ratios ) {
        last if $stopit && $x > $shown;

        my $ratio = $ratios->[$x];
        my $price = $y_from + $diff * $ratio;

        push @out, {
            ratio      => $ratio,
            price      => $price,
            from_index => $x_from,
            to_index   => $last_bar_idx,
        };

        if ( ( $dir == 1 && $price > $ref_extreme )
            || ( $dir == -1 && $price < $ref_extreme ) )
        {
            $stopit = 1;
        }
    }
    return \@out;
}

sub get_dir { return $_[0]->{_dir}; }

# -----------------------------------------------------------------------------
# _process_candle: traduccion literal del bloque de deteccion newbar + ph/pl
# + dir + actualizacion del array zigzag.
# -----------------------------------------------------------------------------
sub _process_candle {
    my ( $self, $idx ) = @_;
    my $c = $self->{_c}[$idx];

    my $bucket_ts = $self->_bucket_ts_for( $c->{ts} );
    my $is_newbar = ( !defined $self->{_prev_bucket_ts} )
        || ( $bucket_ts != $self->{_prev_bucket_ts} );
    $self->{_prev_bucket_ts} = $bucket_ts;

    push @{ $self->{_newbar_bar_indices} }, $idx if $is_newbar;

    # bi = valuewhen(newbar, bar_index, prd-1): el indice de la newbar
    # numero (prd-1) hacia atras contando desde la mas reciente (0 = actual).
    my $p  = $self->{period};
    my $nb = $self->{_newbar_bar_indices};
    return unless @$nb >= $p;   # sin suficientes newbars todavia -> len=na
    my $bi  = $nb->[ -$p ];
    my $len = $idx - $bi + 1;
    return if $len <= 0;

    # ph/pl: highestbars/lowestbars sobre la ventana [idx-len+1, idx]
    my ( $ph, $pl ) = $self->_ph_pl( $idx, $len );

    $self->{_prev_dir} = $self->{_dir};
    if ( defined($ph) && !defined($pl) ) {
        $self->{_dir} = 1;
    }
    elsif ( defined($pl) && !defined($ph) ) {
        $self->{_dir} = -1;
    }
    # si ambos o ninguno definido: dir se mantiene (var, sin cambios)

    return unless defined($ph) || defined($pl);

    my $dir_changed = ( $self->{_dir} != $self->{_prev_dir} );
    my $value = ( $self->{_dir} == 1 ) ? $ph : $pl;
    return unless defined $value;

    if ($dir_changed) {
        $self->_add_to_zigzag( $value, $idx );
    }
    else {
        $self->_update_zigzag( $value, $idx );
    }
}

# highestbars(high, len) == 0 ? high : na  /  lowestbars(low, len) == 0 ? low : na
# Equivale a: high actual es el maximo de la ventana [idx-len+1, idx] (y
# analogo para low). Se devuelve el valor si aplica, undef si no.
sub _ph_pl {
    my ( $self, $idx, $len ) = @_;
    my $from = $idx - $len + 1;
    $from = 0 if $from < 0;

    my $c = $self->{_c};
    my $cur = $c->[$idx];

    my $is_highest = 1;
    my $is_lowest  = 1;
    for my $i ( $from .. $idx - 1 ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        $is_highest = 0 if $candle->{high} > $cur->{high};
        $is_lowest  = 0 if $candle->{low}  < $cur->{low};
    }
    my $ph = $is_highest ? $cur->{high} : undef;
    my $pl = $is_lowest  ? $cur->{low}  : undef;
    return ( $ph, $pl );
}

sub _add_to_zigzag {
    my ( $self, $value, $bindex ) = @_;
    unshift @{ $self->{_zigzag} }, $bindex;
    unshift @{ $self->{_zigzag} }, $value;
    if ( @{ $self->{_zigzag} } > 500 ) {   # max_array_size=50 puntos = 100 floats
        pop @{ $self->{_zigzag} };
        pop @{ $self->{_zigzag} };
    }
}

sub _update_zigzag {
    my ( $self, $value, $bindex ) = @_;
    my $zz = $self->{_zigzag};
    if ( !@$zz ) {
        $self->_add_to_zigzag( $value, $bindex );
        return;
    }
    my $dir = $self->{_dir};
    if ( ( $dir == 1 && $value > $zz->[0] ) || ( $dir == -1 && $value < $zz->[0] ) ) {
        $zz->[0] = $value;
        $zz->[1] = $bindex;
    }
}

# -----------------------------------------------------------------------------
# _bucket_ts_for: timestamp de inicio de bucket para la resolucion elegida.
# Soporta minutos intradia directos, D/W ancladas a GMT-5 (mismo criterio
# que Market::MarketData) y M (mes calendario, GMT-5).
# -----------------------------------------------------------------------------
my %RES_MINUTES = (
    '1min' => 1, '3min' => 3, '5min' => 5, '10min' => 10, '15min' => 15,
    '30min' => 30, '45min' => 45,
    '1h' => 60, '2h' => 120, '3h' => 180, '4h' => 240,
);

sub _bucket_ts_for {
    my ( $self, $ts ) = @_;
    my $res = $self->{resolution};

    if ( exists $RES_MINUTES{$res} ) {
        my $interval_sec = $RES_MINUTES{$res} * 60;
        return int( $ts / $interval_sec ) * $interval_sec;
    }

    my $tm = Time::Moment->from_epoch($ts)->with_offset_same_instant(GMT_OFFSET_MIN);

    if ( $res eq '1d' ) {
        return $self->_truncate_to_midnight($tm)->epoch;
    }
    if ( $res eq '1w' ) {
        my $dow = $tm->day_of_week;   # 1=Lunes .. 7=Domingo
        return $self->_truncate_to_midnight($tm)->minus_days( $dow - 1 )->epoch;
    }
    if ( $res eq '1m' ) {   # mes calendario
        return $self->_truncate_to_midnight($tm)->with_day_of_month(1)->epoch;
    }

    # fallback: tratar como minutos si viene un numero crudo
    if ( $res =~ /^(\d+)$/ ) {
        my $interval_sec = $1 * 60;
        return int( $ts / $interval_sec ) * $interval_sec;
    }
    return int($ts);
}

sub _truncate_to_midnight {
    my ( $self, $tm ) = @_;
    return $tm->with_hour(0)->with_minute(0)->with_second(0)->with_nanosecond(0);
}

# -----------------------------------------------------------------------------
# _build_fibo_ratios: equivalente al bloque barstate.isfirst del Pine.
# -----------------------------------------------------------------------------
sub _build_fibo_ratios {
    my ($self) = @_;
    my @ratios = (0.000);
    push @ratios, 0.236 if $self->{enable_236};
    push @ratios, 0.382 if $self->{enable_382};
    push @ratios, 0.500 if $self->{enable_500};
    push @ratios, 0.618 if $self->{enable_618};
    push @ratios, 0.786 if $self->{enable_786};

    for my $x ( 1 .. 5 ) {
        push @ratios, $x, $x + 0.272, $x + 0.414, $x + 0.618;
    }
    $self->{_fibo_ratios} = \@ratios;
}

sub _shown_levels_count {
    my ($self) = @_;
    my $n = 1;
    $n++ for grep { $self->{$_} } qw(enable_236 enable_382 enable_500 enable_618 enable_786);
    return $n;
}

1;