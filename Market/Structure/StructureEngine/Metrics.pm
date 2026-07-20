package Market::Structure::StructureEngine;

# =============================================================================
# StructureEngine::Metrics
# =============================================================================
# Prominence, hierarchy, scopes y estadisticos de swings.
# Continuacion del paquete Market::Structure::StructureEngine (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _pivot_prominence {
    my ($swings, $idx) = @_;
    return 0 unless $swings && ref $swings eq 'ARRAY';
    return 0 unless defined $idx && $idx >= 0 && $idx <= $#$swings;

    my $s = $swings->[$idx];
    return 0 unless $s && defined $s->{price};

    my @distances;
    if ($idx > 0 && defined $swings->[$idx - 1]{price}) {
        push @distances, abs($s->{price} - $swings->[$idx - 1]{price});
    }
    if ($idx < $#$swings && defined $swings->[$idx + 1]{price}) {
        push @distances, abs($s->{price} - $swings->[$idx + 1]{price});
    }
    return 0 unless @distances;

    my $prominence = $distances[0];
    for my $d (@distances) {
        $prominence = $d if $d < $prominence;
    }
    return $prominence;
}

sub _adjacent_distance {
    my ($swings, $idx) = @_;
    return 0 unless $swings && ref $swings eq 'ARRAY';
    return 0 unless defined $idx && $idx >= 0 && $idx <= $#$swings;
    my $s = $swings->[$idx];
    return 0 unless $s && defined $s->{index};

    my @distances;
    push @distances, abs($s->{index} - $swings->[$idx - 1]{index})
        if $idx > 0 && defined $swings->[$idx - 1]{index};
    push @distances, abs($s->{index} - $swings->[$idx + 1]{index})
        if $idx < $#$swings && defined $swings->[$idx + 1]{index};
    return 0 unless @distances;

    my $distance = $distances[0];
    for my $d (@distances) {
        $distance = $d if $d < $distance;
    }
    return $distance;
}

sub _swing_depth {
    my ($swings, $idx) = @_;
    return 0 unless $swings && ref $swings eq 'ARRAY';
    return 0 unless defined $idx && $idx >= 0 && $idx <= $#$swings;
    my $s = $swings->[$idx];
    return 0 unless $s && defined $s->{price};

    my @prices = grep { defined $_ } map { $_->{price} } @$swings;
    return 0 unless @prices;
    my ($min, $max) = ($prices[0], $prices[0]);
    for my $p (@prices) {
        $min = $p if $p < $min;
        $max = $p if $p > $max;
    }
    my $range = $max - $min;
    return 0 if $range <= 0;
    return abs($s->{price} - (($max + $min) / 2)) / $range;
}

sub _median {
    my @values = sort { $a <=> $b } grep { defined $_ } @_;
    return 0 unless @values;
    my $n = scalar @values;
    return $values[int($n / 2)] if $n % 2;
    return ($values[$n / 2 - 1] + $values[$n / 2]) / 2;
}

sub _lower_quartile {
    my @values = sort { $a <=> $b } grep { defined $_ } @_;
    return 0 unless @values;
    return $values[int(@values * 0.25)];
}

sub _upper_quartile {
    my @values = sort { $a <=> $b } grep { defined $_ } @_;
    return 0 unless @values;
    return $values[int(@values * 0.75)];
}

sub _hierarchy_thresholds {
    my ($tol, @source) = @_;
    my @swings = grep { $_ && ref $_ eq 'HASH' } @source;
    my @prominences = grep { defined $_ && $_ > 0 } map { $_->{prominence} } @swings;
    my @distances = grep { defined $_ && $_ > 0 } map { $_->{distance} } @swings;
    $tol = 0 if !defined $tol || $tol < 0;
    return (intermediate => 0, major => 0) unless @prominences;
    return (
        intermediate => _median(@prominences),
        major        => _upper_quartile(@prominences),
        atr          => $tol,
        distance     => _median(@distances),
        depth        => _median(grep { defined $_ } map { $_->{depth} } @swings),
    );
}

sub _swing_hierarchy {
    my ($profile, $prominence, $distance, $depth, $confirmed, $thresholds) = @_;
    $prominence //= 0;
    $distance //= 0;
    $depth //= 0;
    $confirmed //= 0;
    $thresholds ||= {};
    my $major = $thresholds->{major} // 0;
    my $intermediate = $thresholds->{intermediate} // 0;
    my $atr = $thresholds->{atr} // 0;
    my $median_distance = $thresholds->{distance} // 0;
    my $median_depth = $thresholds->{depth} // 0;

    my $prominent = $major > 0 && $prominence >= $major;
    my $structural = $intermediate > 0 && $prominence >= $intermediate;
    my $atr_confirmed = $atr > 0 && $prominence >= $atr;
    my $spaced = $median_distance > 0 && $distance >= $median_distance;

    return 'Major' if $confirmed && $prominent && $atr_confirmed && ($spaced || $depth >= $median_depth);
    return 'Intermediate' if $confirmed && ($structural || ($atr_confirmed && $spaced));
    return 'Minor';
}

sub _collapse_same_side_swings {
    my (@swings) = @_;
    my @out;
    for my $s (@swings) {
        if (@out && (($s->{type} || '') eq ($out[-1]{type} || ''))) {
            $out[-1] = $s if _more_extreme_swing($s, $out[-1]);
            next;
        }
        push @out, $s;
    }
    return @out;
}

sub _more_extreme_swing {
    my ($candidate, $current) = @_;
    return 0 unless $candidate && $current;
    my $type = $candidate->{type} || '';
    return ($candidate->{price} // 0) > ($current->{price} // 0) if $type eq 'swing_high';
    return ($candidate->{price} // 0) < ($current->{price} // 0) if $type eq 'swing_low';
    return 0;
}

sub _classify_swing {
    my ($self, $current, $swing, $tol) = @_;
    $tol //= 1e-6;
    my $source_type = $swing->{type} || '';
    return 'swing' unless $source_type eq 'swing_high' || $source_type eq 'swing_low';

    my $prev_same;
    for my $s (reverse @$current) {
        next unless ($s->{source_type} || '') eq $source_type;
        $prev_same = $s;
        last;
    }
    return 'swing' unless $prev_same;

    return $self->_compare_prices($source_type, $prev_same->{price}, $swing->{price}, $tol);
}

sub _reclassify_vs_external {
    my ($self, $swings, $tol) = @_;
    $tol //= 1e-6;
    return unless $swings && @$swings;

    my ($last_ext_high, $last_ext_low);
    my @sorted = sort { $a->{index} <=> $b->{index} } @$swings;

    for my $s (@sorted) {
        my $st = $s->{source_type} || '';
        next unless $st eq 'swing_high' || $st eq 'swing_low';

        if ($st eq 'swing_high') {
            if (defined $last_ext_high) {
                my $class = $self->_compare_prices('swing_high', $last_ext_high, $s->{price}, $tol);
                $s->{type}  = $class;
                $s->{label} = $self->_swing_label($class);
            }
            $last_ext_high = $s->{price}
                if ($s->{scope} // '') eq 'external';
        }
        else {
            if (defined $last_ext_low) {
                my $class = $self->_compare_prices('swing_low', $last_ext_low, $s->{price}, $tol);
                $s->{type}  = $class;
                $s->{label} = $self->_swing_label($class);
            }
            $last_ext_low = $s->{price}
                if ($s->{scope} // '') eq 'external';
        }
    }
}

sub _compare_prices {
    my ($self, $source_type, $prev_price, $curr_price, $tol) = @_;
    $tol //= 1e-6;

    if ($source_type eq 'swing_high') {
        return 'Higher High' if $curr_price > $prev_price + $tol;
        return 'Lower High'  if $curr_price < $prev_price - $tol;
        return 'Equal High';
    }
    return 'Higher Low' if $curr_price > $prev_price + $tol;
    return 'Lower Low'  if $curr_price < $prev_price - $tol;
    return 'Equal Low';
}

# _assign_swing_scopes($swings)
# Leg alcista: HH/HL externos; LH/LL internos. Leg bajista: inverso.
sub _assign_swing_scopes {
    my ($self, $swings) = @_;
    return unless $swings && @$swings;

    my $leg     = 0;
    my $leg_id  = 0;
    my @labeled = sort { $a->{index} <=> $b->{index} }
        grep { ($_->{label} || '') ne '' } @$swings;

    for my $s (@labeled) {
        my $lbl  = $s->{label};
        my $kind = $s->{kind} // '';

        if ($leg == 0) {
            $s->{scope}  = 'external';
            $s->{leg_id} = $leg_id;
            $leg = 1  if $lbl =~ /^(HH|HL)$/ || ($lbl eq 'EQH' && $kind eq 'high');
            $leg = -1 if $lbl =~ /^(LL|LH)$/ || ($lbl eq 'EQL' && $kind eq 'low');
            next;
        }

        if ($leg > 0) {
            if ($lbl =~ /^(HH|HL)$/ || ($lbl eq 'EQH' && $kind eq 'high')
                || ($lbl eq 'EQL' && $kind eq 'low'))
            {
                $s->{scope} = 'external';
            }
            else {
                $s->{scope} = 'internal';
            }
            if ($lbl eq 'LL') {
                $leg = -1;
                $leg_id++;
            }
        }
        else {
            if ($lbl =~ /^(LL|LH)$/ || ($lbl eq 'EQL' && $kind eq 'low')
                || ($lbl eq 'EQH' && $kind eq 'high'))
            {
                $s->{scope} = 'external';
            }
            else {
                $s->{scope} = 'internal';
            }
            if ($lbl eq 'HH') {
                $leg = 1;
                $leg_id++;
            }
        }
        $s->{leg_id} = $leg_id;
    }

    for my $s (@$swings) {
        $s->{scope}  //= 'internal';
        $s->{leg_id} //= $leg_id;
    }
}

sub _swing_label {
    my ($self, $type) = @_;
    return '' unless defined $type;
    return 'HH'  if $type eq 'Higher High';
    return 'HL'  if $type eq 'Higher Low';
    return 'LH'  if $type eq 'Lower High';
    return 'LL'  if $type eq 'Lower Low';
    return 'EQH' if $type eq 'Equal High';
    return 'EQL' if $type eq 'Equal Low';
    return '';
}

sub _derive_trend {
    my ($self, $swings) = @_;
    return 'neutral' unless $swings && @$swings;

    my @external = grep {
        ($_->{scope} // '') eq 'external' && (($_->{label} || '') ne '')
    } @$swings;
    return 'neutral' unless @external;

    my ($bull, $bear) = (0, 0);
    my $from = @external > 4 ? @external - 4 : 0;
    for my $s (@external[$from .. $#external]) {
        my $lbl = $s->{label} || '';
        $bull++ if $lbl =~ /^(HH|HL)$/ || $lbl eq 'EQH';
        $bear++ if $lbl =~ /^(LL|LH)$/ || $lbl eq 'EQL';
    }
    return 'bullish' if $bull > $bear;
    return 'bearish' if $bear > $bull;

    my $last_lbl = $external[-1]{label} || '';
    return 'bullish' if $last_lbl =~ /^(HH|HL)$/;
    return 'bearish' if $last_lbl =~ /^(LL|LH)$/;
    return 'neutral';
}


1;
