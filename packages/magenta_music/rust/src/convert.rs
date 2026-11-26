//! Note <-> model encodings, ported from magenta.js core/data.ts,
//! core/melodies.ts, core/aux_inputs.ts and core/chords.ts.
//! Time is in quantized steps (4 per quarter note, Magenta's default).

/// A quantized note. Drum hits have `end = start + 1`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Note {
    pub start: u32,
    pub end: u32,
    pub pitch: u8,
}

/// magenta.js DEFAULT_DRUM_PITCH_CLASSES: kick, snare, closed hat, open hat,
/// low / mid / high tom, crash, ride. The first pitch of a class is used on output.
pub const DRUM_PITCH_CLASSES: [&[u8]; 9] = [
    &[36, 35],
    &[38, 27, 28, 31, 32, 33, 34, 37, 39, 40, 56, 65, 66, 75, 85],
    &[42, 44, 54, 68, 69, 70, 71, 73, 78, 80],
    &[46, 67, 72, 74, 79, 81],
    &[45, 29, 41, 61, 64, 84],
    &[48, 47, 60, 63, 77, 86, 87],
    &[50, 30, 43, 62, 76, 83],
    &[49, 55, 57, 58],
    &[51, 52, 53, 59, 82],
];

pub fn drum_class(pitch: u8) -> Option<usize> {
    DRUM_PITCH_CLASSES.iter().position(|c| c.contains(&pitch))
}

/// Per step label = sum of 2^class of the drums hit (DrumsOneHotConverter /
/// the DrumsConverter output labels). Unknown pitches are ignored.
pub fn drums_to_labels(notes: &[Note], steps: usize) -> Vec<usize> {
    let mut labels = vec![0usize; steps];
    for n in notes {
        if let (Some(c), Some(l)) = (drum_class(n.pitch), labels.get_mut(n.start as usize)) {
            *l |= 1 << c;
        }
    }
    labels
}

pub fn labels_to_drums(labels: &[usize], offset: u32) -> Vec<Note> {
    let mut out = Vec::new();
    for (s, &l) in labels.iter().enumerate() {
        for (c, class) in DRUM_PITCH_CLASSES.iter().enumerate() {
            if l >> c & 1 == 1 {
                let start = offset + s as u32;
                out.push(Note { start, end: start + 1, pitch: class[0] });
            }
        }
    }
    out
}

/// DrumsConverter.toTensor: [steps, 10] roll, last column = no drum (NOR),
/// as in Magenta's Python training pipeline. (magenta.js 1.23 writes the NOR
/// flag with `buffer.set(v, i, -1)`, which lands on row i-1: see
/// tests/golden.rs, which reproduces that to check the encoder.)
pub fn drums_to_roll(notes: &[Note], steps: usize) -> Vec<[f32; 10]> {
    let mut roll = vec![[0.0f32; 10]; steps];
    for r in roll.iter_mut() {
        r[9] = 1.0;
    }
    for n in notes {
        if let (Some(c), Some(r)) = (drum_class(n.pitch), roll.get_mut(n.start as usize)) {
            r[c] = 1.0;
            r[9] = 0.0;
        }
    }
    roll
}

pub const NO_EVENT: usize = 0;
pub const NOTE_OFF: usize = 1;
pub const FIRST_PITCH: usize = 2;

/// Melody.fromNoteSequence (ignorePolyphony: keep the highest note at a step).
/// Pitches outside [min, max] are moved by octaves into the range.
pub fn melody_to_events(notes: &[Note], min: u8, max: u8, steps: usize) -> Vec<usize> {
    let mut sorted: Vec<Note> = notes.to_vec();
    sorted.sort_by(|a, b| a.start.cmp(&b.start).then(b.pitch.cmp(&a.pitch)));
    let mut ev = vec![NO_EVENT; steps];
    let mut last_start: i64 = -1;
    for n in sorted {
        if n.start as i64 == last_start || n.start as usize >= steps {
            continue;
        }
        let mut p = n.pitch as i32;
        while p < min as i32 {
            p += 12;
        }
        while p > max as i32 {
            p -= 12;
        }
        if p < min as i32 {
            continue; // range narrower than an octave
        }
        ev[n.start as usize] = (p - min as i32) as usize + FIRST_PITCH;
        if (n.end as usize) < steps {
            ev[n.end as usize] = NOTE_OFF;
        }
        last_start = n.start as i64;
    }
    ev
}

/// Melody.toNoteSequence.
pub fn events_to_melody(events: &[usize], min: u8, offset: u32) -> Vec<Note> {
    let mut out = Vec::new();
    let mut cur: Option<Note> = None;
    for (s, &e) in events.iter().enumerate() {
        let s = offset + s as u32;
        match e {
            NO_EVENT => {}
            NOTE_OFF => {
                if let Some(mut n) = cur.take() {
                    n.end = s;
                    out.push(n);
                }
            }
            _ => {
                if let Some(mut n) = cur.take() {
                    n.end = s;
                    out.push(n);
                }
                cur = Some(Note { start: s, end: 0, pitch: (e - FIRST_PITCH) as u8 + min });
            }
        }
    }
    if let Some(mut n) = cur {
        n.end = offset + events.len() as u32;
        out.push(n);
    }
    out
}

/// BinaryCounter aux input: bit i of (step + 1), as +1 / -1, LSB first.
pub fn binary_counter(step: usize, bits: usize, out: &mut Vec<f32>) {
    for i in 0..bits {
        out.push(if ((step + 1) >> i) & 1 == 1 { 1.0 } else { -1.0 });
    }
}

/// Root pitch class and chord pitch classes for a chord symbol such as
/// "C", "Am", "F#m7", "Bbmaj7", "G7", "Ddim", "Esus4"; None = no chord ("N.C.").
pub fn parse_chord(sym: &str) -> Option<(u8, Vec<u8>)> {
    let s = sym.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("N.C.") || s.eq_ignore_ascii_case("NC") {
        return None;
    }
    let mut chars = s.chars();
    let letter = chars.next()?.to_ascii_uppercase();
    let mut root: i32 = match letter {
        'C' => 0,
        'D' => 2,
        'E' => 4,
        'F' => 5,
        'G' => 7,
        'A' => 9,
        'B' => 11,
        _ => return None,
    };
    let mut rest: &str = chars.as_str();
    while let Some(c) = rest.chars().next() {
        match c {
            '#' | '♯' => root += 1,
            'b' | '♭' if !rest.starts_with("b5") => root -= 1,
            _ => break,
        }
        rest = &rest[c.len_utf8()..];
    }
    let root = root.rem_euclid(12) as u8;
    let q = rest.split('/').next().unwrap_or("");
    let intervals: &[u8] = match q {
        "" | "M" | "maj" => &[0, 4, 7],
        "m" | "min" | "-" => &[0, 3, 7],
        "7" | "dom7" => &[0, 4, 7, 10],
        "maj7" | "M7" | "Δ" | "Δ7" => &[0, 4, 7, 11],
        "m7" | "min7" | "-7" => &[0, 3, 7, 10],
        "dim" | "o" | "°" => &[0, 3, 6],
        "dim7" | "o7" | "°7" => &[0, 3, 6, 9],
        "m7b5" | "ø" | "ø7" => &[0, 3, 6, 10],
        "aug" | "+" => &[0, 4, 8],
        "sus2" => &[0, 2, 7],
        "sus4" | "sus" => &[0, 5, 7],
        "6" => &[0, 4, 7, 9],
        "m6" => &[0, 3, 7, 9],
        "9" => &[0, 4, 7, 10, 2],
        "m9" => &[0, 3, 7, 10, 2],
        "add9" => &[0, 4, 7, 2],
        "5" => &[0, 7],
        _ => &[0, 4, 7],
    };
    Some((root, intervals.iter().map(|i| (root + i) % 12).collect()))
}

/// PitchChordEncoder: [no-chord flag, root one-hot (12), pitches (12), bass = root (12)].
pub fn encode_chord(chord: Option<&(u8, Vec<u8>)>, out: &mut Vec<f32>) {
    let start = out.len();
    out.resize(start + 37, 0.0);
    let v = &mut out[start..];
    match chord {
        None => v[0] = 1.0,
        Some((root, pitches)) => {
            v[1 + *root as usize] = 1.0;
            for p in pitches {
                v[13 + *p as usize] = 1.0;
            }
            v[25 + *root as usize] = 1.0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drums_roundtrip() {
        let notes = vec![
            Note { start: 0, end: 1, pitch: 36 },
            Note { start: 0, end: 1, pitch: 42 },
            Note { start: 4, end: 5, pitch: 40 }, // snare class (alt pitch)
        ];
        let labels = drums_to_labels(&notes, 8);
        assert_eq!(labels[0], 0b101);
        assert_eq!(labels[4], 0b10);
        let back = labels_to_drums(&labels, 0);
        assert_eq!(back.len(), 3);
        assert_eq!(back[2].pitch, 38);
        let roll = drums_to_roll(&notes, 8);
        assert_eq!(roll[0][0], 1.0);
        assert_eq!(roll[0][9], 0.0);
        assert_eq!(roll[1][9], 1.0);
    }

    #[test]
    fn melody_roundtrip() {
        let notes = vec![Note { start: 0, end: 2, pitch: 60 }, Note { start: 4, end: 8, pitch: 64 }];
        let ev = melody_to_events(&notes, 48, 83, 8);
        assert_eq!(ev, vec![14, 0, 1, 0, 18, 0, 0, 0]);
        assert_eq!(events_to_melody(&ev, 48, 0), notes);
        // out of range: moved by octaves
        let ev = melody_to_events(&[Note { start: 0, end: 1, pitch: 96 }], 48, 83, 2);
        assert_eq!(ev[0] - FIRST_PITCH + 48, 84 - 12);
    }

    #[test]
    fn chords_parse() {
        assert_eq!(parse_chord("C"), Some((0, vec![0, 4, 7])));
        assert_eq!(parse_chord("Am"), Some((9, vec![9, 0, 4])));
        assert_eq!(parse_chord("F#m7"), Some((6, vec![6, 9, 1, 4])));
        assert_eq!(parse_chord("Bb"), Some((10, vec![10, 2, 5])));
        assert_eq!(parse_chord("N.C."), None);
        let mut v = Vec::new();
        encode_chord(parse_chord("G").as_ref(), &mut v);
        assert_eq!(v.len(), 37);
        assert_eq!(v.iter().sum::<f32>(), 5.0);
    }

    #[test]
    fn binary_counter_matches_magenta() {
        let mut v = Vec::new();
        binary_counter(0, 3, &mut v); // step 0 -> value 1
        assert_eq!(v, vec![1.0, -1.0, -1.0]);
        v.clear();
        binary_counter(5, 3, &mut v); // value 6 = 0b110
        assert_eq!(v, vec![-1.0, 1.0, 1.0]);
    }
}
