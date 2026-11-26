//! The few neural-network ops the Magenta models need, matching tf.js:
//! row-vector x matrix products, `tf.basicLSTMCell`, softmax and sampling.

use crate::weights::Tensor;

/// out = x · W + b, with W row-major [in, out] (tf.js layout).
pub fn dense(x: &[f32], w: &Tensor, b: Option<&Tensor>, out: &mut [f32]) {
    let (rows, cols) = (w.rows(), w.cols());
    debug_assert_eq!(x.len(), rows);
    debug_assert_eq!(out.len(), cols);
    match b {
        Some(b) => out.copy_from_slice(&b.data[..cols]),
        None => out.fill(0.0),
    }
    for (r, &xv) in x.iter().enumerate() {
        if xv == 0.0 {
            continue; // one-hot inputs are mostly zeros
        }
        let row = &w.data[r * cols..(r + 1) * cols];
        for (o, &wv) in out.iter_mut().zip(row) {
            *o += xv * wv;
        }
    }
}

#[inline]
pub fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

/// One LSTM layer, `tf.basicLSTMCell` semantics: gates [i, j, f, o] from
/// concat(input, h) · kernel + bias, forget bias 1.0.
pub struct Lstm {
    pub kernel: Tensor,
    pub bias: Tensor,
    pub units: usize,
}

impl Lstm {
    pub fn new(kernel: Tensor, bias: Tensor) -> Self {
        let units = bias.data.len() / 4;
        Self { kernel, bias, units }
    }

    pub fn input_size(&self) -> usize {
        self.kernel.rows() - self.units
    }

    /// Updates (c, h) in place. `scratch` must hold input + units and 4 * units floats.
    pub fn step(&self, input: &[f32], c: &mut [f32], h: &mut [f32], xh: &mut Vec<f32>, gates: &mut Vec<f32>) {
        let n = self.units;
        xh.clear();
        xh.extend_from_slice(input);
        xh.extend_from_slice(h);
        gates.resize(4 * n, 0.0);
        dense(xh, &self.kernel, Some(&self.bias), gates);
        for k in 0..n {
            let i = gates[k];
            let j = gates[n + k];
            let f = gates[2 * n + k];
            let o = gates[3 * n + k];
            let nc = c[k] * sigmoid(f + 1.0) + sigmoid(i) * j.tanh();
            c[k] = nc;
            h[k] = nc.tanh() * sigmoid(o);
        }
    }
}

/// Stacked LSTM (`tf.multiRNNCell`): each layer feeds the next.
pub struct MultiLstm {
    pub layers: Vec<Lstm>,
    xh: Vec<f32>,
    gates: Vec<f32>,
    tmp: Vec<f32>,
}

impl MultiLstm {
    pub fn new(layers: Vec<Lstm>) -> Self {
        Self { layers, xh: Vec::new(), gates: Vec::new(), tmp: Vec::new() }
    }

    pub fn zero_state(&self) -> (Vec<Vec<f32>>, Vec<Vec<f32>>) {
        let c = self.layers.iter().map(|l| vec![0.0; l.units]).collect();
        let h = self.layers.iter().map(|l| vec![0.0; l.units]).collect();
        (c, h)
    }

    pub fn step(&mut self, input: &[f32], c: &mut [Vec<f32>], h: &mut [Vec<f32>]) {
        self.tmp.clear();
        self.tmp.extend_from_slice(input);
        for (l, layer) in self.layers.iter().enumerate() {
            layer.step(&self.tmp, &mut c[l], &mut h[l], &mut self.xh, &mut self.gates);
            self.tmp.clear();
            self.tmp.extend_from_slice(&h[l]);
        }
    }
}

/// Small deterministic RNG (xoshiro128++ seeded by splitmix64).
pub struct Rng {
    s: [u32; 4],
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        let mut z = seed;
        let mut next = || {
            z = z.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut x = z;
            x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            x ^ (x >> 31)
        };
        let a = next();
        let b = next();
        Self { s: [a as u32, (a >> 32) as u32, b as u32, (b >> 32) as u32 | 1] }
    }

    pub fn next_u32(&mut self) -> u32 {
        let s = &mut self.s;
        let r = s[0].wrapping_add(s[3]).rotate_left(7).wrapping_add(s[0]);
        let t = s[1] << 9;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = s[3].rotate_left(11);
        r
    }

    /// Uniform in [0, 1).
    pub fn uniform(&mut self) -> f32 {
        (self.next_u32() >> 8) as f32 / (1u32 << 24) as f32
    }

    /// Standard normal (Box-Muller).
    pub fn normal(&mut self) -> f32 {
        let u1 = self.uniform().max(1e-7);
        let u2 = self.uniform();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f32::consts::PI * u2).cos()
    }
}

pub fn argmax(x: &[f32]) -> usize {
    let mut best = 0;
    for (i, &v) in x.iter().enumerate() {
        if v > x[best] {
            best = i;
        }
    }
    best
}

/// Samples a category from logits / temperature; argmax when temperature <= 0
/// (magenta.js semantics: no temperature = argmax).
pub fn sample_logits(logits: &[f32], temperature: f32, rng: &mut Rng) -> usize {
    if temperature <= 0.0 {
        return argmax(logits);
    }
    let max = logits.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    let mut sum = 0.0f64;
    let probs: Vec<f64> = logits
        .iter()
        .map(|&l| {
            let p = (((l - max) / temperature) as f64).exp();
            sum += p;
            p
        })
        .collect();
    let mut r = rng.uniform() as f64 * sum;
    for (i, p) in probs.iter().enumerate() {
        r -= p;
        if r <= 0.0 {
            return i;
        }
    }
    probs.len() - 1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(shape: &[usize], data: Vec<f32>) -> Tensor {
        Tensor { shape: shape.to_vec(), data }
    }

    #[test]
    fn dense_matches_hand_computation() {
        let w = t(&[2, 3], vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]);
        let b = t(&[3], vec![0.5, 0.5, 0.5]);
        let mut out = [0.0; 3];
        dense(&[1.0, -1.0], &w, Some(&b), &mut out);
        assert_eq!(out, [-2.5, -2.5, -2.5]);
    }

    #[test]
    fn lstm_cell_matches_tfjs_formula() {
        // 1 input, 1 unit: kernel rows = [x, h], cols = [i, j, f, o]
        let k = t(&[2, 4], vec![0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]);
        let b = t(&[4], vec![0.0, 0.1, 0.0, -0.1]);
        let cell = Lstm::new(k, b);
        let (mut c, mut h) = (vec![0.3], vec![-0.2]);
        let (mut xh, mut g) = (Vec::new(), Vec::new());
        cell.step(&[1.0], &mut c, &mut h, &mut xh, &mut g);
        let (x, h0, c0) = (1.0f32, -0.2f32, 0.3f32);
        let i = 0.1 * x + 0.5 * h0;
        let j = 0.2 * x + 0.6 * h0 + 0.1;
        let f = 0.3 * x + 0.7 * h0;
        let o = 0.4 * x + 0.8 * h0 - 0.1;
        let nc = c0 * sigmoid(f + 1.0) + sigmoid(i) * j.tanh();
        assert!((c[0] - nc).abs() < 1e-6);
        assert!((h[0] - nc.tanh() * sigmoid(o)).abs() < 1e-6);
    }

    #[test]
    fn sampling_is_seeded_and_tempered() {
        let logits = [0.0, 3.0, 0.0];
        assert_eq!(sample_logits(&logits, 0.0, &mut Rng::new(1)), 1);
        let mut r = Rng::new(42);
        let hits = (0..1000).filter(|_| sample_logits(&logits, 0.1, &mut r) == 1).count();
        assert!(hits > 990, "{hits}");
        let mut r = Rng::new(42);
        let hits = (0..1000).filter(|_| sample_logits(&logits, 100.0, &mut r) == 1).count();
        assert!((250..420).contains(&hits), "{hits}");
        assert_eq!(Rng::new(7).next_u32(), Rng::new(7).next_u32());
    }
}
