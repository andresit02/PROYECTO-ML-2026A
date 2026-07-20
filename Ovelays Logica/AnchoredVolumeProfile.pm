package Market::Overlays::AnchoredVolumeProfile;

use strict;
use warnings;

use constant TAG        => 'overlay_avp';
use constant TAG_LABELS => 'overlay_avp_labels';

use constant {
    C_BUY       => '#26a69a',
    C_SELL      => '#ef5350',
    C_POC       => '#000000',
    C_ANCHOR    => '#4f8cff',
    MAX_WIDTH_FRACTION => 0.22,
    MIN_BAR_H          => 2,
};

sub tag         { return TAG; }
sub tag_labels  { return TAG_LABELS; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source => $args{source},
        show   => $args{show} // 1,
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
    my $profile = $src->get_profile or return;
    my $bins = $profile->{bins};
    return unless $bins && @$bins;

    my $anchor_idx   = $profile->{anchor_index};
    my $anchor_price = $profile->{anchor_price};
    my $plot_w       = $scale->_plot_w;

    my $max_bar_w  = $plot_w * MAX_WIDTH_FRACTION;
    return if $max_bar_w <= 1;

    my $baseline_x = $plot_w - $max_bar_w;
    my $max_total  = $profile->{max_total} || 1;

    # --- Marca vertical del ancla + puntito en el precio de ancla ---
    if ( defined $anchor_idx ) {
        my $ax = $scale->index_to_center_x($anchor_idx);
        if ( $ax >= 0 && $ax <= $plot_w ) {
            $canvas->createLine(
                $ax, $scale->_plot_y_top, $ax, $scale->_plot_y_bottom,
                -fill => C_ANCHOR, -width => 1, -dash => [ 3, 3 ],
                -tags => [TAG],
            );
            if ( defined $anchor_price ) {
                my $ay = $scale->value_to_y($anchor_price);
                my $r  = 6;   # antes 4 -- mas grande para que se note bien
                $canvas->createOval(
                    $ax - $r, $ay - $r, $ax + $r, $ay + $r,
                    -fill => C_ANCHOR, -outline => '#ffffff', -width => 2,
                    -tags => [TAG],
                );
            }
            $canvas->createText(
                $ax + 4, $scale->_plot_y_top + 10,
                -text => 'AVP', -anchor => 'w', -fill => C_ANCHOR,
                -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
            );
        }
    }

    my $bin_gap = 1;

    my ($poc_bin_data) = grep { $_->{is_poc} } @$bins;
    my $poc_price_mid;
    $poc_price_mid = ( $poc_bin_data->{price_lo} + $poc_bin_data->{price_hi} ) / 2
        if $poc_bin_data;

    my ( $poc_x1, $poc_x2, $poc_y1, $poc_y2 );

    for my $b (@$bins) {
        next unless $scale->value_in_range( $b->{price_lo} )
                 || $scale->value_in_range( $b->{price_hi} )
                 || ( $b->{price_lo} < $scale->{min_val}
                   && $b->{price_hi} > $scale->{max_val} );

        my $y1 = $scale->value_to_y( $b->{price_hi} );
        my $y2 = $scale->value_to_y( $b->{price_lo} );
        ( $y1, $y2 ) = ( $y2, $y1 ) if $y1 > $y2;
        next if ( $y2 - $y1 ) < MIN_BAR_H;

        my ( $yy1, $yy2 ) = ( $y1, $y2 );
        if ( ( $yy2 - $yy1 ) > ( 2 * $bin_gap + MIN_BAR_H ) ) {
            $yy1 += $bin_gap;
            $yy2 -= $bin_gap;
        }

        my $bar_len = ( $b->{total} / $max_total ) * $max_bar_w;
        next if $bar_len <= 0;

        my $buy_len  = $b->{total} > 0 ? ( $b->{buy}  / $b->{total} ) * $bar_len : 0;
        my $sell_len = $bar_len - $buy_len;

        my $x3 = $plot_w;
        my $x2 = $x3 - $sell_len;
        my $x1 = $x2 - $buy_len;

        $canvas->createRectangle( $x1, $yy1, $x2, $yy2,
            -fill => C_BUY, -outline => C_BUY, -width => 0, -tags => [TAG] )
            if $buy_len > 0;
        $canvas->createRectangle( $x2, $yy1, $x3, $yy2,
            -fill => C_SELL, -outline => C_SELL, -width => 0, -tags => [TAG] )
            if $sell_len > 0;

        if ( $b->{is_poc} ) {
            $poc_x1 = $x1;
            $poc_x2 = $x3;
            $poc_y1 = $yy1;
            $poc_y2 = $yy2;
        }
    }

    if ( defined $poc_x1 ) {
        $canvas->createRectangle( $poc_x1, $poc_y1, $poc_x2, $poc_y2,
            -fill => '', -outline => C_POC, -width => 2, -tags => [TAG] );
    }


    if ( defined $poc_price_mid && $scale->value_in_range($poc_price_mid) ) {
        my $py = $scale->value_to_y($poc_price_mid);
        $canvas->createLine(
            0, $py, $plot_w, $py,
            -fill => C_POC, -width => 2, -dash => [ 6, 3 ], -tags => [TAG],
        );
    }

    $canvas->raise(TAG);
    $canvas->raise(TAG_LABELS);
}

1;