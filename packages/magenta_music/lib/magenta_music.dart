/// Google Magenta music models on-device (pure Rust port, no ML runtime).
///
/// ```dart
/// final dir = await MagentaModels.ensure(MagentaModel.drumsVae, cacheDir);
/// final vae = await MusicVae.load(dir);
/// final beat = await vae.sample(temperature: 1.0); // 2 bars of drum hits
/// ```
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart' as b;

/// A quantized note; 4 steps per quarter note (16ths). Drum hits last one step
/// and use General MIDI drum pitches (36 kick, 38 snare, 42 closed hat ...).
class MagentaNote {
  const MagentaNote(this.start, this.end, this.pitch);
  final int start, end, pitch;

  @override
  bool operator ==(Object o) => o is MagentaNote && o.start == start && o.end == end && o.pitch == pitch;
  @override
  int get hashCode => Object.hash(start, end, pitch);
  @override
  String toString() => 'Note($start-$end, $pitch)';
}

class MagentaException implements Exception {
  MagentaException(this.message);
  final String message;
  @override
  String toString() => 'MagentaException: $message';
}

/// The published Magenta checkpoints this package supports (Apache-2.0).
enum MagentaModel {
  /// DrumsRNN with attention: continues a drum pattern.
  drumKitRnn('music_rnn/drum_kit_rnn', 11),

  /// MelodyRNN (basic): continues a monophonic melody.
  melodyRnn('music_rnn/melody_rnn', 13),

  /// ImprovRNN: melody over a chord progression.
  improvRnn('music_rnn/chord_pitches_improv', 6),

  /// MusicVAE 2-bar drums: sample, mix (interpolate), vary.
  drumsVae('music_vae/drums_2bar_lokl_small', 20),

  /// MusicVAE 2-bar melody: sample, mix (interpolate), vary.
  melodyVae('music_vae/mel_2bar_small', 18);

  const MagentaModel(this.path, this.sizeMb);
  final String path;
  final int sizeMb;
  String get id => path.split('/').last;
}

/// Downloads checkpoints from Magenta's public bucket into a cache dir.
abstract final class MagentaModels {
  static const base = 'https://storage.googleapis.com/magentadata/js/checkpoints';

  static Directory dirOf(MagentaModel m, Directory cache) => Directory('${cache.path}/${m.id}');

  static bool isReady(MagentaModel m, Directory cache) => File('${dirOf(m, cache).path}/.done').existsSync();

  /// Returns the model directory, downloading it first if needed.
  /// [onProgress] gets 0..1 (by files).
  static Future<Directory> ensure(MagentaModel m, Directory cache, {void Function(double)? onProgress}) async {
    final dir = dirOf(m, cache);
    if (isReady(m, cache)) return dir;
    await dir.create(recursive: true);
    final client = HttpClient();
    try {
      Future<List<int>> get(String name) async {
        final req = await client.getUrl(Uri.parse('$base/${m.path}/$name'));
        final res = await req.close();
        if (res.statusCode != 200) throw MagentaException('download $name: HTTP ${res.statusCode}');
        final bytes = <int>[];
        await for (final chunk in res) {
          bytes.addAll(chunk);
        }
        return bytes;
      }

      Future<void> save(String name, List<int> bytes) async {
        final tmp = File('${dir.path}/$name.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename('${dir.path}/$name');
      }

      final manifest = await get('weights_manifest.json');
      final config = await get('config.json');
      final shards = RegExp(r'"(group\d+-shard\d+of\d+)"').allMatches(String.fromCharCodes(manifest)).map((x) => x[1]!).toSet().toList();
      var done = 0;
      for (final s in shards) {
        await save(s, await get(s));
        onProgress?.call(++done / (shards.length + 1));
      }
      await save('config.json', config);
      await save('weights_manifest.json', manifest);
      await File('${dir.path}/.done').writeAsString('ok');
      onProgress?.call(1);
      return dir;
    } finally {
      client.close();
    }
  }
}

String _err() {
  final p = b.mmLastError();
  return p == nullptr ? 'unknown error' : p.toDartString();
}

Pointer<b.MmNote> _toNative(List<MagentaNote> notes) {
  final p = calloc<b.MmNote>(max(1, notes.length));
  for (var i = 0; i < notes.length; i++) {
    (p + i).ref
      ..start = notes[i].start
      ..end = notes[i].end
      ..pitch = notes[i].pitch.clamp(0, 127);
  }
  return p;
}

/// Calls [run] with an output buffer, growing it if the result does not fit.
List<MagentaNote> _collect(int Function(Pointer<b.MmNote> out, int cap) run) {
  var cap = 256;
  while (true) {
    final out = calloc<b.MmNote>(cap);
    try {
      final n = run(out, cap);
      if (n < 0) throw MagentaException(_err());
      if (n <= cap) {
        return [for (var i = 0; i < n; i++) MagentaNote((out + i).ref.start, (out + i).ref.end, (out + i).ref.pitch)];
      }
      cap = n;
    } finally {
      calloc.free(out);
    }
  }
}

int _seed() => Random().nextInt(1 << 32);

// Isolate entry points: top-level so their closures capture only plain values.
int _loadRnn(String dir) {
  final p = dir.toNativeUtf8();
  try {
    final m = b.mmRnnLoad(p);
    if (m == nullptr) throw MagentaException(_err());
    return m.address;
  } finally {
    malloc.free(p);
  }
}

int _loadVae(String dir) {
  final p = dir.toNativeUtf8();
  try {
    final m = b.mmVaeLoad(p);
    if (m == nullptr) throw MagentaException(_err());
    return m.address;
  } finally {
    malloc.free(p);
  }
}

List<MagentaNote> _rnnContinue((int, List<MagentaNote>, int, int, double, int, String?) a) {
  final (addr, primer, primerSteps, steps, temperature, seed, chords) = a;
  final pr = _toNative(primer);
  final ch = chords == null ? nullptr : chords.toNativeUtf8();
  try {
    return _collect((out, cap) => b.mmRnnContinue(Pointer<b.MmRnn>.fromAddress(addr), pr, primer.length, primerSteps,
        steps, temperature, seed, ch.cast(), out, cap));
  } finally {
    calloc.free(pr);
    if (ch != nullptr) malloc.free(ch);
  }
}

List<MagentaNote> _vaeSample((int, double, int) a) {
  final (addr, temperature, seed) = a;
  return _collect((out, cap) => b.mmVaeSample(Pointer<b.MmVae>.fromAddress(addr), temperature, seed, out, cap));
}

List<MagentaNote> _vaeInterpolate((int, List<MagentaNote>, List<MagentaNote>, double, double, int) a) {
  final (addr, x, y, alpha, temperature, seed) = a;
  final px = _toNative(x), py = _toNative(y);
  try {
    return _collect((out, cap) => b.mmVaeInterpolate(
        Pointer<b.MmVae>.fromAddress(addr), px, x.length, py, y.length, alpha, temperature, seed, out, cap));
  } finally {
    calloc
      ..free(px)
      ..free(py);
  }
}

List<MagentaNote> _vaeSimilar((int, List<MagentaNote>, double, double, int) a) {
  final (addr, src, amount, temperature, seed) = a;
  final ps = _toNative(src);
  try {
    return _collect((out, cap) =>
        b.mmVaeSimilar(Pointer<b.MmVae>.fromAddress(addr), ps, src.length, amount, temperature, seed, out, cap));
  } finally {
    calloc.free(ps);
  }
}

Future<R> _bg<A, R>(R Function(A) f, A arg) => Isolate.run(() => f(arg));

enum RnnKind { drums, melody, improv }

/// MusicRNN: continues a sequence (DrumsRNN, MelodyRNN, ImprovRNN).
class MusicRnn {
  MusicRnn._(this._addr, this.kind);
  final int _addr;
  final RnnKind kind;
  bool _busy = false, _disposed = false;

  static Future<MusicRnn> load(Directory dir) async {
    final addr = await _bg(_loadRnn, dir.path);
    return MusicRnn._(addr, RnnKind.values[b.mmRnnKind(Pointer.fromAddress(addr))]);
  }

  /// Continues [primer] (notes in steps [0, primerSteps)) by [steps] steps.
  /// Returned notes start at [primerSteps]. [chords] (ImprovRNN only) are
  /// spread over primer + continuation, e.g. `['C', 'G', 'Am', 'F']`.
  /// [temperature] 0 = most likely, 1 = model's own randomness, >1 wilder.
  Future<List<MagentaNote>> continueSequence(List<MagentaNote> primer,
      {required int primerSteps, required int steps, double temperature = 1.0, List<String>? chords, int? seed}) {
    return _guard(() => _bg(_rnnContinue,
        (_addr, primer, primerSteps, steps, temperature, seed ?? _seed(), chords?.join(','))));
  }

  Future<T> _guard<T>(Future<T> Function() f) async {
    if (_disposed) throw MagentaException('model disposed');
    if (_busy) throw MagentaException('model is busy');
    _busy = true;
    try {
      return await f();
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    if (_disposed || _busy) return;
    _disposed = true;
    b.mmRnnFree(Pointer.fromAddress(_addr));
  }
}

/// MusicVAE (2-bar drums or melody): sample, interpolate, vary.
class MusicVae {
  MusicVae._(this._addr, this.isDrums, this.steps);
  final int _addr;
  final bool isDrums;

  /// Sequence length in steps (32 = 2 bars of 16ths).
  final int steps;
  bool _busy = false, _disposed = false;

  static Future<MusicVae> load(Directory dir) async {
    final addr = await _bg(_loadVae, dir.path);
    final p = Pointer<b.MmVae>.fromAddress(addr);
    return MusicVae._(addr, b.mmVaeKind(p) == 0, b.mmVaeSteps(p));
  }

  Future<List<MagentaNote>> sample({double temperature = 1.0, int? seed}) =>
      _guard(() => _bg(_vaeSample, (_addr, temperature, seed ?? _seed())));

  /// The sequence [alpha] (0..1) of the way from [a] to [b].
  Future<List<MagentaNote>> interpolate(List<MagentaNote> a, List<MagentaNote> b,
          {double alpha = 0.5, double temperature = 0.5, int? seed}) =>
      _guard(() => _bg(_vaeInterpolate, (_addr, a, b, alpha, temperature, seed ?? _seed())));

  /// A variation of [notes]; [amount] 0.1 subtle .. 1.0 wild.
  Future<List<MagentaNote>> similar(List<MagentaNote> notes, {double amount = 0.4, double temperature = 0.5, int? seed}) =>
      _guard(() => _bg(_vaeSimilar, (_addr, notes, amount, temperature, seed ?? _seed())));

  Future<T> _guard<T>(Future<T> Function() f) async {
    if (_disposed) throw MagentaException('model disposed');
    if (_busy) throw MagentaException('model is busy');
    _busy = true;
    try {
      return await f();
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    if (_disposed || _busy) return;
    _disposed = true;
    b.mmVaeFree(Pointer.fromAddress(_addr));
  }
}
