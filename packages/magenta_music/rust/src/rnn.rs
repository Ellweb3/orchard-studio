//! MusicRNN (DrumsRNN, MelodyRNN, ImprovRNN), ported from magenta.js
//! music_rnn/model.ts and music_rnn/attention.ts.

use std::path::Path;

use serde_json::Value;

use crate::convert::{self, Note};
use crate::nn::{self, Lstm, MultiLstm, Rng};
use crate::weights::{self, Tensor, Vars};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Encoding {
    /// DrumsOneHotConverter: 2^9 drum combinations.
    Drums,
    /// MelodyConverter: no event, note off, pitches min..=max.
    Melody { min: u8, max: u8 },
}

impl Encoding {
    pub fn depth(&self) -> usize {
        match *self {
            Encoding::Drums => 1 << 9,
            Encoding::Melody { min, max } => (max - min) as usize + 1 + convert::FIRST_PITCH,
        }
    }

    pub fn from_config(dc: &Value) -> Result<Self, String> {
        match dc["type"].as_str() {
            Some("DrumsOneHotConverter") => Ok(Encoding::Drums),
            Some("MelodyConverter") => Ok(Encoding::Melody {
                min: dc["args"]["minPitch"].as_u64().ok_or("minPitch")? as u8,
                max: dc["args"]["maxPitch"].as_u64().ok_or("maxPitch")? as u8,
            }),
            other => Err(format!("unsupported data converter {other:?}")),
        }
    }
}

/// tf.contrib.rnn.AttentionCellWrapper as implemented in attention.ts
/// (the query concatenates c and h of every layer; output uses the last h).
struct Attention {
    input_kernel: Tensor,
    input_bias: Tensor,
    w: Tensor, // [1,1,size,size] 1x1 conv = [size, size] matrix
    v: Tensor,
    kernel: Tensor,
    bias: Tensor,
    out_kernel: Tensor,
    out_bias: Tensor,
    length: usize,
    size: usize,
}

struct AttnState {
    attention: Vec<f32>,
    /// `length` rows of `size` (oldest first).
    states: Vec<f32>,
}

pub struct MusicRnn {
    pub encoding: Encoding,
    cells: MultiLstm,
    fc_w: Tensor,
    fc_b: Tensor,
    attention: Option<Attention>,
    aux_bits: usize,
    chords: bool,
}

const CELL_FORMAT: &str = "multi_rnn_cell/cell_%d/basic_lstm_cell/";
const ATTN: &str = "rnn/attention_cell_wrapper/";

impl MusicRnn {
    pub fn load(dir: &Path) -> Result<Self, String> {
        let cfg = weights::read_config(dir)?;
        if cfg["type"].as_str() != Some("MusicRNN") {
            return Err(format!("not a MusicRNN model: {:?}", cfg["type"]));
        }
        let encoding = Encoding::from_config(&cfg["dataConverter"])?;
        let mut vars = weights::load_dir(dir)?;
        Self::from_vars(&cfg, encoding, &mut vars)
    }

    fn from_vars(cfg: &Value, encoding: Encoding, vars: &mut Vars) -> Result<Self, String> {
        let has_attention = vars.contains_key(&format!("{ATTN}kernel"));
        let prefix = if has_attention { ATTN.to_string() } else { "rnn/".to_string() };
        let mut layers = Vec::new();
        for l in 0.. {
            let p = format!("{prefix}{}", CELL_FORMAT.replace("%d", &l.to_string()));
            if !vars.contains_key(&format!("{p}kernel")) {
                break;
            }
            layers.push(Lstm::new(weights::take(vars, &format!("{p}kernel"))?, weights::take(vars, &format!("{p}bias"))?));
        }
        if layers.is_empty() {
            return Err("no LSTM layers found".into());
        }
        let fc_w = weights::take(vars, "fully_connected/weights")?;
        let fc_b = weights::take(vars, "fully_connected/biases")?;
        let attention = if has_attention {
            let length = cfg["attentionLength"].as_u64().ok_or("attentionLength missing")? as usize;
            let size = layers[0].units;
            Some(Attention {
                input_kernel: weights::take(vars, &format!("{ATTN}kernel"))?,
                input_bias: weights::take(vars, &format!("{ATTN}bias"))?,
                w: {
                    // [1, 1, size, size] 1x1 conv kernel == a [size, size] matrix
                    let mut w = weights::take(vars, &format!("{ATTN}attention/attn_w"))?;
                    w.shape = vec![size, size];
                    w
                },
                v: weights::take(vars, &format!("{ATTN}attention/attn_v"))?,
                kernel: weights::take(vars, &format!("{ATTN}attention/kernel"))?,
                bias: weights::take(vars, &format!("{ATTN}attention/bias"))?,
                out_kernel: weights::take(vars, &format!("{ATTN}attention_output_projection/kernel"))?,
                out_bias: weights::take(vars, &format!("{ATTN}attention_output_projection/bias"))?,
                length,
                size,
            })
        } else {
            None
        };
        let mut aux_bits = 0;
        if let Some(aux) = cfg["auxInputs"].as_array() {
            for a in aux {
                if a["type"].as_str() == Some("BinaryCounter") {
                    aux_bits += a["args"]["numBits"].as_u64().unwrap_or(0) as usize;
                } else {
                    return Err(format!("unsupported aux input {:?}", a["type"]));
                }
            }
        }
        let chords = match cfg["chordEncoder"].as_str() {
            None => false,
            Some("PitchChordEncoder") => true,
            Some(other) => return Err(format!("unsupported chord encoder {other}")),
        };
        Ok(Self { encoding, cells: MultiLstm::new(layers), fc_w, fc_b, attention, aux_bits, chords })
    }

    pub fn needs_chords(&self) -> bool {
        self.chords
    }

    /// Continues `labels` (one class index per step) by `steps` steps.
    /// `temperature <= 0` = argmax. `chords`: one symbol list spread over the
    /// whole primer + continuation (magenta.js encodeProgression semantics).
    pub fn continue_labels(
        &mut self,
        primer: &[usize],
        steps: usize,
        temperature: f32,
        chords: Option<&[String]>,
        rng: &mut Rng,
    ) -> Result<Vec<usize>, String> {
        if self.chords && chords.map_or(true, |c| c.is_empty()) {
            return Err("this model needs a chord progression".into());
        }
        // magenta.js needs at least one primer step to produce the first output
        let primer: Vec<usize> = if primer.is_empty() { vec![0] } else { primer.to_vec() };
        let depth = self.encoding.depth();
        let len = primer.len();
        let total = len + steps;
        let parsed: Vec<Option<(u8, Vec<u8>)>> = match (self.chords, chords) {
            (true, Some(c)) => c.iter().map(|s| convert::parse_chord(s)).collect(),
            _ => Vec::new(),
        };
        let chord_at = |step: usize| parsed.get(step * parsed.len() / total.max(1)).and_then(|c| c.as_ref());

        let (mut c, mut h) = self.cells.zero_state();
        let mut attn = self.attention.as_ref().map(|a| AttnState {
            attention: vec![0.0; a.size],
            states: vec![0.0; a.size * a.length],
        });
        let mut last_output: Vec<f32> = Vec::new();
        let mut samples = Vec::with_capacity(steps);
        let mut logits = vec![0.0f32; depth];
        let mut input = Vec::new();

        for i in 0..total {
            let label = if i < len {
                primer[i].min(depth - 1)
            } else {
                nn::dense(&last_output, &self.fc_w, Some(&self.fc_b), &mut logits);
                let s = nn::sample_logits(&logits, temperature, rng);
                samples.push(s);
                s
            };
            if i == total - 1 {
                break;
            }
            input.clear();
            if self.chords {
                convert::encode_chord(chord_at(i + 1), &mut input);
            }
            let start = input.len();
            input.resize(start + depth, 0.0);
            input[start + label] = 1.0;
            if self.aux_bits > 0 {
                convert::binary_counter(i, self.aux_bits, &mut input);
            }
            match (&self.attention, attn.as_mut()) {
                (Some(a), Some(st)) => {
                    last_output = Self::attention_step(&mut self.cells, a, st, &input, &mut c, &mut h);
                }
                _ => {
                    self.cells.step(&input, &mut c, &mut h);
                    last_output.clone_from(h.last().unwrap());
                }
            }
        }
        Ok(samples)
    }

    fn attention_step(
        cells: &mut MultiLstm,
        a: &Attention,
        st: &mut AttnState,
        input: &[f32],
        c: &mut [Vec<f32>],
        h: &mut [Vec<f32>],
    ) -> Vec<f32> {
        let (len, size) = (a.length, a.size);
        // input projection of [input, previous attention]
        let mut x = Vec::with_capacity(input.len() + size);
        x.extend_from_slice(input);
        x.extend_from_slice(&st.attention);
        let mut rnn_in = vec![0.0; a.input_kernel.cols()];
        nn::dense(&x, &a.input_kernel, Some(&a.input_bias), &mut rnn_in);
        cells.step(&rnn_in, c, h);

        // query from every layer's (c, h)
        let mut q = Vec::new();
        for l in 0..c.len() {
            q.extend_from_slice(&c[l]);
            q.extend_from_slice(&h[l]);
        }
        let mut y = vec![0.0; size];
        nn::dense(&q, &a.kernel, Some(&a.bias), &mut y);

        // scores over the stored states: v · tanh(W·hidden + y)
        let w = &a.w;
        let mut feat = vec![0.0; size];
        let mut scores = vec![0.0f32; len];
        for (t, score) in scores.iter_mut().enumerate() {
            let hidden = &st.states[t * size..(t + 1) * size];
            nn::dense(hidden, w, None, &mut feat);
            *score = (0..size).map(|k| a.v.data[k] * (feat[k] + y[k]).tanh()).sum();
        }
        let max = scores.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        let mut sum = 0.0;
        for s in scores.iter_mut() {
            *s = (*s - max).exp();
            sum += *s;
        }
        let mut new_attn = vec![0.0f32; size];
        for (t, s) in scores.iter().enumerate() {
            let p = s / sum;
            let hidden = &st.states[t * size..(t + 1) * size];
            for k in 0..size {
                new_attn[k] += p * hidden[k];
            }
        }

        // output = [h_last, attention] · out_kernel + out_bias
        let mut o_in = Vec::with_capacity(2 * size);
        o_in.extend_from_slice(h.last().unwrap());
        o_in.extend_from_slice(&new_attn);
        let mut output = vec![0.0; a.out_kernel.cols()];
        nn::dense(&o_in, &a.out_kernel, Some(&a.out_bias), &mut output);

        // shift the window: drop the oldest, append the output
        st.states.copy_within(size.., 0);
        let tail = st.states.len() - size;
        st.states[tail..].copy_from_slice(&output);
        st.attention = new_attn;
        output
    }

    /// Drums: continue `primer` (hits in steps [0, primer_steps)) by `steps`.
    pub fn continue_drums(&mut self, primer: &[Note], primer_steps: usize, steps: usize, temperature: f32, seed: u64) -> Result<Vec<Note>, String> {
        if self.encoding != Encoding::Drums {
            return Err("not a drum model".into());
        }
        let labels = convert::drums_to_labels(primer, primer_steps);
        let out = self.continue_labels(&labels, steps, temperature, None, &mut Rng::new(seed))?;
        Ok(convert::labels_to_drums(&out, primer_steps.max(1) as u32))
    }

    /// Melody: continue a monophonic `primer` by `steps`, optionally over chords.
    pub fn continue_melody(
        &mut self,
        primer: &[Note],
        primer_steps: usize,
        steps: usize,
        temperature: f32,
        chords: Option<&[String]>,
        seed: u64,
    ) -> Result<Vec<Note>, String> {
        let Encoding::Melody { min, max } = self.encoding else {
            return Err("not a melody model".into());
        };
        let events = convert::melody_to_events(primer, min, max, primer_steps);
        let out = self.continue_labels(&events, steps, temperature, chords, &mut Rng::new(seed))?;
        Ok(convert::events_to_melody(&out, min, primer_steps.max(1) as u32))
    }
}
