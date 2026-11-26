//! Offline export (FL's File > Export): renders the project with a private
//! Engine faster than real time and writes WAV (16-bit PCM, TPDF dither) or
//! MP3 (LAME via mp3lame-encoder, CBR). The song plays once, then the
//! transport stops and the tail (reverb / delay / releases) is rendered.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicU32, Ordering};

use mp3lame_encoder::{Bitrate, Builder, FlushNoGap, InterleavedPcm, Quality};

use crate::engine::{Cmd, Engine};

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Format {
    Wav = 0,
    Mp3 = 1,
}

const CHUNK: usize = 4096;

/// Ends the tail early once this many frames in a row are below -90 dBFS.
const SILENT_FRAMES_TO_STOP: usize = 4800;

struct Dither(u32);
impl Dither {
    #[inline]
    fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0 as f32 / 4_294_967_296.0
    }
    /// f32 -> i16 with triangular (TPDF) dither of +-1 LSB.
    #[inline]
    fn quantize(&mut self, x: f32) -> i16 {
        let d = self.next() - self.next();
        (x * 32767.0 + d).round().clamp(-32768.0, 32767.0) as i16
    }
}

enum Sink {
    Wav { w: BufWriter<File>, frames: u32 },
    Mp3 { w: BufWriter<File>, enc: Box<mp3lame_encoder::Encoder>, buf: Vec<u8> },
}

impl Sink {
    fn open(path: &str, format: Format, sr: u32, kbps: u32) -> Result<Self, String> {
        let file = File::create(path).map_err(|e| format!("{path}: {e}"))?;
        let mut w = BufWriter::new(file);
        match format {
            Format::Wav => {
                w.write_all(&[0u8; 44]).map_err(|e| e.to_string())?; // header patched in finish
                Ok(Sink::Wav { w, frames: 0 })
            }
            Format::Mp3 => {
                let mut b = Builder::new().ok_or("LAME init failed")?;
                b.set_num_channels(2).map_err(|e| e.to_string())?;
                b.set_sample_rate(sr).map_err(|e| e.to_string())?;
                b.set_brate(match kbps {
                    0..=128 => Bitrate::Kbps128,
                    129..=192 => Bitrate::Kbps192,
                    193..=256 => Bitrate::Kbps256,
                    _ => Bitrate::Kbps320,
                })
                .map_err(|e| e.to_string())?;
                b.set_quality(Quality::Best).map_err(|e| e.to_string())?;
                let enc = b.build().map_err(|e| e.to_string())?;
                Ok(Sink::Mp3 { w, enc: Box::new(enc), buf: Vec::with_capacity(CHUNK * 3 + 7200) })
            }
        }
    }

    fn write(&mut self, pcm: &[i16]) -> Result<(), String> {
        match self {
            Sink::Wav { w, frames } => {
                let mut bytes = [0u8; CHUNK * 4];
                for (i, s) in pcm.iter().enumerate() {
                    bytes[i * 2..i * 2 + 2].copy_from_slice(&s.to_le_bytes());
                }
                w.write_all(&bytes[..pcm.len() * 2]).map_err(|e| e.to_string())?;
                *frames += (pcm.len() / 2) as u32;
            }
            Sink::Mp3 { w, enc, buf } => {
                buf.clear();
                buf.reserve(pcm.len() * 5 / 8 + 7200);
                enc.encode_to_vec(InterleavedPcm(pcm), buf).map_err(|e| e.to_string())?;
                w.write_all(buf).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }

    fn finish(self, sr: u32) -> Result<(), String> {
        match self {
            Sink::Wav { mut w, frames } => {
                use std::io::{Seek, SeekFrom};
                let data = frames * 4;
                let mut h = Vec::with_capacity(44);
                h.extend_from_slice(b"RIFF");
                h.extend_from_slice(&(36 + data).to_le_bytes());
                h.extend_from_slice(b"WAVEfmt ");
                h.extend_from_slice(&16u32.to_le_bytes());
                h.extend_from_slice(&1u16.to_le_bytes()); // PCM
                h.extend_from_slice(&2u16.to_le_bytes());
                h.extend_from_slice(&sr.to_le_bytes());
                h.extend_from_slice(&(sr * 4).to_le_bytes());
                h.extend_from_slice(&4u16.to_le_bytes());
                h.extend_from_slice(&16u16.to_le_bytes());
                h.extend_from_slice(b"data");
                h.extend_from_slice(&data.to_le_bytes());
                w.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
                w.write_all(&h).map_err(|e| e.to_string())?;
                w.flush().map_err(|e| e.to_string())
            }
            Sink::Mp3 { mut w, mut enc, mut buf } => {
                buf.clear();
                buf.reserve(7200);
                enc.flush_to_vec::<FlushNoGap>(&mut buf).map_err(|e| e.to_string())?;
                w.write_all(&buf).map_err(|e| e.to_string())?;
                w.flush().map_err(|e| e.to_string())
            }
        }
    }
}

/// Renders `play_frames` of playback (transport already set up and started
/// by the caller) plus up to `max_tail_frames` of tail, writing `path`.
/// `progress` (0..1, f32 bits) can be polled from another thread.
pub fn render(
    engine: &mut Engine,
    play_frames: u64,
    max_tail_frames: u64,
    path: &str,
    format: Format,
    kbps: u32,
    progress: Option<&AtomicU32>,
) -> Result<(), String> {
    let sr = engine.sample_rate() as u32;
    let mut sink = Sink::open(path, format, sr, kbps)?;
    let mut f32buf = vec![0f32; CHUNK * 2];
    let mut pcm = vec![0i16; CHUNK * 2];
    let mut dither = Dither(0x9E37_79B9);
    let total = (play_frames + max_tail_frames).max(1) as f32;
    let mut done: u64 = 0;
    let mut quiet = 0usize;
    let mut stopped = false;
    loop {
        if !stopped && done >= play_frames {
            engine.handle(Cmd::Play(false));
            stopped = true;
        }
        if stopped && (done >= play_frames + max_tail_frames || quiet >= SILENT_FRAMES_TO_STOP) {
            break;
        }
        let limit = if stopped { play_frames + max_tail_frames } else { play_frames };
        let n = ((limit - done) as usize).clamp(1, CHUNK);
        let buf = &mut f32buf[..n * 2];
        engine.process(buf);
        for (o, x) in pcm[..n * 2].iter_mut().zip(buf.iter()) {
            *o = dither.quantize(*x);
        }
        if stopped {
            for f in buf.chunks(2) {
                if f[0].abs() < 3e-5 && f[1].abs() < 3e-5 {
                    quiet += 1;
                } else {
                    quiet = 0;
                }
            }
        }
        sink.write(&pcm[..n * 2])?;
        done += n as u64;
        if let Some(p) = progress {
            p.store((done as f32 / total).min(1.0).to_bits(), Ordering::Relaxed);
        }
    }
    sink.finish(sr)?;
    if let Some(p) = progress {
        p.store(1f32.to_bits(), Ordering::Relaxed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{Note, Status};
    use crate::instrument::{Instrument, Sampler};
    use std::sync::Arc;

    fn beat_engine() -> Engine {
        let mut e = Engine::new(44100.0, Arc::new(Status::new()), None);
        e.handle(Cmd::Instrument { ch: 0, inst: Box::new(Instrument::Sampler(Sampler::new(0))) });
        e.handle(Cmd::Channel { ch: 0, vol: 0.78, pan: 0.0, pitch: 0.0, mute: false, used: true, insert: 0 });
        let notes: Vec<Note> = [0u32, 4, 8, 12].iter().map(|s| Note { pos: s * 24, len: 0, key: 60, vel: 100 }).collect();
        e.handle(Cmd::Notes { pat: 0, ch: 0, notes: notes.into_boxed_slice() });
        e.handle(Cmd::Tempo(120.0));
        e.handle(Cmd::Play(true));
        e
    }

    fn tmp(name: &str) -> String {
        std::env::temp_dir().join(format!("orchard_test_{}_{name}", std::process::id())).to_string_lossy().into_owned()
    }

    #[test]
    fn wav_has_valid_header_and_length() {
        let path = tmp("a.wav");
        let mut e = beat_engine();
        let prog = AtomicU32::new(0);
        render(&mut e, 88200, 44100, &path, Format::Wav, 0, Some(&prog)).unwrap();
        let b = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(&b[0..4], b"RIFF");
        assert_eq!(&b[8..16], b"WAVEfmt ");
        assert_eq!(u32::from_le_bytes(b[24..28].try_into().unwrap()), 44100);
        let data = u32::from_le_bytes(b[40..44].try_into().unwrap()) as usize;
        assert_eq!(b.len(), 44 + data);
        let frames = data / 4;
        // 2 s of song + a kick tail (<= 1 s, ends early on silence)
        assert!((88200..=88200 + 44100).contains(&frames), "{frames}");
        assert_eq!(f32::from_bits(prog.load(Ordering::Relaxed)), 1.0);
        // the first kick is in the file
        let s0: i32 = b[44..44 + 4 * 2000].chunks(2).map(|c| i16::from_le_bytes([c[0], c[1]]).unsigned_abs() as i32).max().unwrap();
        assert!(s0 > 10000, "{s0}");
    }

    #[test]
    fn mp3_is_a_valid_stream() {
        let path = tmp("a.mp3");
        let mut e = beat_engine();
        render(&mut e, 88200, 44100, &path, Format::Mp3, 192, None).unwrap();
        let b = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).ok();
        // MPEG-1 Layer III frame sync, 192 kbps, 44.1 kHz
        let i = b.windows(2).position(|w| w[0] == 0xFF && (w[1] & 0xFE) == 0xFA).expect("frame sync");
        assert_eq!(b[i + 2] >> 4, 0b1011, "192 kbps index");
        assert_eq!((b[i + 2] >> 2) & 3, 0, "44.1 kHz");
        // ~2-3 s at 192 kbps = 48-72 KB
        assert!((40_000..90_000).contains(&b.len()), "{}", b.len());
    }
}
