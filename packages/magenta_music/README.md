# magenta_music

Google [Magenta](https://magenta.tensorflow.org) music models for Dart and Flutter,
running **on-device** through a pure Rust port: no TensorFlow, no ML runtime, no network
after the one-time model download.

| Model | Does | Size |
|---|---|---|
| `MagentaModel.drumsVae` (MusicVAE `drums_2bar_lokl_small`) | new 2-bar beats, mix two beats, variations | 20 MB |
| `MagentaModel.melodyVae` (MusicVAE `mel_2bar_small`) | new 2-bar melodies, mix, variations | 18 MB |
| `MagentaModel.drumKitRnn` (DrumsRNN + attention) | continue a beat | 11 MB |
| `MagentaModel.melodyRnn` (MelodyRNN) | continue a melody | 13 MB |
| `MagentaModel.improvRnn` (ImprovRNN) | melody over a chord progression | 6 MB |

```dart
final cache = Directory('${(await getApplicationSupportDirectory()).path}/magenta');
final vae = await MusicVae.load(await MagentaModels.ensure(MagentaModel.drumsVae, cache));
final beat = await vae.sample(temperature: 0.7); // List<MagentaNote>, 16ths, GM drum pitches

final improv = await MusicRnn.load(await MagentaModels.ensure(MagentaModel.improvRnn, cache));
final tune = await improv.continueSequence([], primerSteps: 1, steps: 32, chords: ['C', 'G', 'Am', 'F']);
```

## How it works
`rust/` reads the TensorFlow.js checkpoints magenta.js publishes and implements the few ops
the models need (`tf.basicLSTMCell`, dense layers, the attention cell wrapper, softmax
sampling). It is built for every target by `hook/build.dart` (`native_toolchain_rust`) and
called through a flat C ABI.

**Parity:** `rust/tests/golden.rs` checks argmax outputs against magenta.js 1.23.1
(`tool/golden.js`): identical notes for all five models and the same latent vectors
(< 1e-4). One deliberate difference: magenta.js `DrumsConverter` writes its "no hit" column
one row early (`TensorBuffer.set(v, i, -1)` addresses row i-1); this port uses the correct
encoding the models were trained with in Python.

## Development
```sh
tool/fetch_models.sh                      # checkpoints into ./models (tests need them)
(cd rust && cargo test --release)
dart test
```

## License
Apache-2.0. A port of magenta.js (Copyright 2018 Google Inc., Apache-2.0). The model
checkpoints are Google's, Apache-2.0, downloaded from `storage.googleapis.com/magentadata`.
