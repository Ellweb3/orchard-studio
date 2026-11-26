//! The real-time engine: transport, step patterns (Channel Rack), swing,
//! sampler voices and metronome. A trimmed Rust port of src/engine/Engine.ts,
//! Sequencer.ts and Sampler.ts (one-shot sampler path) for stages 1-2.
//!
//! Real-time rules (as in flutter_audio_fx / hum_cpal): `process` never
//! allocates, locks or does I/O. The UI talks to it only through `Cmd`
//! values on a lock-free rtrb queue and reads `Status` atomics back.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

use crate::drumkit::{self, Sample};
use crate::laws;

pub const MAX_CH: usize = 16;
pub const MAX_PAT: usize = 8;
pub const MAX_STEPS: usize = 64;
pub const MAX_VOICES: usize = 64;
pub const PPQ: f64 = 96.0;
pub const STEPS_PER_BEAT: f64 = 4.0;
pub const TICKS_PER_STEP: f64 = PPQ / STEPS_PER_BEAT; // 24
const BLOCK: usize = 64;

#[derive(Clone, Copy, Debug)]
pub enum Cmd {
    Tempo(f64),
    Swing(f32),
    Master(f32),
    Play(bool),
    Metronome(bool),
    /// vel 0 = step off.
    Step { pat: u8, ch: u8, step: u8, vel: u8 },
    Channel { ch: u8, sample: u8, vol: f32, pan: f32, pitch: f32, mute: bool, used: bool },
    PatternLen { pat: u8, steps: u8 },
    SelectPattern(u8),
    Preview { ch: u8 },
    ClearPattern(u8),
}

/// Engine -> UI, read lock-free by the FFI getters.
pub struct Status {
    pub pos_ticks: AtomicU64, // f64 bits, pattern-local
    pub playing: AtomicBool,
    /// Peak |x| since last read, f32 bits (positive floats order like u32): [ch..., master].
    pub peaks: [AtomicU32; MAX_CH + 1],
    pub sample_rate: AtomicU32,
}

impl Status {
    pub fn new() -> Self {
        Self {
            pos_ticks: AtomicU64::new(0),
            playing: AtomicBool::new(false),
            peaks: std::array::from_fn(|_| AtomicU32::new(0)),
            sample_rate: AtomicU32::new(0),
        }
    }
}

impl Default for Status {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy)]
struct ChannelState {
    used: bool,
    sample: usize,
    vol: f64,
    pan: f64,
    pitch: f64,
    mute: bool,
}

impl Default for ChannelState {
    fn default() -> Self {
        Self { used: false, sample: 0, vol: 100.0 / 128.0, pan: 0.0, pitch: 0.0, mute: false }
    }
}

#[derive(Clone, Copy, Default)]
struct Voice {
    active: bool,
    /// Index into `samples` (metronome clicks live past the kit).
    sample: usize,
    /// Rack channel for metering, MAX_CH = master-only (metronome).
    ch: usize,
    pos: f64,
    inc: f64,
    gl: f32,
    gr: f32,
    /// Frames to wait inside the current block before starting.
    delay: usize,
    age: u64,
}

pub struct Engine {
    sr: f64,
    samples: Vec<Sample>,
    click_hi: usize,
    click_lo: usize,
    channels: [ChannelState; MAX_CH],
    /// steps[pat][ch][step] = velocity (0 = off).
    steps: Box<[[[u8; MAX_STEPS]; MAX_CH]; MAX_PAT]>,
    pat_len: [usize; MAX_PAT],
    pattern: usize,
    tempo: f64,
    swing: f64,
    master: f64,
    playing: bool,
    metronome: bool,
    pos: f64,
    voices: [Voice; MAX_VOICES],
    voice_counter: u64,
    peaks: [f32; MAX_CH + 1],
    status: Arc<Status>,
    buf_l: [f32; BLOCK],
    buf_r: [f32; BLOCK],
}

impl Engine {
    pub fn new(sample_rate: f64, status: Arc<Status>) -> Self {
        let mut samples = drumkit::builtin_kit();
        let (hi, lo) = drumkit::metronome_clicks();
        let click_hi = samples.len();
        samples.push(hi);
        let click_lo = samples.len();
        samples.push(lo);
        status.sample_rate.store(sample_rate as u32, Ordering::Relaxed);
        Self {
            sr: sample_rate,
            samples,
            click_hi,
            click_lo,
            channels: [ChannelState::default(); MAX_CH],
            steps: Box::new([[[0; MAX_STEPS]; MAX_CH]; MAX_PAT]),
            pat_len: [16; MAX_PAT],
            pattern: 0,
            tempo: 130.0,
            swing: 0.0,
            master: 0.8,
            playing: false,
            metronome: false,
            pos: 0.0,
            voices: [Voice::default(); MAX_VOICES],
            voice_counter: 0,
            peaks: [0.0; MAX_CH + 1],
            status,
            buf_l: [0.0; BLOCK],
            buf_r: [0.0; BLOCK],
        }
    }

    pub fn kit_size(&self) -> usize {
        self.click_hi
    }

    pub fn handle(&mut self, cmd: Cmd) {
        match cmd {
            Cmd::Tempo(t) => self.tempo = t.clamp(10.0, 522.0),
            Cmd::Swing(s) => self.swing = (s as f64).clamp(0.0, 1.0),
            Cmd::Master(m) => self.master = (m as f64).clamp(0.0, 1.0),
            Cmd::Play(p) => {
                if p && !self.playing {
                    self.pos = 0.0;
                }
                if !p {
                    self.pos = 0.0;
                }
                self.playing = p;
            }
            Cmd::Metronome(m) => self.metronome = m,
            Cmd::Step { pat, ch, step, vel } => {
                if let Some(s) = self
                    .steps
                    .get_mut(pat as usize)
                    .and_then(|p| p.get_mut(ch as usize))
                    .and_then(|c| c.get_mut(step as usize))
                {
                    *s = vel.min(128);
                }
            }
            Cmd::Channel { ch, sample, vol, pan, pitch, mute, used } => {
                if let Some(c) = self.channels.get_mut(ch as usize) {
                    *c = ChannelState {
                        used,
                        sample: (sample as usize).min(self.click_hi - 1),
                        vol: vol as f64,
                        pan: pan as f64,
                        pitch: pitch as f64,
                        mute,
                    };
                }
            }
            Cmd::PatternLen { pat, steps } => {
                if let Some(l) = self.pat_len.get_mut(pat as usize) {
                    *l = (steps as usize).clamp(1, MAX_STEPS);
                }
                if pat as usize == self.pattern {
                    self.pos %= self.pattern_ticks();
                }
            }
            Cmd::SelectPattern(p) => {
                if (p as usize) < MAX_PAT {
                    self.pattern = p as usize;
                    self.pos %= self.pattern_ticks();
                }
            }
            Cmd::Preview { ch } => {
                let ch = ch as usize;
                if ch < MAX_CH && self.channels[ch].used {
                    self.trigger_channel(ch, 100.0, 0);
                }
            }
            Cmd::ClearPattern(p) => {
                if let Some(p) = self.steps.get_mut(p as usize) {
                    *p = [[0; MAX_STEPS]; MAX_CH];
                }
            }
        }
    }

    fn pattern_ticks(&self) -> f64 {
        self.pat_len[self.pattern] as f64 * TICKS_PER_STEP
    }

    fn start_voice(&mut self, sample: usize, ch: usize, rate: f64, gl: f32, gr: f32, delay: usize) {
        // free slot, else steal the oldest
        let mut idx = 0;
        let mut oldest = u64::MAX;
        for (i, v) in self.voices.iter().enumerate() {
            if !v.active {
                idx = i;
                break;
            }
            if v.age < oldest {
                oldest = v.age;
                idx = i;
            }
        }
        self.voice_counter += 1;
        let s = &self.samples[sample];
        self.voices[idx] = Voice {
            active: true,
            sample,
            ch,
            pos: 0.0,
            inc: s.sample_rate / self.sr * rate,
            gl,
            gr,
            delay,
            age: self.voice_counter,
        };
    }

    fn trigger_channel(&mut self, ch: usize, vel: f64, delay: usize) {
        let c = self.channels[ch];
        let g = laws::channel_volume_to_gain(c.vol) * laws::velocity_to_gain(vel);
        let (pl, pr) = laws::pan_gains(c.pan);
        let rate = 2f64.powf(c.pitch / 12.0);
        self.start_voice(c.sample, ch, rate, (g * pl) as f32, (g * pr) as f32, delay);
    }

    /// Render interleaved stereo into `out` (len = frames * 2).
    pub fn process(&mut self, out: &mut [f32]) {
        let frames = out.len() / 2;
        let mut done = 0;
        while done < frames {
            let n = (frames - done).min(BLOCK);
            self.render_block(n);
            for i in 0..n {
                out[(done + i) * 2] = self.buf_l[i];
                out[(done + i) * 2 + 1] = self.buf_r[i];
            }
            done += n;
        }
        self.publish();
    }

    fn schedule(&mut self, n: usize) {
        if !self.playing {
            return;
        }
        let tpf = self.tempo * PPQ / 60.0 / self.sr; // ticks per frame
        let span = n as f64 * tpf;
        let len_ticks = self.pattern_ticks();
        let len_steps = self.pat_len[self.pattern];
        let pat = self.pattern;

        if self.metronome {
            let mut beat_tick = 0.0;
            while beat_tick < len_ticks {
                let d = (beat_tick - self.pos).rem_euclid(len_ticks);
                if d < span {
                    let frame = ((d / tpf) as usize).min(n - 1);
                    let s = if beat_tick == 0.0 { self.click_hi } else { self.click_lo };
                    self.start_voice(s, MAX_CH, 1.0, 0.5, 0.5, frame);
                }
                beat_tick += PPQ;
            }
        }

        for ch in 0..MAX_CH {
            let c = self.channels[ch];
            if !c.used || c.mute {
                continue;
            }
            for step in 0..len_steps {
                let vel = self.steps[pat][ch][step];
                if vel == 0 {
                    continue;
                }
                let t0 = step as f64 * TICKS_PER_STEP;
                let t = t0 + laws::swing_offset(t0, self.swing, TICKS_PER_STEP);
                let d = (t - self.pos).rem_euclid(len_ticks);
                if d < span {
                    let frame = ((d / tpf) as usize).min(n - 1);
                    self.trigger_channel(ch, vel as f64, frame);
                }
            }
        }
        self.pos = (self.pos + span) % len_ticks;
    }

    fn render_block(&mut self, n: usize) {
        self.schedule(n);
        let bl = &mut self.buf_l[..n];
        let br = &mut self.buf_r[..n];
        bl.fill(0.0);
        br.fill(0.0);
        for v in self.voices.iter_mut() {
            if !v.active {
                continue;
            }
            let s = &self.samples[v.sample];
            let len = s.len();
            let left = &s.channels[0];
            let right = s.channels.get(1).unwrap_or(left);
            let mut peak = 0f32;
            let start = v.delay.min(n);
            v.delay = 0;
            for i in start..n {
                let ip = v.pos as usize;
                if ip + 1 >= len {
                    v.active = false;
                    break;
                }
                let fr = (v.pos - ip as f64) as f32;
                let l = left[ip] + (left[ip + 1] - left[ip]) * fr;
                let r = right[ip] + (right[ip + 1] - right[ip]) * fr;
                let (ol, or) = (l * v.gl, r * v.gr);
                bl[i] += ol;
                br[i] += or;
                peak = peak.max(ol.abs()).max(or.abs());
                v.pos += v.inc;
            }
            if v.ch < MAX_CH {
                self.peaks[v.ch] = self.peaks[v.ch].max(peak);
            }
        }
        let mg = laws::fader_to_gain(self.master) as f32;
        let mut mp = self.peaks[MAX_CH];
        for i in 0..n {
            let l = (bl[i] * mg).clamp(-1.0, 1.0);
            let r = (br[i] * mg).clamp(-1.0, 1.0);
            bl[i] = l;
            br[i] = r;
            mp = mp.max(l.abs()).max(r.abs());
        }
        self.peaks[MAX_CH] = mp;
    }

    fn publish(&mut self) {
        let st = &self.status;
        st.pos_ticks.store(self.pos.to_bits(), Ordering::Relaxed);
        st.playing.store(self.playing, Ordering::Relaxed);
        for (i, p) in self.peaks.iter_mut().enumerate() {
            st.peaks[i].fetch_max(p.to_bits(), Ordering::Relaxed);
            *p = 0.0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(sr: f64) -> Engine {
        Engine::new(sr, Arc::new(Status::new()))
    }

    fn render(e: &mut Engine, frames: usize) -> Vec<f32> {
        let mut out = vec![0f32; frames * 2];
        // odd chunk size to exercise block splitting like a real device would
        for chunk in out.chunks_mut(2 * 441) {
            e.process(chunk);
        }
        out
    }

    /// Frames where sound starts after >= 500 silent frames. Several kit
    /// sounds start with an exact 0 (envelope attack), so the first non-zero
    /// frame is the trigger frame + 1: normalise by snapping down to it.
    fn onsets(out: &[f32]) -> Vec<usize> {
        let mut v = vec![];
        let mut quiet = usize::MAX / 2;
        for (i, f) in out.chunks(2).enumerate() {
            if f[0] != 0.0 || f[1] != 0.0 {
                if quiet >= 500 {
                    v.push(i);
                }
                quiet = 0;
            } else {
                quiet += 1;
            }
        }
        v
    }

    fn assert_near(got: &[usize], want: &[usize]) {
        assert!(got.len() >= want.len(), "{got:?} vs {want:?}");
        for (g, w) in got.iter().zip(want) {
            assert!(g.abs_diff(*w) <= 1, "{got:?} vs {want:?}");
        }
    }

    fn kick_channel(e: &mut Engine) {
        e.handle(Cmd::Channel { ch: 0, sample: 0, vol: 100.0 / 128.0, pan: 0.0, pitch: 0.0, mute: false, used: true });
    }

    #[test]
    fn steps_land_on_exact_frames() {
        // 120 BPM, 48 kHz: one step (1/16) = 0.125 s = 6000 frames.
        let mut e = engine(48000.0);
        kick_channel(&mut e);
        e.handle(Cmd::Tempo(120.0));
        e.handle(Cmd::Step { pat: 0, ch: 0, step: 0, vel: 100 });
        e.handle(Cmd::Step { pat: 0, ch: 0, step: 8, vel: 100 });
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 48000 * 2 + 10); // 2 s = one bar at 120 BPM
        assert_near(&onsets(&out), &[0, 48000, 96000]);
    }

    #[test]
    fn swing_delays_even_steps() {
        let mut e = engine(48000.0);
        e.handle(Cmd::Channel { ch: 0, sample: 2, vol: 1.0, pan: 0.0, pitch: 0.0, mute: false, used: true }); // hat 0.11 s
        e.handle(Cmd::Tempo(60.0)); // step = 0.25 s = 12000 frames
        e.handle(Cmd::Swing(1.0)); // even step moves half a step
        e.handle(Cmd::Step { pat: 0, ch: 0, step: 0, vel: 100 });
        e.handle(Cmd::Step { pat: 0, ch: 0, step: 1, vel: 100 });
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 30000);
        assert_near(&onsets(&out), &[0, 18000]);
    }

    #[test]
    fn levels_follow_fl_laws() {
        // channel at 100% volume, vel 100, centre pan: peak = kick peak (0.89) * -3 dB
        let mut e = engine(44100.0);
        e.handle(Cmd::Channel { ch: 0, sample: 0, vol: 1.0, pan: 0.0, pitch: 0.0, mute: false, used: true });
        e.handle(Cmd::Preview { ch: 0 });
        let out = render(&mut e, 44100);
        let peak = out.iter().fold(0f32, |m, x| m.max(x.abs()));
        let expect = 0.89 * std::f32::consts::FRAC_1_SQRT_2;
        assert!((peak - expect).abs() < 0.01, "{peak} vs {expect}");
    }

    #[test]
    fn muted_channel_is_silent_and_stop_resets() {
        let mut e = engine(48000.0);
        e.handle(Cmd::Channel { ch: 0, sample: 0, vol: 1.0, pan: 0.0, pitch: 0.0, mute: true, used: true });
        e.handle(Cmd::Step { pat: 0, ch: 0, step: 0, vel: 100 });
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 10000);
        assert!(out.iter().all(|x| *x == 0.0));
        e.handle(Cmd::Play(false));
        assert_eq!(e.pos, 0.0);
    }

    #[test]
    fn metronome_clicks_every_beat() {
        let mut e = engine(48000.0);
        e.handle(Cmd::Tempo(120.0)); // beat = 24000 frames
        e.handle(Cmd::Metronome(true));
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 72100);
        assert_near(&onsets(&out), &[0, 24000, 48000, 72000]);
    }

    #[test]
    fn voice_pool_survives_overload() {
        let mut e = engine(48000.0);
        for ch in 0..MAX_CH as u8 {
            e.handle(Cmd::Channel { ch, sample: 5, vol: 1.0, pan: 0.0, pitch: 0.0, mute: false, used: true });
            for st in 0..64 {
                e.handle(Cmd::Step { pat: 0, ch, step: st, vel: 128 });
            }
        }
        e.handle(Cmd::PatternLen { pat: 0, steps: 64 });
        e.handle(Cmd::Tempo(522.0));
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 48000 * 3);
        assert!(out.iter().all(|x| x.is_finite() && x.abs() <= 1.0));
    }
}
