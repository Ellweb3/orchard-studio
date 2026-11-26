//! Mixer effects (stage 4): reverb, delay, filter, distortion, compressor.
//! Not ports of FL's plugins yet (src/engine/effects/plugins has those):
//! textbook DSP with FL-like parameter roles, all buffers allocated in `new`.
//! `process` is real-time safe. Parameters are normalised 0..1 and set by
//! index (`set`), so the UI can turn knobs without replacing the effect.

use std::f32::consts::PI;

pub const MAX_PARAMS: usize = 6;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FxKind {
    Reverb = 0,
    Delay = 1,
    Filter = 2,
    Distortion = 3,
    Compressor = 4,
}

impl FxKind {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Reverb,
            1 => Self::Delay,
            2 => Self::Filter,
            3 => Self::Distortion,
            4 => Self::Compressor,
            _ => return None,
        })
    }

    /// Default normalised parameters (keep in sync with Dart `kFxDefs`).
    pub fn defaults(self) -> [f32; MAX_PARAMS] {
        match self {
            // size, damping, wet, dry, width
            Self::Reverb => [0.6, 0.4, 0.3, 1.0, 1.0, 0.0],
            // time (0..1 -> 1/16..1 bar in 16ths), feedback, wet, dry, ping-pong
            Self::Delay => [0.125, 0.4, 0.35, 1.0, 1.0, 0.0],
            // cutoff, resonance, type (0 LP, .5 BP, 1 HP), mix
            Self::Filter => [0.6, 0.2, 0.0, 1.0, 0.0, 0.0],
            // drive, tone, mix, output
            Self::Distortion => [0.4, 0.7, 1.0, 0.7, 0.0, 0.0],
            // threshold, ratio, attack, release, makeup
            Self::Compressor => [0.6, 0.4, 0.2, 0.4, 0.2, 0.0],
        }
    }
}

// ------------------------------------------------------------------ reverb
const COMB_TUNING: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const AP_TUNING: [usize; 4] = [556, 441, 341, 225];
const STEREO_SPREAD: usize = 23;

struct Comb {
    buf: Vec<f32>,
    i: usize,
    store: f32,
}

impl Comb {
    fn new(len: usize) -> Self {
        Self { buf: vec![0.0; len.max(1)], i: 0, store: 0.0 }
    }
    #[inline]
    fn tick(&mut self, x: f32, feedback: f32, damp: f32) -> f32 {
        let y = self.buf[self.i];
        self.store = y * (1.0 - damp) + self.store * damp;
        self.buf[self.i] = x + self.store * feedback;
        self.i = (self.i + 1) % self.buf.len();
        y
    }
}

struct Allpass {
    buf: Vec<f32>,
    i: usize,
}

impl Allpass {
    fn new(len: usize) -> Self {
        Self { buf: vec![0.0; len.max(1)], i: 0 }
    }
    #[inline]
    fn tick(&mut self, x: f32) -> f32 {
        let b = self.buf[self.i];
        let y = b - x;
        self.buf[self.i] = x + b * 0.5;
        self.i = (self.i + 1) % self.buf.len();
        y
    }
}

/// Freeverb (Jezar), tunings scaled from 44.1 kHz.
pub struct Reverb {
    cl: Vec<Comb>,
    cr: Vec<Comb>,
    al: Vec<Allpass>,
    ar: Vec<Allpass>,
}

impl Reverb {
    fn new(sr: f32) -> Self {
        let k = sr / 44100.0;
        let s = |n: usize| (n as f32 * k) as usize;
        Self {
            cl: COMB_TUNING.iter().map(|&n| Comb::new(s(n))).collect(),
            cr: COMB_TUNING.iter().map(|&n| Comb::new(s(n + STEREO_SPREAD))).collect(),
            al: AP_TUNING.iter().map(|&n| Allpass::new(s(n))).collect(),
            ar: AP_TUNING.iter().map(|&n| Allpass::new(s(n + STEREO_SPREAD))).collect(),
        }
    }

    fn process(&mut self, p: &[f32; MAX_PARAMS], l: &mut [f32], r: &mut [f32]) {
        let feedback = 0.7 + p[0] * 0.28;
        let damp = p[1] * 0.4;
        let (wet, dry, width) = (p[2] * 3.0, p[3], p[4]);
        let wet1 = wet * (width / 2.0 + 0.5);
        let wet2 = wet * ((1.0 - width) / 2.0);
        for i in 0..l.len() {
            let input = (l[i] + r[i]) * 0.015;
            let (mut ol, mut or) = (0.0, 0.0);
            for c in &mut self.cl {
                ol += c.tick(input, feedback, damp);
            }
            for c in &mut self.cr {
                or += c.tick(input, feedback, damp);
            }
            for a in &mut self.al {
                ol = a.tick(ol);
            }
            for a in &mut self.ar {
                or = a.tick(or);
            }
            let (dl, dr) = (l[i], r[i]);
            l[i] = ol * wet1 + or * wet2 + dl * dry;
            r[i] = or * wet1 + ol * wet2 + dr * dry;
        }
    }
}

// ------------------------------------------------------------------ delay
pub struct Delay {
    bl: Vec<f32>,
    br: Vec<f32>,
    w: usize,
}

impl Delay {
    fn new(sr: f32) -> Self {
        // up to one bar at 40 BPM
        let n = (sr * 6.0) as usize;
        Self { bl: vec![0.0; n], br: vec![0.0; n], w: 0 }
    }

    fn process(&mut self, p: &[f32; MAX_PARAMS], l: &mut [f32], r: &mut [f32], sr: f32, tempo: f32) {
        let sixteenths = (1.0 + (p[0] * 15.0).round()).clamp(1.0, 16.0);
        let secs = sixteenths * 60.0 / tempo.max(1.0) / 4.0;
        let n = self.bl.len();
        let d = ((secs * sr) as usize).clamp(1, n - 1);
        let (fb, wet, dry, pp) = (p[1] * 0.95, p[2], p[3], p[4] > 0.5);
        for i in 0..l.len() {
            let rd = (self.w + n - d) % n;
            let (yl, yr) = (self.bl[rd], self.br[rd]);
            if pp {
                self.bl[self.w] = (l[i] + r[i]) * 0.5 + yr * fb;
                self.br[self.w] = yl * fb;
            } else {
                self.bl[self.w] = l[i] + yl * fb;
                self.br[self.w] = r[i] + yr * fb;
            }
            self.w = (self.w + 1) % n;
            l[i] = l[i] * dry + yl * wet;
            r[i] = r[i] * dry + yr * wet;
        }
    }
}

// ------------------------------------------------------------------ filter
#[derive(Default)]
pub struct Filter {
    ic1: [f32; 2],
    ic2: [f32; 2],
}

impl Filter {
    /// TPT state-variable filter (Simper), cutoff 20 Hz..20 kHz exponential.
    fn process(&mut self, p: &[f32; MAX_PARAMS], l: &mut [f32], r: &mut [f32], sr: f32) {
        let fc = (20.0 * 1000f32.powf(p[0])).min(sr * 0.45);
        let q = 0.5 + p[1] * 19.5;
        let g = (PI * fc / sr).tan();
        let k = 1.0 / q;
        let a1 = 1.0 / (1.0 + g * (g + k));
        let a2 = g * a1;
        let a3 = g * a2;
        let mode = p[2];
        let mix = p[3];
        for (c, buf) in [&mut *l, &mut *r].into_iter().enumerate() {
            for x in buf.iter_mut() {
                let v3 = *x - self.ic2[c];
                let v1 = a1 * self.ic1[c] + a2 * v3;
                let v2 = self.ic2[c] + a2 * self.ic1[c] + a3 * v3;
                self.ic1[c] = 2.0 * v1 - self.ic1[c];
                self.ic2[c] = 2.0 * v2 - self.ic2[c];
                let y = if mode < 0.33 {
                    v2
                } else if mode < 0.66 {
                    v1
                } else {
                    *x - k * v1 - v2
                };
                *x = *x * (1.0 - mix) + y * mix;
            }
        }
    }
}

// ------------------------------------------------------------------ distortion
#[derive(Default)]
pub struct Distortion {
    lp: [f32; 2],
}

impl Distortion {
    fn process(&mut self, p: &[f32; MAX_PARAMS], l: &mut [f32], r: &mut [f32], sr: f32) {
        let drive = 1.0 + p[0] * 40.0;
        let tone_hz = 800.0 * 25f32.powf(p[1]);
        let a = (-2.0 * PI * tone_hz / sr).exp();
        let (mix, out) = (p[2], p[3] * 1.4);
        let comp = 1.0 / drive.tanh();
        for (c, buf) in [&mut *l, &mut *r].into_iter().enumerate() {
            for x in buf.iter_mut() {
                let d = (*x * drive).tanh() * comp;
                self.lp[c] = d * (1.0 - a) + self.lp[c] * a;
                *x = (*x * (1.0 - mix) + self.lp[c] * mix) * out;
            }
        }
    }
}

// ------------------------------------------------------------------ compressor
#[derive(Default)]
pub struct Compressor {
    env: f32,
    /// Last gain reduction in dB (for the UI some day).
    pub gr_db: f32,
}

impl Compressor {
    fn process(&mut self, p: &[f32; MAX_PARAMS], l: &mut [f32], r: &mut [f32], sr: f32) {
        let thr_db = -40.0 + p[0] * 40.0;
        let ratio = 1.0 + p[1] * 19.0;
        let att = (-1.0 / (sr * (0.0005 + p[2] * 0.1))).exp();
        let rel = (-1.0 / (sr * (0.02 + p[3] * 1.0))).exp();
        let makeup = 10f32.powf(p[4] * 24.0 / 20.0);
        for i in 0..l.len() {
            let x = l[i].abs().max(r[i].abs());
            let c = if x > self.env { att } else { rel };
            self.env = x + c * (self.env - x);
            let db = 20.0 * self.env.max(1e-6).log10();
            let over = db - thr_db;
            let gr = if over > 0.0 { over - over / ratio } else { 0.0 };
            self.gr_db = gr;
            let g = 10f32.powf(-gr / 20.0) * makeup;
            l[i] *= g;
            r[i] *= g;
        }
    }
}

// ------------------------------------------------------------------ slot
pub enum FxState {
    Reverb(Reverb),
    Delay(Delay),
    Filter(Filter),
    Distortion(Distortion),
    Compressor(Compressor),
}

pub struct Effect {
    pub kind: FxKind,
    pub params: [f32; MAX_PARAMS],
    pub bypass: bool,
    state: FxState,
}

impl Effect {
    /// Allocates (UI thread only).
    pub fn new(kind: FxKind, sr: f32) -> Self {
        let state = match kind {
            FxKind::Reverb => FxState::Reverb(Reverb::new(sr)),
            FxKind::Delay => FxState::Delay(Delay::new(sr)),
            FxKind::Filter => FxState::Filter(Filter::default()),
            FxKind::Distortion => FxState::Distortion(Distortion::default()),
            FxKind::Compressor => FxState::Compressor(Compressor::default()),
        };
        Self { kind, params: kind.defaults(), bypass: false, state }
    }

    pub fn set(&mut self, idx: usize, v: f32) {
        if let Some(p) = self.params.get_mut(idx) {
            *p = if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
        }
    }

    pub fn process(&mut self, l: &mut [f32], r: &mut [f32], sr: f32, tempo: f32) {
        if self.bypass {
            return;
        }
        let p = &self.params;
        match &mut self.state {
            FxState::Reverb(s) => s.process(p, l, r),
            FxState::Delay(s) => s.process(p, l, r, sr, tempo),
            FxState::Filter(s) => s.process(p, l, r, sr),
            FxState::Distortion(s) => s.process(p, l, r, sr),
            FxState::Compressor(s) => s.process(p, l, r, sr),
        }
        // keep denormals / blow-ups out of the mix
        for x in l.iter_mut().chain(r.iter_mut()) {
            if !x.is_finite() {
                *x = 0.0;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn impulse_response(kind: FxKind, frames: usize) -> (Vec<f32>, Vec<f32>) {
        let mut e = Effect::new(kind, 48000.0);
        let mut l = vec![0f32; frames];
        let mut r = vec![0f32; frames];
        l[0] = 1.0;
        r[0] = 1.0;
        for (cl, cr) in l.chunks_mut(64).zip(r.chunks_mut(64)) {
            e.process(cl, cr, 48000.0, 120.0);
        }
        (l, r)
    }

    #[test]
    fn reverb_has_a_tail() {
        let (l, _) = impulse_response(FxKind::Reverb, 48000);
        let tail: f32 = l[10000..20000].iter().map(|x| x.abs()).sum();
        assert!(tail > 0.1, "{tail}");
        assert!(l.iter().all(|x| x.is_finite() && x.abs() < 4.0));
    }

    #[test]
    fn delay_echo_lands_on_the_grid() {
        // default time 0.125 -> 1 + round(1.875) = 3 sixteenths at 120 BPM = 0.375 s = 18000 frames
        let (l, _) = impulse_response(FxKind::Delay, 40000);
        let peak = (1..40000).max_by(|&a, &b| l[a].abs().total_cmp(&l[b].abs())).unwrap();
        assert_eq!(peak, 18000);
    }

    #[test]
    fn lowpass_kills_highs() {
        let mut e = Effect::new(FxKind::Filter, 48000.0);
        e.set(0, 0.2); // ~80 Hz
        let mut l: Vec<f32> = (0..4800).map(|i| if i % 2 == 0 { 1.0 } else { -1.0 }).collect(); // Nyquist
        let mut r = l.clone();
        e.process(&mut l, &mut r, 48000.0, 120.0);
        let rms = (l[2400..].iter().map(|x| x * x).sum::<f32>() / 2400.0).sqrt();
        assert!(rms < 0.01, "{rms}");
    }

    #[test]
    fn compressor_reduces_loud_signal() {
        let mut e = Effect::new(FxKind::Compressor, 48000.0);
        e.set(4, 0.0); // no makeup
        let mut l = vec![0.9f32; 48000];
        let mut r = l.clone();
        e.process(&mut l, &mut r, 48000.0, 120.0);
        assert!(l[47999] < 0.5, "{}", l[47999]);
    }

    #[test]
    fn distortion_stays_bounded() {
        let mut e = Effect::new(FxKind::Distortion, 48000.0);
        e.set(0, 1.0);
        let mut l: Vec<f32> = (0..4800).map(|i| (i as f32 * 0.05).sin() * 2.0).collect();
        let mut r = l.clone();
        e.process(&mut l, &mut r, 48000.0, 120.0);
        assert!(l.iter().all(|x| x.abs() <= 1.5));
    }
}
