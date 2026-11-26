import 'dart:ffi';
import 'dart:io';

import 'package:magenta_music/magenta_music.dart';
import 'package:magenta_music/src/bindings.dart';
import 'package:test/test.dart';

void main() {
  final models = Directory('models');
  final have = MagentaModels.isReady(MagentaModel.drumsVae, models);

  test('note struct matches Rust', () => expect(sizeOf<MmNote>(), 12));

  test('drums: VAE sample, mix, vary; RNN continue', () async {
    final vae = await MusicVae.load(MagentaModels.dirOf(MagentaModel.drumsVae, models));
    expect(vae.isDrums, isTrue);
    expect(vae.steps, 32);
    final a = await vae.sample(seed: 1);
    final b = await vae.sample(seed: 2);
    expect(a, isNotEmpty);
    expect(a.every((n) => n.start < 32 && n.end == n.start + 1), isTrue);
    expect(await vae.sample(seed: 1), a); // seeded
    final mid = await vae.interpolate(a, b, alpha: 0.5);
    expect(mid.every((n) => n.start < 32), isTrue);
    expect(await vae.similar(a), isNotEmpty);
    vae.dispose();

    final rnn = await MusicRnn.load(MagentaModels.dirOf(MagentaModel.drumKitRnn, models));
    expect(rnn.kind, RnnKind.drums);
    final cont = await rnn.continueSequence(a.where((n) => n.start < 16).toList(), primerSteps: 16, steps: 16, seed: 3);
    expect(cont.every((n) => n.start >= 16 && n.start < 32), isTrue);
    rnn.dispose();
  }, skip: have ? false : 'run tool/fetch_models.sh');

  test('melody: improv over chords', () async {
    final rnn = await MusicRnn.load(MagentaModels.dirOf(MagentaModel.improvRnn, models));
    expect(rnn.kind, RnnKind.improv);
    final out = await rnn.continueSequence(const [MagentaNote(0, 4, 60)],
        primerSteps: 4, steps: 28, chords: ['C', 'G', 'Am', 'F'], temperature: 1.0, seed: 5);
    expect(out, isNotEmpty);
    expect(out.every((n) => n.pitch >= 48 && n.pitch <= 83 && n.end > n.start), isTrue);
    rnn.dispose();
  }, skip: have ? false : 'run tool/fetch_models.sh');
}
