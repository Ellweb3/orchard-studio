//! FL value laws, ported from src/model/scales.ts and src/engine/Sequencer.ts.

use std::f64::consts::PI;

const LN11: f64 = 2.397_895_272_798_371;

/// FL's single volume curve: G(x) = (11^x - 1) / 10, x = 1 is unity.
pub fn fl_gain(x: f64) -> f64 {
    if x <= 0.0 {
        return 0.0;
    }
    ((LN11 * x).exp() - 1.0) / 10.0
}

/// Mixer fader 0..1, 0.8 = 0 dB.
pub fn fader_to_gain(v: f64) -> f64 {
    fl_gain(v / 0.8)
}

/// Channel volume knob 0..1 (default 100/128 = -5.2 dB).
pub fn channel_volume_to_gain(v: f64) -> f64 {
    fl_gain(v.clamp(0.0, 1.0))
}

/// Note velocity 0..128, 100 = unity.
pub fn velocity_to_gain(vel: f64) -> f64 {
    fl_gain(vel / 100.0)
}

/// Circular (constant power) pan law, -3 dB at centre. Returns (gainL, gainR).
pub fn pan_gains(pan: f64) -> (f64, f64) {
    let th = (pan.clamp(-1.0, 1.0) + 1.0) * PI / 4.0;
    (th.cos(), th.sin())
}

/// Swing delays every second step; at 100% the delayed step moves by half a step.
/// Piecewise-linear time warp of the step pair (Sequencer.ts swingOffset).
pub fn swing_offset(pos: f64, amount: f64, ticks_per_step: f64) -> f64 {
    if amount <= 0.0 {
        return 0.0;
    }
    let pair = ticks_per_step * 2.0;
    let in_pair = ((pos % pair) + pair) % pair;
    let s = amount / 2.0;
    let warp_point = ticks_per_step * (1.0 + s);
    let warped = if in_pair <= ticks_per_step {
        (in_pair / ticks_per_step) * warp_point
    } else {
        warp_point + ((in_pair - ticks_per_step) / ticks_per_step) * (pair - warp_point)
    };
    warped - in_pair
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_laws_match_fl() {
        assert!((fl_gain(1.0) - 1.0).abs() < 1e-12);
        assert!((fader_to_gain(0.8) - 1.0).abs() < 1e-12);
        // default channel volume 78.125% = -5.2 dB (README)
        let db = 20.0 * channel_volume_to_gain(100.0 / 128.0).log10();
        assert!((db - -5.2).abs() < 0.05, "{db}");
        // velocity 128 = +6.25 dB
        let db = 20.0 * velocity_to_gain(128.0).log10();
        assert!((db - 6.25).abs() < 0.05, "{db}");
        // fader max +5.6 dB
        let db = 20.0 * fader_to_gain(1.0).log10();
        assert!((db - 5.6).abs() < 0.05, "{db}");
    }

    #[test]
    fn pan_is_minus_3db_at_centre() {
        let (l, r) = pan_gains(0.0);
        assert!((20.0 * l.log10() - -3.0103).abs() < 1e-3);
        assert!((l - r).abs() < 1e-12);
        let (l, r) = pan_gains(-1.0);
        assert!((l - 1.0).abs() < 1e-12 && r.abs() < 1e-12);
    }

    #[test]
    fn swing_moves_even_steps_only() {
        let tps = 24.0;
        assert_eq!(swing_offset(0.0, 1.0, tps), 0.0);
        assert!((swing_offset(24.0, 1.0, tps) - 12.0).abs() < 1e-9);
        assert!((swing_offset(24.0, 0.5, tps) - 6.0).abs() < 1e-9);
        assert!(swing_offset(48.0, 1.0, tps).abs() < 1e-9);
    }
}
