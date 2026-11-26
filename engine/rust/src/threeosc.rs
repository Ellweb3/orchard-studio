//! 3x Osc, ported from src/engine/gen/plugins/3xosc.ts (non-HQ path):
//! FL's host wavetables read at phase >> 18 with a 32-bit phase, speed =
//! round(2^32 x 523.2511 / rate x 2^(cents / 1200)), FL's mix level law
//! (l3 = mix3/128, l2 = (1 - l3) mix2/128, l1 = (1 - l3) - l2) and the
//! 441-sample cosine release fade. Stereo detune / phase offset / AM / HQ are
//! not ported yet. An optional ADSR stands in for the channel's INS envelope.

use std::sync::OnceLock;

pub const WAVE_SIZE: usize = 16384;
const FADE_LEN: usize = 441;
const C5_HZ: f64 = 523.2511;
const MAX_VOICES: usize = 16;

/// [sine, triangle, square, saw, rounded ("analog") saw]; shape 5 = noise.
fn tables() -> &'static [Vec<f32>; 5] {
    static T: OnceLock<[Vec<f32>; 5]> = OnceLock::new();
    T.get_or_init(|| {
        let n = WAVE_SIZE;
        let inv = 6.103515625e-05f64;
        let mut w: [Vec<f32>; 5] = std::array::from_fn(|_| vec![0f32; n]);
        for i in 0..n {
            w[0][i] = (((i * 2) as f64) * std::f64::consts::PI * inv).sin() as f32;
        }
        for i in 0..n / 2 {
            w[1][(i + 12288) % n] = (-1.0 + (i * 4) as f64 * inv) as f32;
        }
        for i in n / 2..n {
            w[1][(i + 12288) % n] = (1.0 - ((i - n / 2) * 4) as f64 * inv) as f32;
        }
        for i in 0..n {
            w[2][i] = if i < n / 2 { 1.0 } else { -1.0 };
            w[3][i] = (-1.0 + (i * 2) as f64 * inv) as f32;
        }
        let mut s2: f32 = 32767.0;
        for i in 0..7600 {
            let s0 = 32767.0f32 - s2 * 2.0;
            let v = (s0 as i64) as i16; // (int16)(int64)s0
            w[4][i] = (v as f64 / 32767.0) as f32;
            s2 *= 0.997;
        }
        for v in &mut w[4][7600..13653] {
            *v = 1.0;
        }
        for v in &mut w[4][13653..] {
            *v = -1.0;
        }
        w
    })
}

fn fade(q: usize) -> f32 {
    (0.5 * (1.0 + (std::f64::consts::PI * (q + 1) as f64 / FADE_LEN as f64).cos())) as f32
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscParams {
    /// 0 sine, 1 triangle, 2 square, 3 saw, 4 rounded saw, 5 noise.
    pub shape: [u8; 3],
    pub coarse: [i8; 3],
    pub fine: [i8; 3],
    pub pan: [i8; 3],
    /// Mix levels of oscillators 2 and 3 (0..128).
    pub mix2: u8,
    pub mix3: u8,
    /// Envelope on: ADSR (seconds / level), else FL's gate + release fade.
    pub env: bool,
    pub attack: f32,
    pub decay: f32,
    pub sustain: f32,
    pub release: f32,
}

impl Default for OscParams {
    /// FL's fresh 3x Osc: sines at 0 / -12 / -24, mix 2 = 64, mix 3 = 32.
    fn default() -> Self {
        Self {
            shape: [0, 0, 0],
            coarse: [0, -12, -24],
            fine: [0, 0, 0],
            pan: [0, 0, 0],
            mix2: 64,
            mix3: 32,
            env: false,
            attack: 0.0,
            decay: 0.0,
            sustain: 1.0,
            release: 0.0,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Stage {
    Off,
    Attack,
    Decay,
    Sustain,
    Release,
    /// FL gate mode: release fade position.
    Fade(usize),
}

#[derive(Clone, Copy)]
struct Voice {
    key: u8,
    stage: Stage,
    env: f32,
    ph: [u32; 3],
    sp: [u32; 3],
    vel: f32,
    noise: u32,
    age: u64,
}

impl Default for Voice {
    fn default() -> Self {
        Self { key: 0, stage: Stage::Off, env: 0.0, ph: [0; 3], sp: [0; 3], vel: 0.0, noise: 1, age: 0 }
    }
}

pub struct ThreeOsc {
    p: OscParams,
    sr: f64,
    e8: f64,
    lv: [f32; 3],
    gl: [f32; 3],
    gr: [f32; 3],
    voices: [Voice; MAX_VOICES],
    counter: u64,
    seed: u32,
}

impl ThreeOsc {
    pub fn new(p: OscParams, sr: f64) -> Self {
        let _ = tables();
        let l3 = p.mix3.min(128) as f32 * 0.0078125;
        let s0 = 1.0 - l3;
        let l2 = s0 * p.mix2.min(128) as f32 * 0.0078125;
        let l1 = s0 - l2;
        let lv = [l1, l2, l3];
        let mut gl = [0f32; 3];
        let mut gr = [0f32; 3];
        for i in 0..3 {
            // per-oscillator pan, normalised so the centre is unity (the channel applies FL's law)
            let pan = (p.pan[i] as f32 / 64.0).clamp(-1.0, 1.0);
            gl[i] = lv[i] * (1.0 - pan).min(1.0);
            gr[i] = lv[i] * (1.0 + pan).min(1.0);
        }
        Self {
            p,
            sr,
            e8: 4_294_967_296.0 * C5_HZ / sr,
            lv,
            gl,
            gr,
            voices: [Voice::default(); MAX_VOICES],
            counter: 0,
            seed: 0x1234_5678,
        }
    }

    pub fn params(&self) -> &OscParams {
        &self.p
    }

    fn speed(&self, cents: f64) -> u32 {
        let v = self.e8 * (cents * std::f64::consts::LN_2 / 1200.0).exp();
        if v >= 4_294_967_295.0 { u32::MAX } else { v.round() as u32 }
    }

    /// `key` 60 = C5 = 523.25 Hz (FL); `pitch` in semitones (channel pitch).
    pub fn note_on(&mut self, key: u8, vel_gain: f32, pitch: f64) {
        let mut idx = 0;
        let mut oldest = u64::MAX;
        for (i, v) in self.voices.iter().enumerate() {
            if v.stage == Stage::Off {
                idx = i;
                break;
            }
            if v.age < oldest {
                oldest = v.age;
                idx = i;
            }
        }
        self.counter += 1;
        self.seed = self.seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        let base = (key as f64 - 60.0 + pitch) * 100.0;
        let mut sp = [0u32; 3];
        for (i, s) in sp.iter_mut().enumerate() {
            *s = self.speed(base + self.p.coarse[i] as f64 * 100.0 + self.p.fine[i] as f64);
        }
        self.voices[idx] = Voice {
            key,
            stage: if self.p.env { Stage::Attack } else { Stage::Sustain },
            env: if self.p.env { 0.0 } else { 1.0 },
            ph: [0; 3],
            sp,
            vel: vel_gain,
            noise: self.seed | 1,
            age: self.counter,
        };
    }

    pub fn note_off(&mut self, key: u8) {
        let env = self.p.env;
        for v in self.voices.iter_mut() {
            if v.key == key && matches!(v.stage, Stage::Attack | Stage::Decay | Stage::Sustain) {
                v.stage = if env { Stage::Release } else { Stage::Fade(0) };
            }
        }
    }

    pub fn all_off(&mut self) {
        for v in self.voices.iter_mut() {
            if matches!(v.stage, Stage::Attack | Stage::Decay | Stage::Sustain) {
                v.stage = if self.p.env { Stage::Release } else { Stage::Fade(0) };
            }
        }
    }

    pub fn active(&self) -> bool {
        self.voices.iter().any(|v| v.stage != Stage::Off)
    }

    /// Adds into l / r.
    pub fn render(&mut self, l: &mut [f32], r: &mut [f32]) {
        let t = tables();
        let p = self.p;
        let sr = self.sr as f32;
        let a_step = if p.attack > 0.0 { 1.0 / (p.attack * sr) } else { 1.0 };
        let d_step = if p.decay > 0.0 { (1.0 - p.sustain) / (p.decay * sr) } else { 1.0 };
        let r_time = p.release.max(0.002) * sr;
        for v in self.voices.iter_mut() {
            if v.stage == Stage::Off {
                continue;
            }
            let r_step = (v.env.max(0.001)) / r_time;
            for i in 0..l.len() {
                // envelope
                let g = match v.stage {
                    Stage::Attack => {
                        v.env += a_step;
                        if v.env >= 1.0 {
                            v.env = 1.0;
                            v.stage = Stage::Decay;
                        }
                        v.env
                    }
                    Stage::Decay => {
                        v.env -= d_step;
                        if v.env <= p.sustain {
                            v.env = p.sustain;
                            v.stage = Stage::Sustain;
                        }
                        v.env
                    }
                    Stage::Sustain => v.env,
                    Stage::Release => {
                        v.env -= r_step;
                        if v.env <= 0.0 {
                            v.stage = Stage::Off;
                            break;
                        }
                        v.env
                    }
                    Stage::Fade(q) => {
                        if q >= FADE_LEN {
                            v.stage = Stage::Off;
                            break;
                        }
                        v.stage = Stage::Fade(q + 1);
                        fade(q)
                    }
                    Stage::Off => break,
                };
                let (mut sl, mut sr_) = (0f32, 0f32);
                for o in 0..3 {
                    if self.lv[o] == 0.0 {
                        v.ph[o] = v.ph[o].wrapping_add(v.sp[o]);
                        continue;
                    }
                    let s = match p.shape[o] {
                        5 => {
                            v.noise ^= v.noise << 13;
                            v.noise ^= v.noise >> 17;
                            v.noise ^= v.noise << 5;
                            v.noise as f32 / 2_147_483_648.0 - 1.0
                        }
                        sh => t[(sh as usize).min(4)][(v.ph[o] >> 18) as usize],
                    };
                    v.ph[o] = v.ph[o].wrapping_add(v.sp[o]);
                    sl += s * self.gl[o];
                    sr_ += s * self.gr[o];
                }
                let k = g * v.vel;
                l[i] += sl * k;
                r[i] += sr_ * k;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c5_is_523_hz() {
        let mut o = ThreeOsc::new(OscParams { mix2: 0, mix3: 0, ..Default::default() }, 48000.0);
        o.note_on(60, 1.0, 0.0);
        let mut l = vec![0f32; 48000];
        let mut r = vec![0f32; 48000];
        o.render(&mut l, &mut r);
        let crossings = l.windows(2).filter(|w| w[0] <= 0.0 && w[1] > 0.0).count();
        assert!((crossings as i64 - 523).abs() <= 1, "{crossings}");
    }

    #[test]
    fn fl_mix_levels() {
        let o = ThreeOsc::new(OscParams::default(), 48000.0);
        // mix3 32 -> l3 .25, l2 = .75 * .5 = .375, l1 = .375
        assert_eq!(o.lv, [0.375, 0.375, 0.25]);
    }

    #[test]
    fn gate_release_fades_in_441_samples() {
        let mut o = ThreeOsc::new(OscParams::default(), 44100.0);
        o.note_on(60, 1.0, 0.0);
        let mut l = vec![0f32; 1000];
        let mut r = vec![0f32; 1000];
        o.render(&mut l, &mut r);
        o.note_off(60);
        let mut l = vec![0f32; 500];
        let mut r = vec![0f32; 500];
        o.render(&mut l, &mut r);
        assert!(l[440..].iter().all(|x| *x == 0.0));
        assert!(!o.active());
    }
}
