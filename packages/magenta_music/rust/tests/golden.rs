//! Parity with the reference magenta.js 1.23.1 (tool/golden.js): argmax
//! decoding must give the same notes, and encodings the same latent z.
//! Needs the checkpoints in ../models (tool/fetch_models.sh); skipped otherwise.

use std::path::PathBuf;

use magenta_music::{MusicRnn, MusicVae, Note, nn::Rng};
use serde_json::Value;

fn models() -> Option<PathBuf> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../models");
    p.join("drum_kit_rnn/.done").exists().then_some(p)
}

fn golden() -> Value {
    let t = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/golden.json")).unwrap();
    serde_json::from_str(&t).unwrap()
}

fn notes(v: &Value) -> Vec<Note> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|n| Note { start: n[0].as_u64().unwrap() as u32, end: n[1].as_u64().unwrap() as u32, pitch: n[2].as_u64().unwrap() as u8 })
        .collect()
}

fn sorted(mut n: Vec<Note>, shift: u32) -> Vec<Note> {
    for x in n.iter_mut() {
        x.start -= shift;
        x.end -= shift;
    }
    n.sort_by_key(|x| (x.start, x.pitch));
    n
}

#[test]
fn music_rnn_matches_magenta_js() {
    let Some(m) = models() else { return };
    let g = golden();
    for name in ["drum_kit_rnn", "melody_rnn", "chord_pitches_improv"] {
        let c = &g[name];
        let mut model = MusicRnn::load(&m.join(name)).unwrap();
        let primer = notes(&c["primer"]);
        let ps = c["primer_steps"].as_u64().unwrap() as usize;
        let steps = c["steps"].as_u64().unwrap() as usize;
        let got = if name == "drum_kit_rnn" {
            model.continue_drums(&primer, ps, steps, 0.0, 1).unwrap()
        } else {
            let chords: Option<Vec<String>> =
                c["chords"].as_array().map(|a| a.iter().map(|s| s.as_str().unwrap().to_string()).collect());
            model.continue_melody(&primer, ps, steps, 0.0, chords.as_deref(), 1).unwrap()
        };
        assert_eq!(sorted(got, ps as u32), notes(&c["out"]), "{name}");
    }
}

#[test]
fn music_vae_matches_magenta_js() {
    let Some(m) = models() else { return };
    let g = golden();
    for name in ["drums_2bar_lokl_small", "mel_2bar_small"] {
        let c = &g[name];
        let mut model = MusicVae::load(&m.join(name)).unwrap();
        let z: Vec<f32> = c["decode_z"].as_array().unwrap().iter().map(|v| v.as_f64().unwrap() as f32).collect();
        let got = model.decode(&z, 0.0, &mut Rng::new(1));
        assert_eq!(sorted(got, 0), notes(&c["decoded"]), "{name} decode");

        let want: Vec<f32> = c["encode_z"].as_array().unwrap().iter().map(|v| v.as_f64().unwrap() as f32).collect();
        let input = notes(&c["encode_in"]);
        let enc = if name.starts_with("drums") { model.encode_rows(&magenta_js_drum_roll(&input, 32)) } else { model.encode(&input) };
        let err = enc.iter().zip(&want).map(|(a, b)| (a - b).abs()).fold(0f32, f32::max);
        assert!(err < 1e-4, "{name} encode max error {err}");
    }
}

/// magenta.js DrumsConverter.toTensor, bug for bug: `set(1, i, -1)` on a
/// TensorBuffer addresses flat index 10 * i - 1, i.e. the NOR column of row
/// i - 1 (row 0's write is dropped), and `set(0, step, -1)` clears row step - 1.
fn magenta_js_drum_roll(notes: &[Note], steps: usize) -> Vec<Vec<f32>> {
    let mut flat = vec![0.0f32; steps * 10];
    let mut set = |v: f32, row: usize, col: i64| {
        let idx = row as i64 * 10 + col;
        if idx >= 0 {
            flat[idx as usize] = v;
        }
    };
    for i in 0..steps {
        set(1.0, i, -1);
    }
    for n in notes {
        let c = magenta_music::convert::drum_class(n.pitch).unwrap();
        set(1.0, n.start as usize, c as i64);
        set(0.0, n.start as usize, -1);
    }
    flat.chunks(10).map(|r| r.to_vec()).collect()
}

#[test]
fn drum_encoding_uses_true_nor_column() {
    let roll = magenta_music::convert::drums_to_roll(&[Note { start: 1, end: 2, pitch: 36 }], 3);
    assert_eq!(roll.iter().map(|r| r[9]).collect::<Vec<_>>(), vec![1.0, 0.0, 1.0]);
}

#[test]
fn sampling_gives_musical_output() {
    let Some(m) = models() else { return };
    let mut vae = MusicVae::load(&m.join("drums_2bar_lokl_small")).unwrap();
    let beat = vae.sample(1.0, 42);
    assert!(beat.len() >= 8, "a 2-bar beat has hits: {}", beat.len());
    assert!(beat.iter().all(|n| n.start < 32));
    assert_ne!(vae.sample(1.0, 43), beat, "different seeds, different beats");
    assert_eq!(vae.sample(1.0, 42), beat, "same seed, same beat");

    let mut mel = MusicVae::load(&m.join("mel_2bar_small")).unwrap();
    let tune = mel.sample(0.8, 7);
    assert!(!tune.is_empty() && tune.iter().all(|n| (21..=108).contains(&n.pitch) && n.end > n.start));

    let a = mel.sample(0.5, 1);
    let mid = mel.interpolate(&a, &tune, 0.5, 0.0, 1);
    assert!(mid.iter().all(|n| n.end <= 32));
}
