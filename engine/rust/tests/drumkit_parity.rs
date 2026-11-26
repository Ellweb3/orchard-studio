//! The Rust starter kit must sound like the TS one (src/audio/drumkit.ts).
//! Golden files are rendered from the TS code with:
//!   node --experimental-strip-types tools/golden.mts  (see engine/README.md)

use orchard_engine::drumkit::builtin_kit;

fn load(key: &str) -> Vec<Vec<f32>> {
    let path = format!("{}/tests/golden/{key}.f32", env!("CARGO_MANIFEST_DIR"));
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let nch = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
    let data: Vec<f32> = bytes[4..].chunks(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())).collect();
    let len = data.len() / nch;
    (0..nch).map(|c| data[c * len..(c + 1) * len].to_vec()).collect()
}

#[test]
fn kit_matches_typescript() {
    let keys = ["kick", "clap", "hat", "openhat", "snare", "808", "stab"];
    for (sample, key) in builtin_kit().iter().zip(keys) {
        let golden = load(key);
        assert_eq!(sample.channels.len(), golden.len(), "{key}: channel count");
        for (c, (a, b)) in sample.channels.iter().zip(&golden).enumerate() {
            assert_eq!(a.len(), b.len(), "{key}[{c}]: length");
            let max_err = a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0f32, f32::max);
            assert!(max_err < 1e-5, "{key}[{c}]: max error {max_err}");
        }
    }
}
