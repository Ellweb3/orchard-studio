//! Channel instruments: Sampler (one-shot, like the TS sampler with the volume
//! envelope off), 3x Osc and SoundFont (rustysynth, the FL "Fruity Soundfont
//! Player" role). Instruments render raw (velocity included); the channel
//! applies its volume knob and pan.

use std::sync::Arc;

use rustysynth::{SoundFont, Synthesizer, SynthesizerSettings};

use crate::drumkit::Sample;
use crate::laws;
use crate::threeosc::{OscParams, ThreeOsc};

const SAMPLER_VOICES: usize = 24;

#[derive(Clone, Copy, Default)]
struct SVoice {
    active: bool,
    sample: usize,
    pos: f64,
    inc: f64,
    gain: f32,
    age: u64,
}

pub struct Sampler {
    pub sample: usize,
    voices: [SVoice; SAMPLER_VOICES],
    counter: u64,
}

impl Sampler {
    pub fn new(sample: usize) -> Self {
        Self { sample, voices: [SVoice::default(); SAMPLER_VOICES], counter: 0 }
    }

    /// Root key C5 (60): other keys transpose the sample.
    pub(crate) fn note_on(&mut self, key: u8, vel: f64, pitch: f64, samples: &[Sample], sr: f64) {
        let s = &samples[self.sample];
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
        self.counter += 1;
        let rate = 2f64.powf((key as f64 - 60.0 + pitch) / 12.0);
        self.voices[idx] = SVoice {
            active: true,
            sample: self.sample,
            pos: 0.0,
            inc: s.sample_rate / sr * rate,
            gain: laws::velocity_to_gain(vel) as f32,
            age: self.counter,
        };
    }

    pub(crate) fn render(&mut self, l: &mut [f32], r: &mut [f32], samples: &[Sample]) {
        for v in self.voices.iter_mut().filter(|v| v.active) {
            let s = &samples[v.sample];
            let len = s.len();
            let left = &s.channels[0];
            let right = s.channels.get(1).unwrap_or(left);
            for i in 0..l.len() {
                let ip = v.pos as usize;
                if ip + 1 >= len {
                    v.active = false;
                    break;
                }
                let fr = (v.pos - ip as f64) as f32;
                l[i] += (left[ip] + (left[ip + 1] - left[ip]) * fr) * v.gain;
                r[i] += (right[ip] + (right[ip + 1] - right[ip]) * fr) * v.gain;
                v.pos += v.inc;
            }
        }
    }
}

pub struct SoundFontInst {
    synth: Synthesizer,
    midi_ch: i32,
    pub bank: u16,
    pub program: u8,
    /// MIDI key each pattern key was started on (+1, 0 = none): note offs
    /// must hit the same key even if the channel pitch moved meanwhile.
    sounding: [u8; 128],
}

impl SoundFontInst {
    /// Bank 128 = drum kits (played on MIDI channel 10).
    pub fn new(sf: &Arc<SoundFont>, sr: f64, bank: u16, program: u8) -> Result<Self, String> {
        let mut settings = SynthesizerSettings::new(sr as i32);
        settings.enable_reverb_and_chorus = false; // one synth per channel: keep it light
        settings.maximum_polyphony = 48;
        let mut synth = Synthesizer::new(sf, &settings).map_err(|e| format!("{e:?}"))?;
        let midi_ch = if bank >= 128 { 9 } else { 0 };
        if bank < 128 {
            synth.process_midi_message(midi_ch, 0xB0, 0x00, bank as i32);
        }
        synth.process_midi_message(midi_ch, 0xC0, program as i32, 0);
        Ok(Self { synth, midi_ch, bank, program, sounding: [0; 128] })
    }
}

pub enum Instrument {
    Sampler(Sampler),
    Osc(ThreeOsc),
    SoundFont(SoundFontInst),
}

/// What the instrument needs from the engine while playing.
pub struct Ctx<'a> {
    pub samples: &'a [Sample],
    pub sr: f64,
    pub pitch: f64,
}

impl Instrument {
    pub fn osc(p: OscParams, sr: f64) -> Self {
        Instrument::Osc(ThreeOsc::new(p, sr))
    }

    /// `vel` 0..128 (100 = unity, FL).
    pub fn note_on(&mut self, key: u8, vel: f64, ctx: &Ctx) {
        match self {
            Instrument::Sampler(s) => s.note_on(key, vel, ctx.pitch, ctx.samples, ctx.sr),
            Instrument::Osc(o) => o.note_on(key, laws::velocity_to_gain(vel) as f32, ctx.pitch),
            Instrument::SoundFont(s) => {
                let k = (key as f64 + ctx.pitch.round()).clamp(0.0, 127.0) as i32;
                let v = ((vel * 127.0 / 128.0).round() as i32).clamp(1, 127);
                let slot = &mut s.sounding[(key & 127) as usize];
                if *slot != 0 && *slot as i32 - 1 != k {
                    s.synth.note_off(s.midi_ch, *slot as i32 - 1);
                }
                *slot = k as u8 + 1;
                s.synth.note_on(s.midi_ch, k, v);
            }
        }
    }

    pub fn note_off(&mut self, key: u8, ctx: &Ctx) {
        match self {
            Instrument::Sampler(_) => {} // one-shot: plays to the end
            Instrument::Osc(o) => o.note_off(key),
            Instrument::SoundFont(s) => {
                let _ = ctx;
                let slot = &mut s.sounding[(key & 127) as usize];
                if *slot != 0 {
                    s.synth.note_off(s.midi_ch, *slot as i32 - 1);
                    *slot = 0;
                }
            }
        }
    }

    pub fn all_off(&mut self) {
        match self {
            Instrument::Sampler(_) => {}
            Instrument::Osc(o) => o.all_off(),
            Instrument::SoundFont(s) => {
                s.synth.note_off_all(false);
                s.sounding = [0; 128];
            }
        }
    }

    /// Adds into l / r (same length, <= 64 frames).
    pub fn render(&mut self, l: &mut [f32], r: &mut [f32], ctx: &Ctx, scratch: &mut [f32; 128]) {
        match self {
            Instrument::Sampler(s) => s.render(l, r, ctx.samples),
            Instrument::Osc(o) => o.render(l, r),
            Instrument::SoundFont(s) => {
                let n = l.len();
                let (sl, sr) = scratch.split_at_mut(64);
                let (sl, sr) = (&mut sl[..n], &mut sr[..n]);
                s.synth.render(sl, sr);
                for i in 0..n {
                    l[i] += sl[i];
                    r[i] += sr[i];
                }
            }
        }
    }

    /// SoundFont output is already panned by the synth: the channel pan is a
    /// balance (centre = unity) instead of FL's -3 dB law.
    pub fn pan_is_balance(&self) -> bool {
        matches!(self, Instrument::SoundFont(_))
    }
}
