//! The real-time engine: transport, patterns of notes per channel (steps are
//! zero-length notes on C5, as in src/engine/Sequencer.ts), swing, channel
//! instruments (Sampler / 3x Osc / SoundFont), channel volume + pan, master,
//! metronome.
//!
//! Real-time rules (as in flutter_audio_fx / hum_cpal): `process` never
//! allocates, frees, locks or does I/O. The UI sends `Cmd`s over a lock-free
//! rtrb queue; anything the audio thread replaces (note lists, instruments)
//! goes back to the UI thread as `Garbage` to be dropped there.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

use crate::drumkit::{self, Sample};
use crate::instrument::{Ctx, Instrument, Sampler};
use crate::laws;

pub const MAX_CH: usize = 16;
pub const MAX_PAT: usize = 8;
pub const MAX_STEPS: usize = 64;
pub const PPQ: f64 = 96.0;
pub const STEPS_PER_BEAT: f64 = 4.0;
pub const TICKS_PER_STEP: f64 = PPQ / STEPS_PER_BEAT; // 24
const BLOCK: usize = 64;
const MAX_EVENTS: usize = 1024;
const METRO_CH: u8 = u8::MAX;

/// A note in a pattern. `len == 0` is a step (one-shot; synths hold it one step).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Note {
    pub pos: u32,
    pub len: u32,
    pub key: u8,
    pub vel: u8,
}

pub enum Cmd {
    Tempo(f64),
    Swing(f32),
    Master(f32),
    Play(bool),
    Metronome(bool),
    Notes { pat: u8, ch: u8, notes: Box<[Note]> },
    Channel { ch: u8, vol: f32, pan: f32, pitch: f32, mute: bool, used: bool },
    Instrument { ch: u8, inst: Box<Instrument> },
    PatternLen { pat: u8, steps: u8 },
    SelectPattern(u8),
    NoteOn { ch: u8, key: u8, vel: u8 },
    NoteOff { ch: u8, key: u8 },
}

/// Heap data the audio thread let go of; dropped on the UI thread.
pub enum Garbage {
    Notes(#[allow(dead_code)] Box<[Note]>),
    Inst(#[allow(dead_code)] Box<Instrument>),
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

struct Channel {
    used: bool,
    vol: f64,
    pan: f64,
    pitch: f64,
    mute: bool,
    inst: Option<Box<Instrument>>,
    /// Keys started by the sequencer and not yet released (bitset).
    held: [u64; 2],
}

impl Default for Channel {
    fn default() -> Self {
        Self { used: false, vol: 100.0 / 128.0, pan: 0.0, pitch: 0.0, mute: false, inst: None, held: [0; 2] }
    }
}

#[derive(Clone, Copy, Default)]
struct Ev {
    frame: u16,
    ch: u8,
    on: bool,
    key: u8,
    vel: u8,
}

pub struct Engine {
    sr: f64,
    samples: Vec<Sample>,
    click_hi: usize,
    click_lo: usize,
    metro: Sampler,
    channels: Vec<Channel>,
    /// notes[pat][ch], sorted by pos.
    notes: Vec<Vec<Box<[Note]>>>,
    pat_len: [usize; MAX_PAT],
    pattern: usize,
    tempo: f64,
    swing: f64,
    master: f64,
    playing: bool,
    metronome: bool,
    pos: f64,
    events: Box<[Ev; MAX_EVENTS]>,
    n_events: usize,
    peaks: [f32; MAX_CH + 1],
    status: Arc<Status>,
    garbage: Option<rtrb::Producer<Garbage>>,
    buf_l: [f32; BLOCK],
    buf_r: [f32; BLOCK],
    ch_l: [f32; BLOCK],
    ch_r: [f32; BLOCK],
    scratch: [f32; 128],
}

impl Engine {
    pub fn new(sample_rate: f64, status: Arc<Status>, garbage: Option<rtrb::Producer<Garbage>>) -> Self {
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
            metro: Sampler::new(click_hi),
            channels: (0..MAX_CH).map(|_| Channel::default()).collect(),
            notes: (0..MAX_PAT).map(|_| (0..MAX_CH).map(|_| Box::<[Note]>::default()).collect()).collect(),
            pat_len: [16; MAX_PAT],
            pattern: 0,
            tempo: 130.0,
            swing: 0.0,
            master: 0.8,
            playing: false,
            metronome: false,
            pos: 0.0,
            events: Box::new([Ev::default(); MAX_EVENTS]),
            n_events: 0,
            peaks: [0.0; MAX_CH + 1],
            status,
            garbage,
            buf_l: [0.0; BLOCK],
            buf_r: [0.0; BLOCK],
            ch_l: [0.0; BLOCK],
            ch_r: [0.0; BLOCK],
            scratch: [0.0; 128],
        }
    }

    pub fn sample_rate(&self) -> f64 {
        self.sr
    }

    pub fn kit_size(&self) -> usize {
        self.click_hi
    }

    fn discard(&mut self, g: Garbage) {
        match self.garbage.as_mut() {
            Some(tx) => {
                if let Err(rtrb::PushError::Full(g)) = tx.push(g) {
                    std::mem::forget(g); // never free on the audio thread
                }
            }
            None => drop(g), // offline / tests
        }
    }

    fn release_sequenced(&mut self, ch: usize) {
        let c = &mut self.channels[ch];
        if c.held == [0; 2] {
            return;
        }
        if let Some(inst) = c.inst.as_mut() {
            let ctx = Ctx { samples: &self.samples, sr: self.sr, pitch: c.pitch };
            for k in 0..128u8 {
                if c.held[(k >> 6) as usize] & (1 << (k & 63)) != 0 {
                    inst.note_off(k, &ctx);
                }
            }
        }
        c.held = [0; 2];
    }

    fn release_all_sequenced(&mut self) {
        for ch in 0..MAX_CH {
            self.release_sequenced(ch);
        }
    }

    pub fn handle(&mut self, cmd: Cmd) {
        match cmd {
            Cmd::Tempo(t) => self.tempo = t.clamp(10.0, 522.0),
            Cmd::Swing(s) => self.swing = (s as f64).clamp(0.0, 1.0),
            Cmd::Master(m) => self.master = (m as f64).clamp(0.0, 1.0),
            Cmd::Play(p) => {
                if !p || !self.playing {
                    self.pos = 0.0;
                }
                if !p {
                    self.release_all_sequenced();
                }
                self.playing = p;
            }
            Cmd::Metronome(m) => self.metronome = m,
            Cmd::Notes { pat, ch, notes } => {
                let (p, c) = (pat as usize, ch as usize);
                if p < MAX_PAT && c < MAX_CH {
                    if p == self.pattern {
                        self.release_sequenced(c);
                    }
                    let old = std::mem::replace(&mut self.notes[p][c], notes);
                    self.discard(Garbage::Notes(old));
                } else {
                    self.discard(Garbage::Notes(notes));
                }
            }
            Cmd::Channel { ch, vol, pan, pitch, mute, used } => {
                if let Some(c) = self.channels.get_mut(ch as usize) {
                    c.used = used;
                    c.vol = vol as f64;
                    c.pan = pan as f64;
                    c.pitch = pitch as f64;
                    c.mute = mute;
                }
            }
            Cmd::Instrument { ch, inst } => {
                let ch = ch as usize;
                if ch < MAX_CH {
                    self.channels[ch].held = [0; 2];
                    if let Some(old) = self.channels[ch].inst.replace(inst) {
                        self.discard(Garbage::Inst(old));
                    }
                } else {
                    self.discard(Garbage::Inst(inst));
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
                if (p as usize) < MAX_PAT && p as usize != self.pattern {
                    self.release_all_sequenced();
                    self.pattern = p as usize;
                    self.pos %= self.pattern_ticks();
                }
            }
            Cmd::NoteOn { ch, key, vel } => self.live(ch, key, Some(vel)),
            Cmd::NoteOff { ch, key } => self.live(ch, key, None),
        }
    }

    fn live(&mut self, ch: u8, key: u8, vel: Option<u8>) {
        let Some(c) = self.channels.get_mut(ch as usize) else { return };
        if !c.used {
            return;
        }
        let ctx = Ctx { samples: &self.samples, sr: self.sr, pitch: c.pitch };
        if let Some(inst) = c.inst.as_mut() {
            match vel {
                Some(v) => inst.note_on(key.min(127), v as f64, &ctx),
                None => inst.note_off(key.min(127), &ctx),
            }
        }
    }

    fn pattern_ticks(&self) -> f64 {
        self.pat_len[self.pattern] as f64 * TICKS_PER_STEP
    }

    fn push_ev(&mut self, ev: Ev) {
        if self.n_events < MAX_EVENTS {
            self.events[self.n_events] = ev;
            self.n_events += 1;
        }
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

    /// This block's note on / off events, sorted by frame (offs first).
    fn schedule(&mut self, n: usize) {
        self.n_events = 0;
        if !self.playing {
            return;
        }
        let tpf = self.tempo * PPQ / 60.0 / self.sr;
        let span = n as f64 * tpf;
        let len_ticks = self.pattern_ticks();
        let frame_of = |d: f64| ((d / tpf) as usize).min(n - 1) as u16;

        if self.metronome {
            let mut beat = 0.0;
            while beat < len_ticks {
                let d = (beat - self.pos).rem_euclid(len_ticks);
                if d < span {
                    let key = if beat == 0.0 { 1 } else { 0 };
                    self.push_ev(Ev { frame: frame_of(d), ch: METRO_CH, on: true, key, vel: 100 });
                }
                beat += PPQ;
            }
        }

        for ch in 0..MAX_CH {
            if !self.channels[ch].used || self.channels[ch].inst.is_none() {
                continue;
            }
            let mute = self.channels[ch].mute;
            let count = self.notes[self.pattern][ch].len();
            for i in 0..count {
                let nt = self.notes[self.pattern][ch][i];
                let t0 = nt.pos as f64;
                if t0 >= len_ticks || nt.vel == 0 {
                    continue;
                }
                let on = t0 + laws::swing_offset(t0, self.swing, TICKS_PER_STEP);
                let len = if nt.len > 0 { nt.len as f64 } else { TICKS_PER_STEP };
                let off = on + len.min(len_ticks - 1.0);
                let d_off = (off - self.pos).rem_euclid(len_ticks);
                if d_off < span {
                    self.push_ev(Ev { frame: frame_of(d_off), ch: ch as u8, on: false, key: nt.key, vel: 0 });
                }
                let d_on = (on - self.pos).rem_euclid(len_ticks);
                if d_on < span && !mute {
                    self.push_ev(Ev { frame: frame_of(d_on), ch: ch as u8, on: true, key: nt.key, vel: nt.vel });
                }
            }
        }
        // insertion sort: by frame, note offs before note ons
        let ev = &mut self.events[..self.n_events];
        for i in 1..ev.len() {
            let mut j = i;
            while j > 0 && (ev[j - 1].frame, ev[j - 1].on) > (ev[j].frame, ev[j].on) {
                ev.swap(j - 1, j);
                j -= 1;
            }
        }
        self.pos = (self.pos + span) % len_ticks;
    }

    fn apply(&mut self, e: Ev) {
        if e.ch == METRO_CH {
            self.metro.sample = if e.key == 1 { self.click_hi } else { self.click_lo };
            self.metro.note_on(60, 100.0, 0.0, &self.samples, self.sr);
            return;
        }
        let c = &mut self.channels[e.ch as usize];
        let ctx = Ctx { samples: &self.samples, sr: self.sr, pitch: c.pitch };
        let Some(inst) = c.inst.as_mut() else { return };
        let bit = 1u64 << (e.key & 63);
        let word = &mut c.held[(e.key >> 6) as usize];
        if e.on {
            inst.note_on(e.key, e.vel as f64, &ctx);
            *word |= bit;
        } else if *word & bit != 0 {
            inst.note_off(e.key, &ctx);
            *word &= !bit;
        }
    }

    fn render_range(&mut self, a: usize, b: usize) {
        if a >= b {
            return;
        }
        let n = b - a;
        for ch in 0..MAX_CH {
            let c = &mut self.channels[ch];
            if !c.used {
                continue;
            }
            let Some(inst) = c.inst.as_mut() else { continue };
            let (tl, tr) = (&mut self.ch_l[..n], &mut self.ch_r[..n]);
            tl.fill(0.0);
            tr.fill(0.0);
            let ctx = Ctx { samples: &self.samples, sr: self.sr, pitch: c.pitch };
            inst.render(tl, tr, &ctx, &mut self.scratch);
            if c.mute {
                continue;
            }
            let g = laws::channel_volume_to_gain(c.vol);
            let (pl, pr) = if inst.pan_is_balance() {
                ((1.0 - c.pan).min(1.0), (1.0 + c.pan).min(1.0))
            } else {
                laws::pan_gains(c.pan)
            };
            let (gl, gr) = ((g * pl) as f32, (g * pr) as f32);
            let mut peak = self.peaks[ch];
            for i in 0..n {
                let (l, r) = (tl[i] * gl, tr[i] * gr);
                self.buf_l[a + i] += l;
                self.buf_r[a + i] += r;
                peak = peak.max(l.abs()).max(r.abs());
            }
            self.peaks[ch] = peak;
        }
        // metronome straight to the master
        let (tl, tr) = (&mut self.ch_l[..n], &mut self.ch_r[..n]);
        tl.fill(0.0);
        tr.fill(0.0);
        self.metro.render(tl, tr, &self.samples);
        for i in 0..n {
            self.buf_l[a + i] += tl[i] * 0.5;
            self.buf_r[a + i] += tr[i] * 0.5;
        }
    }

    fn render_block(&mut self, n: usize) {
        self.schedule(n);
        self.buf_l[..n].fill(0.0);
        self.buf_r[..n].fill(0.0);
        let mut cur = 0;
        for i in 0..self.n_events {
            let e = self.events[i];
            let f = e.frame as usize;
            if f > cur {
                self.render_range(cur, f);
                cur = f;
            }
            self.apply(e);
        }
        self.render_range(cur, n);

        let mg = laws::fader_to_gain(self.master) as f32;
        let mut mp = self.peaks[MAX_CH];
        for i in 0..n {
            let l = (self.buf_l[i] * mg).clamp(-1.0, 1.0);
            let r = (self.buf_r[i] * mg).clamp(-1.0, 1.0);
            self.buf_l[i] = l;
            self.buf_r[i] = r;
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
    use crate::threeosc::OscParams;

    fn engine(sr: f64) -> Engine {
        Engine::new(sr, Arc::new(Status::new()), None)
    }

    fn render(e: &mut Engine, frames: usize) -> Vec<f32> {
        let mut out = vec![0f32; frames * 2];
        // odd chunk size to exercise block splitting like a real device would
        for chunk in out.chunks_mut(2 * 441) {
            e.process(chunk);
        }
        out
    }

    /// Frames where sound starts after >= 500 silent frames.
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

    fn channel(e: &mut Engine, ch: u8, inst: Instrument, vol: f32, mute: bool) {
        e.handle(Cmd::Instrument { ch, inst: Box::new(inst) });
        e.handle(Cmd::Channel { ch, vol, pan: 0.0, pitch: 0.0, mute, used: true });
    }

    fn steps(e: &mut Engine, ch: u8, steps: &[u32]) {
        let notes: Vec<Note> = steps.iter().map(|s| Note { pos: s * 24, len: 0, key: 60, vel: 100 }).collect();
        e.handle(Cmd::Notes { pat: 0, ch, notes: notes.into_boxed_slice() });
    }

    #[test]
    fn steps_land_on_exact_frames() {
        // 120 BPM, 48 kHz: one step (1/16) = 0.125 s = 6000 frames.
        let mut e = engine(48000.0);
        channel(&mut e, 0, Instrument::Sampler(Sampler::new(0)), 0.78, false);
        e.handle(Cmd::Tempo(120.0));
        steps(&mut e, 0, &[0, 8]);
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 48000 * 2 + 10);
        assert_near(&onsets(&out), &[0, 48000, 96000]);
    }

    #[test]
    fn swing_delays_even_steps() {
        let mut e = engine(48000.0);
        channel(&mut e, 0, Instrument::Sampler(Sampler::new(2)), 1.0, false); // hat 0.11 s
        e.handle(Cmd::Tempo(60.0)); // step = 0.25 s = 12000 frames
        e.handle(Cmd::Swing(1.0));
        steps(&mut e, 0, &[0, 1]);
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 30000);
        assert_near(&onsets(&out), &[0, 18000]);
    }

    #[test]
    fn levels_follow_fl_laws() {
        // channel at 100% volume, vel 100, centre pan: peak = kick peak (0.89) * -3 dB
        let mut e = engine(44100.0);
        channel(&mut e, 0, Instrument::Sampler(Sampler::new(0)), 1.0, false);
        e.handle(Cmd::NoteOn { ch: 0, key: 60, vel: 100 });
        let out = render(&mut e, 44100);
        let peak = out.iter().fold(0f32, |m, x| m.max(x.abs()));
        let expect = 0.89 * std::f32::consts::FRAC_1_SQRT_2;
        assert!((peak - expect).abs() < 0.01, "{peak} vs {expect}");
    }

    #[test]
    fn muted_channel_is_silent_and_stop_resets() {
        let mut e = engine(48000.0);
        channel(&mut e, 0, Instrument::Sampler(Sampler::new(0)), 1.0, true);
        steps(&mut e, 0, &[0]);
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
    fn synth_note_lengths_are_sample_accurate() {
        // 3x Osc gate: a 1-beat note at 120 BPM / 48 kHz sounds 24000 frames + the 441-sample fade
        let mut e = engine(48000.0);
        channel(&mut e, 0, Instrument::osc(OscParams::default(), 48000.0), 1.0, false);
        e.handle(Cmd::Tempo(120.0));
        e.handle(Cmd::PatternLen { pat: 0, steps: 16 });
        let notes = vec![Note { pos: 0, len: 96, key: 60, vel: 100 }].into_boxed_slice();
        e.handle(Cmd::Notes { pat: 0, ch: 0, notes });
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 40000);
        let last = out.chunks(2).rposition(|f| f[0] != 0.0).unwrap();
        assert!((last as i64 - (24000 + 440)).abs() <= 2, "{last}");
    }

    #[test]
    fn stop_releases_held_synth_notes() {
        let mut e = engine(48000.0);
        channel(&mut e, 0, Instrument::osc(OscParams::default(), 48000.0), 1.0, false);
        let notes = vec![Note { pos: 0, len: 384, key: 60, vel: 100 }].into_boxed_slice();
        e.handle(Cmd::Notes { pat: 0, ch: 0, notes });
        e.handle(Cmd::Play(true));
        render(&mut e, 4800);
        e.handle(Cmd::Play(false));
        let out = render(&mut e, 2000);
        assert!(out[2 * 1000..].iter().all(|x| *x == 0.0));
    }

    #[test]
    fn voice_pool_survives_overload() {
        let mut e = engine(48000.0);
        for ch in 0..MAX_CH as u8 {
            let inst = if ch % 2 == 0 {
                Instrument::Sampler(Sampler::new(5))
            } else {
                Instrument::osc(OscParams::default(), 48000.0)
            };
            channel(&mut e, ch, inst, 1.0, false);
            let notes: Vec<Note> =
                (0..64).map(|s| Note { pos: s * 24, len: 48, key: 40 + (s % 40) as u8, vel: 128 }).collect();
            e.handle(Cmd::Notes { pat: 0, ch, notes: notes.into_boxed_slice() });
        }
        e.handle(Cmd::PatternLen { pat: 0, steps: 64 });
        e.handle(Cmd::Tempo(522.0));
        e.handle(Cmd::Play(true));
        let out = render(&mut e, 48000 * 3);
        assert!(out.iter().all(|x| x.is_finite() && x.abs() <= 1.0));
    }
}
