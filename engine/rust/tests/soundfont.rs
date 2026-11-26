//! SoundFont channel plays through the engine (skipped without the .sf2,
//! fetch it with app/tool/fetch_soundfont.sh).

use std::sync::Arc;

use orchard_engine::engine::{Cmd, Engine, Note, Status};
use orchard_engine::instrument::{Instrument, SoundFontInst};
use rustysynth::SoundFont;

#[test]
fn piano_plays_and_stops() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../app/assets/GeneralUser-GS.sf2");
    let Ok(bytes) = std::fs::read(path) else {
        eprintln!("skipped: {path} missing");
        return;
    };
    let sf = Arc::new(SoundFont::new(&mut std::io::Cursor::new(bytes)).unwrap());
    let piano = sf.get_presets().iter().find(|p| p.get_bank_number() == 0 && p.get_patch_number() == 0).unwrap();
    assert!(piano.get_name().to_lowercase().contains("piano"), "{}", piano.get_name());

    let mut e = Engine::new(48000.0, Arc::new(Status::new()), None);
    let inst = SoundFontInst::new(&sf, 48000.0, 0, 0).unwrap();
    e.handle(Cmd::Instrument { ch: 0, inst: Box::new(Instrument::SoundFont(inst)) });
    e.handle(Cmd::Channel { ch: 0, vol: 0.78, pan: 0.0, pitch: 0.0, mute: false, used: true, insert: 1 });
    e.handle(Cmd::Tempo(120.0));
    let notes = vec![Note { pos: 0, len: 48, key: 60, vel: 100 }].into_boxed_slice(); // half a beat
    e.handle(Cmd::Notes { pat: 0, ch: 0, notes });
    e.handle(Cmd::Play(true));
    let mut out = vec![0f32; 48000 * 2];
    for c in out.chunks_mut(512) {
        e.process(c);
    }
    let rms = |s: &[f32]| (s.iter().map(|x| x * x).sum::<f32>() / s.len() as f32).sqrt();
    let held = rms(&out[2 * 1000..2 * 10000]);
    let after = rms(&out[2 * 40000..2 * 47000]); // released at 12000, before the loop at 96000
    assert!(held > 0.01, "held rms {held}");
    assert!(after < held * 0.05, "after release {after} vs {held}");
    // drum kit bank 128 exists
    assert!(sf.get_presets().iter().any(|p| p.get_bank_number() == 128));
}

#[test]
fn pitch_change_while_held_does_not_hang() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../app/assets/GeneralUser-GS.sf2");
    let Ok(bytes) = std::fs::read(path) else { return };
    let sf = Arc::new(SoundFont::new(&mut std::io::Cursor::new(bytes)).unwrap());
    let mut e = Engine::new(48000.0, Arc::new(Status::new()), None);
    let inst = SoundFontInst::new(&sf, 48000.0, 0, 19).unwrap(); // organ: sustains forever
    e.handle(Cmd::Instrument { ch: 0, inst: Box::new(Instrument::SoundFont(inst)) });
    e.handle(Cmd::Channel { ch: 0, vol: 1.0, pan: 0.0, pitch: 0.0, mute: false, used: true, insert: 0 });
    e.handle(Cmd::NoteOn { ch: 0, key: 60, vel: 100 });
    let mut out = vec![0f32; 2 * 4800];
    e.process(&mut out);
    e.handle(Cmd::Channel { ch: 0, vol: 1.0, pan: 0.0, pitch: 3.0, mute: false, used: true, insert: 0 });
    e.handle(Cmd::NoteOff { ch: 0, key: 60 });
    let mut out = vec![0f32; 2 * 96000];
    for c in out.chunks_mut(512) {
        e.process(c);
    }
    let tail = out[2 * 90000..].iter().fold(0f32, |m, x| m.max(x.abs()));
    assert!(tail < 1e-3, "organ still sounding: {tail}");
}
