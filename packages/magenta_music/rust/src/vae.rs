//! MusicVAE (flat, categorical decoder), ported from magenta.js
//! music_vae/model.ts: BidirectionalLstmEncoder + CategoricalDecoder.
//! Covers drums_2bar_* and mel_2bar_* checkpoints.

use std::path::Path;

use crate::convert::{self, Note};
use crate::nn::{self, Lstm, MultiLstm, Rng};
use crate::weights::{self, Tensor};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum VaeEncoding {
    /// DrumsConverter: encoder sees a 10-column drum roll, decoder emits 2^9 labels.
    Drums,
    Melody { min: u8, max: u8 },
}

pub struct MusicVae {
    pub encoding: VaeEncoding,
    pub steps: usize,
    enc_fw: Lstm,
    enc_bw: Lstm,
    mu: (Tensor, Tensor),
    dec: MultiLstm,
    z_to_init: (Tensor, Tensor),
    out_proj: (Tensor, Tensor),
    pub z_dims: usize,
}

const ENC: &str = "encoder/cell_0/bidirectional_rnn/%s/multi_rnn_cell/cell_0/lstm_cell/";

impl MusicVae {
    pub fn load(dir: &Path) -> Result<Self, String> {
        let cfg = weights::read_config(dir)?;
        if cfg["type"].as_str() != Some("MusicVAE") {
            return Err(format!("not a MusicVAE model: {:?}", cfg["type"]));
        }
        let dc = &cfg["dataConverter"];
        if !dc["args"]["numSegments"].is_null() {
            return Err("hierarchical MusicVAE models are not supported".into());
        }
        let steps = dc["args"]["numSteps"].as_u64().ok_or("numSteps")? as usize;
        let encoding = match dc["type"].as_str() {
            Some("DrumsConverter") => VaeEncoding::Drums,
            Some("MelodyConverter") => VaeEncoding::Melody {
                min: dc["args"]["minPitch"].as_u64().ok_or("minPitch")? as u8,
                max: dc["args"]["maxPitch"].as_u64().ok_or("maxPitch")? as u8,
            },
            other => return Err(format!("unsupported data converter {other:?}")),
        };
        let mut v = weights::load_dir(dir)?;
        let enc = |v: &mut weights::Vars, d: &str| -> Result<Lstm, String> {
            let p = ENC.replace("%s", d);
            Ok(Lstm::new(weights::take(v, &format!("{p}kernel"))?, weights::take(v, &format!("{p}bias"))?))
        };
        let enc_fw = enc(&mut v, "fw")?;
        let enc_bw = enc(&mut v, "bw")?;
        let mu = (weights::take(&mut v, "encoder/mu/kernel")?, weights::take(&mut v, "encoder/mu/bias")?);
        let mut layers = Vec::new();
        for l in 0.. {
            let p = format!("decoder/multi_rnn_cell/cell_{l}/lstm_cell/");
            if !v.contains_key(&format!("{p}kernel")) {
                break;
            }
            layers.push(Lstm::new(weights::take(&mut v, &format!("{p}kernel"))?, weights::take(&mut v, &format!("{p}bias"))?));
        }
        if v.contains_key("decoder/nade/w_enc") {
            return Err("NADE decoders are not supported".into());
        }
        let z_to_init =
            (weights::take(&mut v, "decoder/z_to_initial_state/kernel")?, weights::take(&mut v, "decoder/z_to_initial_state/bias")?);
        let out_proj =
            (weights::take(&mut v, "decoder/output_projection/kernel")?, weights::take(&mut v, "decoder/output_projection/bias")?);
        let z_dims = z_to_init.0.rows();
        Ok(Self { encoding, steps, enc_fw, enc_bw, mu, dec: MultiLstm::new(layers), z_to_init, out_proj, z_dims })
    }

    fn output_dims(&self) -> usize {
        self.out_proj.1.data.len()
    }

    /// Encoder input rows for `notes` over `self.steps` steps.
    fn inputs(&self, notes: &[Note]) -> Vec<Vec<f32>> {
        match self.encoding {
            VaeEncoding::Drums => convert::drums_to_roll(notes, self.steps).into_iter().map(|r| r.to_vec()).collect(),
            VaeEncoding::Melody { min, max } => {
                let depth = self.output_dims();
                convert::melody_to_events(notes, min, max, self.steps)
                    .into_iter()
                    .map(|e| {
                        let mut r = vec![0.0; depth];
                        r[e.min(depth - 1)] = 1.0;
                        r
                    })
                    .collect()
            }
        }
    }

    /// z = mu(concat(last forward h, first backward h)).
    pub fn encode(&self, notes: &[Note]) -> Vec<f32> {
        self.encode_rows(&self.inputs(notes))
    }

    /// Encodes pre-built encoder input rows (one per step).
    pub fn encode_rows(&self, rows: &[Vec<f32>]) -> Vec<f32> {
        let (mut xh, mut g) = (Vec::new(), Vec::new());
        let run = |cell: &Lstm, order: &mut dyn Iterator<Item = &Vec<f32>>, xh: &mut Vec<f32>, g: &mut Vec<f32>| {
            let (mut c, mut h) = (vec![0.0; cell.units], vec![0.0; cell.units]);
            for x in order {
                cell.step(x, &mut c, &mut h, xh, g);
            }
            h
        };
        let fw = run(&self.enc_fw, &mut rows.iter(), &mut xh, &mut g);
        let bw = run(&self.enc_bw, &mut rows.iter().rev(), &mut xh, &mut g);
        let mut fin = fw;
        fin.extend_from_slice(&bw);
        let mut z = vec![0.0; self.mu.1.data.len()];
        nn::dense(&fin, &self.mu.0, Some(&self.mu.1), &mut z);
        z
    }

    /// Decodes z into one class label per step (argmax when temperature <= 0).
    pub fn decode_labels(&mut self, z: &[f32], temperature: f32, rng: &mut Rng) -> Vec<usize> {
        let mut init = vec![0.0; self.z_to_init.1.data.len()];
        nn::dense(z, &self.z_to_init.0, Some(&self.z_to_init.1), &mut init);
        let (mut c, mut h) = self.dec.zero_state();
        let mut off = 0;
        for l in 0..c.len() {
            let n = c[l].len();
            for k in 0..n {
                c[l][k] = init[off + k].tanh();
                h[l][k] = init[off + n + k].tanh();
            }
            off += 2 * n;
        }
        let depth = self.output_dims();
        let mut next = vec![0.0f32; depth];
        let mut input = Vec::with_capacity(depth + z.len());
        let mut logits = vec![0.0f32; depth];
        let mut labels = Vec::with_capacity(self.steps);
        for _ in 0..self.steps {
            input.clear();
            input.extend_from_slice(&next);
            input.extend_from_slice(z);
            self.dec.step(&input, &mut c, &mut h);
            nn::dense(h.last().unwrap(), &self.out_proj.0, Some(&self.out_proj.1), &mut logits);
            let s = nn::sample_logits(&logits, temperature, rng);
            next.fill(0.0);
            next[s] = 1.0;
            labels.push(s);
        }
        labels
    }

    fn labels_to_notes(&self, labels: &[usize]) -> Vec<Note> {
        match self.encoding {
            VaeEncoding::Drums => convert::labels_to_drums(labels, 0),
            VaeEncoding::Melody { min, .. } => convert::events_to_melody(labels, min, 0),
        }
    }

    pub fn decode(&mut self, z: &[f32], temperature: f32, rng: &mut Rng) -> Vec<Note> {
        let labels = self.decode_labels(z, temperature, rng);
        self.labels_to_notes(&labels)
    }

    /// A new sequence from the prior: z ~ N(0, I).
    pub fn sample(&mut self, temperature: f32, seed: u64) -> Vec<Note> {
        let mut rng = Rng::new(seed);
        let z: Vec<f32> = (0..self.z_dims).map(|_| rng.normal()).collect();
        self.decode(&z, temperature, &mut rng)
    }

    /// The sequence `alpha` of the way from `a` to `b` in latent space.
    pub fn interpolate(&mut self, a: &[Note], b: &[Note], alpha: f32, temperature: f32, seed: u64) -> Vec<Note> {
        let za = self.encode(a);
        let zb = self.encode(b);
        let z: Vec<f32> = za.iter().zip(&zb).map(|(x, y)| x + (y - x) * alpha).collect();
        self.decode(&z, temperature, &mut Rng::new(seed))
    }

    /// A variation of `notes`: its z plus gaussian noise of `amount`.
    pub fn similar(&mut self, notes: &[Note], amount: f32, temperature: f32, seed: u64) -> Vec<Note> {
        let mut rng = Rng::new(seed);
        let z: Vec<f32> = self.encode(notes).iter().map(|v| v + amount * rng.normal()).collect();
        self.decode(&z, temperature, &mut rng)
    }
}
