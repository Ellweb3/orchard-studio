// Golden outputs from the reference magenta.js (argmax decoding, so no
// randomness) for rust/tests/golden.rs. Usage, from a dir with
// `npm i @magenta/music@1.23.1` and the models served at $MODELS
// (e.g. `python3 -m http.server 8765` in ../models):
//   MODELS=http://127.0.0.1:8765 node golden.js > ../rust/tests/golden.json
const rnn = require('@magenta/music/node/music_rnn');
const vae = require('@magenta/music/node/music_vae');
const tf = require('@tensorflow/tfjs');

const M = process.env.MODELS || 'http://127.0.0.1:8765';
const seq = (notes, steps) => ({
  notes: notes.map(([s, e, p]) => ({pitch: p, quantizedStartStep: s, quantizedEndStep: e, isDrum: p < 0 ? undefined : undefined})),
  quantizationInfo: {stepsPerQuarter: 4},
  totalQuantizedSteps: steps,
});
const out = (ns) => ns.notes.map((n) => [n.quantizedStartStep, n.quantizedEndStep, n.pitch])
  .sort((a, b) => a[0] - b[0] || a[2] - b[2]);

(async () => {
  const g = {};
  const drumPrimer = [[0, 1, 36], [2, 3, 42], [4, 5, 38], [6, 7, 42]];
  const drums = new rnn.MusicRNN(`${M}/drum_kit_rnn`);
  await drums.initialize();
  g.drum_kit_rnn = {primer: drumPrimer, primer_steps: 8, steps: 24,
    out: out(await drums.continueSequence(seq(drumPrimer, 8), 24))};

  const melPrimer = [[0, 2, 60], [2, 4, 64], [4, 8, 67]];
  const mel = new rnn.MusicRNN(`${M}/melody_rnn`);
  await mel.initialize();
  g.melody_rnn = {primer: melPrimer, primer_steps: 8, steps: 24,
    out: out(await mel.continueSequence(seq(melPrimer, 8), 24))};

  const imp = new rnn.MusicRNN(`${M}/chord_pitches_improv`);
  await imp.initialize();
  const chords = ['C', 'G', 'Am', 'F'];
  g.chord_pitches_improv = {primer: [[0, 4, 60]], primer_steps: 4, steps: 28, chords,
    out: out(await imp.continueSequence(seq([[0, 4, 60]], 4), 28, undefined, chords))};

  for (const name of ['drums_2bar_lokl_small', 'mel_2bar_small']) {
    const m = new vae.MusicVAE(`${M}/${name}`);
    await m.initialize();
    const z = tf.tensor2d([Array.from({length: m.decoder ? 256 : 256}, (_, i) => Math.sin(i * 0.37) * 0.8)]);
    const decoded = (await m.decode(z))[0];
    const input = name.startsWith('drums') ?
      seq([[0, 1, 36], [4, 5, 38], [8, 9, 36], [12, 13, 38], [2, 3, 42], [6, 7, 42], [10, 11, 42], [14, 15, 42]], 32) :
      seq([[0, 4, 60], [4, 8, 62], [8, 12, 64], [12, 16, 65], [16, 24, 67], [24, 32, 64]], 32);
    const zEnc = await (await m.encode([input])).data();
    g[name] = {decode_z: Array.from(z.dataSync()), decoded: out(decoded),
      encode_in: input.notes.map((n) => [n.quantizedStartStep, n.quantizedEndStep, n.pitch]),
      encode_z: Array.from(zEnc)};
  }
  process.stdout.write(JSON.stringify(g));
})().catch((e) => { console.error(e); process.exit(1); });
