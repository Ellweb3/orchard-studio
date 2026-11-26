//! Procedurally synthesised starter samples, a 1:1 port of src/audio/drumkit.ts.
//! Math runs in f64 and buffers are stored as f32 exactly like the TS
//! Float32Array version, so both produce the same sounds (see tests).

use std::f64::consts::PI;

pub const SR: f64 = 44100.0;

pub struct Sample {
    pub name: &'static str,
    /// One (mono) or two (stereo) channels.
    pub channels: Vec<Vec<f32>>,
    pub sample_rate: f64,
}

impl Sample {
    pub fn len(&self) -> usize {
        self.channels[0].len()
    }
}

struct Rng(u32);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        (self.0 as f64 / 4_294_967_296.0) * 2.0 - 1.0
    }
}

fn normalize(buf: &mut [f32], peak: f64) {
    let mut m = 0.0f64;
    for &x in buf.iter() {
        m = m.max((x as f64).abs());
    }
    if m > 0.0 {
        for x in buf.iter_mut() {
            *x = (*x as f64 * (peak / m)) as f32;
        }
    }
}

fn one_pole_lp(buf: &mut [f32], hz: f64) {
    let a = (-2.0 * PI * hz / SR).exp();
    let mut y = 0.0f64;
    for x in buf.iter_mut() {
        y = *x as f64 * (1.0 - a) + y * a;
        *x = y as f32;
    }
}

fn one_pole_hp(buf: &mut [f32], hz: f64) {
    let a = (-2.0 * PI * hz / SR).exp();
    let (mut y, mut x_prev) = (0.0f64, 0.0f64);
    for v in buf.iter_mut() {
        let x = *v as f64;
        y = a * (y + x - x_prev);
        x_prev = x;
        *v = y as f32;
    }
}

fn bandpass(buf: &mut [f32], hz: f64, q: f64) {
    let w = 2.0 * PI * hz / SR;
    let alpha = w.sin() / (2.0 * q);
    let (b0, b2, a0, a1, a2) = (alpha, -alpha, 1.0 + alpha, -2.0 * w.cos(), 1.0 - alpha);
    let (mut x1, mut x2, mut y1, mut y2) = (0.0f64, 0.0, 0.0, 0.0);
    for v in buf.iter_mut() {
        let x = *v as f64;
        let y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        *v = y as f32;
    }
}

fn len_of(sec: f64) -> usize {
    (SR * sec).floor() as usize
}

pub fn make_kick() -> Vec<f32> {
    let len = len_of(0.55);
    let mut out = vec![0f32; len];
    let mut phase = 0.0f64;
    let mut noise = Rng(7);
    for (i, o) in out.iter_mut().enumerate() {
        let t = i as f64 / SR;
        let f = 48.0 + 190.0 * (-t / 0.032).exp() + 40.0 * (-t / 0.004).exp();
        phase += 2.0 * PI * f / SR;
        let body = phase.sin() * (-t / 0.28).exp() * (1.0 - (-t / 0.0008).exp());
        let click = noise.next() * (-t / 0.0015).exp() * 0.35;
        *o = ((body + click) * 1.6).tanh() as f32;
    }
    normalize(&mut out, 0.89);
    out
}

pub fn make_clap() -> Vec<f32> {
    let len = len_of(0.42);
    let mut out = vec![0f32; len];
    let mut noise = Rng(1234);
    let bursts = [0.0, 0.0105, 0.021, 0.0335];
    for (i, o) in out.iter_mut().enumerate() {
        let t = i as f64 / SR;
        let mut env = 0.0f64;
        for &b in &bursts {
            if t >= b {
                env = env.max((-(t - b) / 0.0055).exp());
            }
        }
        let tail = if t >= 0.0335 { (-(t - 0.0335) / 0.11).exp() * 0.75 } else { 0.0 };
        *o = (noise.next() * env.max(tail)) as f32;
    }
    bandpass(&mut out, 1150.0, 0.9);
    one_pole_hp(&mut out, 300.0);
    normalize(&mut out, 0.89);
    out
}

pub fn make_hat(open: bool) -> Vec<f32> {
    let len = len_of(if open { 0.5 } else { 0.11 });
    let mut out = vec![0f32; len];
    let mut noise = Rng(if open { 99 } else { 42 });
    let ratios = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21];
    let base = 410.0;
    let mut ph = [0.0f64; 6];
    for (i, o) in out.iter_mut().enumerate() {
        let t = i as f64 / SR;
        let mut metal = 0.0;
        for k in 0..ratios.len() {
            ph[k] += base * ratios[k] / SR;
            metal += if ph[k] % 1.0 < 0.5 { 1.0 } else { -1.0 };
        }
        let env = if open { (-t / 0.16).exp() } else { (-t / 0.022).exp() };
        *o = ((metal * 0.12 + noise.next() * 0.7) * env * (1.0 - (-t / 0.0004).exp())) as f32;
    }
    one_pole_hp(&mut out, 6500.0);
    one_pole_hp(&mut out, 6500.0);
    normalize(&mut out, 0.8);
    out
}

pub fn make_snare() -> Vec<f32> {
    let len = len_of(0.35);
    let mut out = vec![0f32; len];
    let mut noise = Rng(555);
    let mut nbuf: Vec<f32> = (0..len).map(|_| noise.next() as f32).collect();
    one_pole_hp(&mut nbuf, 1800.0);
    one_pole_lp(&mut nbuf, 9000.0);
    let (mut p1, mut p2) = (0.0f64, 0.0f64);
    for (i, o) in out.iter_mut().enumerate() {
        let t = i as f64 / SR;
        let f = 185.0 + 60.0 * (-t / 0.01).exp();
        p1 += 2.0 * PI * f / SR;
        p2 += 2.0 * PI * f * 1.62 / SR;
        let tone = (p1.sin() * 0.8 + p2.sin() * 0.35) * (-t / 0.055).exp();
        let rattle = nbuf[i] as f64 * (-t / 0.085).exp() * 0.9;
        *o = (((tone + rattle) * 1.3).tanh() * (1.0 - (-t / 0.0005).exp())) as f32;
    }
    normalize(&mut out, 0.89);
    out
}

pub fn make_bass808() -> Vec<f32> {
    let len = len_of(1.6);
    let mut out = vec![0f32; len];
    let mut phase = 0.0f64;
    for (i, o) in out.iter_mut().enumerate() {
        let t = i as f64 / SR;
        let f = 55.0 * (1.0 + 0.9 * (-t / 0.018).exp());
        phase += 2.0 * PI * f / SR;
        *o = ((phase.sin() * 1.8).tanh() * (-t / 0.9).exp() * (1.0 - (-t / 0.001).exp())) as f32;
    }
    normalize(&mut out, 0.89);
    out
}

pub fn make_chord_stab() -> Vec<Vec<f32>> {
    let len = len_of(1.2);
    let mut l = vec![0f32; len];
    let mut r = vec![0f32; len];
    let notes = [60.0, 63.0, 67.0, 70.0];
    let mut ph = [0.0f64; 8];
    for i in 0..len {
        let t = i as f64 / SR;
        let (mut sl, mut sr) = (0.0f64, 0.0f64);
        for (n, &k) in notes.iter().enumerate() {
            let f = 440.0 * 2f64.powf((k - 69.0) / 12.0);
            ph[n * 2] += f * 1.003 / SR;
            ph[n * 2 + 1] += f * 0.997 / SR;
            let saw1 = 2.0 * (ph[n * 2] % 1.0) - 1.0;
            let saw2 = 2.0 * (ph[n * 2 + 1] % 1.0) - 1.0;
            sl += saw1 * 0.7 + saw2 * 0.3;
            sr += saw1 * 0.3 + saw2 * 0.7;
        }
        let env = (-t / 0.35).exp() * (1.0 - (-t / 0.002).exp());
        l[i] = (sl * env) as f32;
        r[i] = (sr * env) as f32;
    }
    one_pole_lp(&mut l, 2600.0);
    one_pole_lp(&mut r, 2600.0);
    one_pole_lp(&mut l, 4000.0);
    one_pole_lp(&mut r, 4000.0);
    let m = l.iter().chain(r.iter()).fold(0.0f64, |m, &x| m.max((x as f64).abs()));
    for i in 0..len {
        l[i] = (l[i] as f64 * (0.85 / m)) as f32;
        r[i] = (r[i] as f64 * (0.85 / m)) as f32;
    }
    vec![l, r]
}

/// Metronome clicks (engine-internal, not in the TS kit): short sine blips.
fn make_click(freq: f64) -> Vec<f32> {
    let len = len_of(0.03);
    (0..len)
        .map(|i| {
            let t = i as f64 / SR;
            ((2.0 * PI * freq * t).sin() * (-t / 0.006).exp() * 0.5) as f32
        })
        .collect()
}

/// Order is the public sample id used over FFI (keep in sync with Dart `kSounds`).
pub fn builtin_kit() -> Vec<Sample> {
    let mono = |name, v: Vec<f32>| Sample { name, channels: vec![v], sample_rate: SR };
    vec![
        mono("Kick", make_kick()),
        mono("Clap", make_clap()),
        mono("Hat", make_hat(false)),
        mono("Open Hat", make_hat(true)),
        mono("Snare", make_snare()),
        mono("808 Bass", make_bass808()),
        Sample { name: "Chord Stab", channels: make_chord_stab(), sample_rate: SR },
    ]
}

pub fn metronome_clicks() -> (Sample, Sample) {
    (
        Sample { name: "click hi", channels: vec![make_click(1760.0)], sample_rate: SR },
        Sample { name: "click lo", channels: vec![make_click(1320.0)], sample_rate: SR },
    )
}
