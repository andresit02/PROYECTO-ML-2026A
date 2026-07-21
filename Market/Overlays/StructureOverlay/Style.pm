package Market::Overlays::StructureOverlay;

# =============================================================================
# StructureOverlay::Style
# =============================================================================
# Colores, estilos de etiqueta y helpers de clip.
# Continuacion del paquete Market::Overlays::StructureOverlay (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _swing_abbr {
    my ($stype) = @_;
    return 'HH'  if $stype eq 'Higher High';
    return 'HL'  if $stype eq 'Higher Low';
    return 'LH'  if $stype eq 'Lower High';
    return 'LL'  if $stype eq 'Lower Low';
    return 'EQH' if $stype eq 'Equal High';
    return 'EQL' if $stype eq 'Equal Low';
    return 'SH'  if $stype eq 'swing_high';
    return 'SL'  if $stype eq 'swing_low';
    return '';
}

sub _swing_colors {
    my ($abbr, $scope, $style) = @_;
    $style ||= {};
    my ($fg, $bg);
    if ($abbr eq 'HH' || $abbr eq 'HL') {
        ($fg, $bg) = ($style->{bull_fg} || '#81c784', $style->{bull_bg} || '#1b3a1f');
    }
    elsif ($abbr eq 'LH' || $abbr eq 'LL') {
        ($fg, $bg) = ($style->{bear_fg} || '#ef9a9a', $style->{bear_bg} || '#3a1b1b');
    }
    elsif ($abbr eq 'EQH' || $abbr eq 'EQL') {
        ($fg, $bg) = ($style->{eq_fg} || '#ffd54f', $style->{eq_bg} || '#3a3218');
    }
    else {
        ($fg, $bg) = ($style->{neutral_fg} || '#b0bec5', $style->{neutral_bg} || '#263238');
    }
    if (($scope // '') eq 'internal') {
        $bg = $style->{internal_bg} || '#1a1a1a';
        $fg = $style->{internal_fg} || '#78909c';
    }
    return ($fg, $bg);
}

sub _event_style {
    my ($point, $style) = @_;
    $style ||= {};
    if ($point->{type} && $point->{type} eq 'BOS') {
        my $bear = lc($point->{direction} // '') eq 'bearish';
        return $bear ? ($style->{bear_fg} || '#ff5252', $style->{bear_bg} || '#3a1515')
                     : ($style->{bull_fg} || '#69f0ae', $style->{bull_bg} || '#153a22');
    }
    if (($point->{type} || '') =~ /CHoCH/i || defined $point->{new_trend}) {
        my $bear = lc($point->{direction} // $point->{new_trend} // '') eq 'bearish';
        return $bear ? ('#ff9800', '#3a2a10') : ('#40c4ff', '#102a3a');
    }
    return ('#ff9800', '#3a2a10');
}

sub _draw_tag {
    my ($canvas, $x, $y, $text, $fg, $bg, $style) = @_;
    return unless $canvas && defined $x && defined $y && defined $text;
    $style ||= {};

    my $pad_x = $style->{pad_x} || 3;
    my $pad_y = $style->{pad_y} || 1;
    my $w = length($text) * ($style->{text_w} || 5) + $pad_x * 2;
    my $h = ($style->{text_h} || 10) + $pad_y * 2;

    $canvas->createRectangle(
        $x - $w / 2, $y - $h / 2, $x + $w / 2, $y + $h / 2,
        -fill => $bg, -outline => $fg, -width => 1,
        -tags => ['overlay_structure'],
    );
    $canvas->createText($x, $y,
        -text   => $text,
        -anchor => 'c',
        -fill   => $fg,
        -font   => $style->{font} || 'Helvetica 7 bold',
        -tags   => ['overlay_structure'],
    );
}

sub _event_index {
    my ($point) = @_;
    return $point->{index} if defined $point->{index};
    return $point->{confirmation_index} if defined $point->{confirmation_index};
    return $point->{event_index} if defined $point->{event_index};
    return $point->{break_index} if defined $point->{break_index};
    return undef;
}

sub _event_label {
    my ($point) = @_;
    return 'BOS' if $point->{type} && $point->{type} eq 'BOS' && !defined $point->{direction};

    if ($point->{type} && $point->{type} eq 'BOS') {
        my $dir = lc($point->{direction} // '');
        return $dir eq 'bullish' ? 'BOS+'
             : $dir eq 'bearish' ? 'BOS-'
             : 'BOS';
    }

    if ($point->{type} && $point->{type} =~ /CHoCH/i) {
        my $dir = lc($point->{direction} // $point->{new_trend} // '');
        return $dir eq 'bullish' ? 'CHoCH+'
             : $dir eq 'bearish' ? 'CHoCH-'
             : 'CHoCH';
    }

    if (defined $point->{previous_trend} || defined $point->{new_trend}) {
        my $new_trend = lc($point->{new_trend} // '');
        return $new_trend eq 'bullish' ? 'CHoCH+'
             : $new_trend eq 'bearish' ? 'CHoCH-'
             : 'CHoCH';
    }

    return defined $point->{type} ? uc($point->{type}) : 'STRUCT';
}

sub _y_in_clip {
    my ($y, $top, $bottom) = @_;
    return 1 unless defined $y;
    return 0 if defined $top    && $y < $top - 8;
    return 0 if defined $bottom && $y > $bottom + 4;
    return 1;
}

# _clamp_label_y($y, $top, $bottom, $scale) -> $y
# Mantiene la etiqueta dentro del panel de precios (margen interno), evitando
# que se descarte por clip cuando el pivote esta en el extremo del rango AUTO.
sub _clamp_label_y {
    my ($y, $top, $bottom, $scale) = @_;
    return $y unless defined $y;

    my $margin = 10;
    my $lo = defined $top    ? $top + $margin    : $margin;
    my $hi = defined $bottom ? $bottom - $margin : undef;
    if (!defined $hi && $scale) {
        my $h  = $scale->{height} || 0;
        my $yo = $scale->{y_offset} || 0;
        $hi = $yo + $h - $margin if $h > 0;
    }
    $y = $lo if defined $lo && $y < $lo;
    $y = $hi if defined $hi && $y > $hi;
    return $y;
}


1;
