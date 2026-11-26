/// Dart API over the Rust engine. One instance per app.
library;

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart' as b;

const int kMaxChannels = 16;
const int kMaxPatterns = 8;
const int kMaxSteps = 64;
const int kPpq = 96;
const int kTicksPerStep = 24;

/// Built-in kit, index = sample id in the engine (engine/rust/src/drumkit.rs).
const List<String> kSounds = ['Kick', 'Clap', 'Hat', 'Open Hat', 'Snare', '808 Bass', 'Chord Stab'];

class EngineException implements Exception {
  EngineException(this.message);
  final String message;
  @override
  String toString() => 'EngineException: $message';
}

/// A pattern note. `len == 0` is a step (one-shot).
class EngineNote {
  const EngineNote(this.pos, this.len, this.key, this.vel);
  final int pos, len, key, vel;
}

/// 3x Osc parameters (engine/rust/src/threeosc.rs OscParams).
class OscParams {
  const OscParams({
    this.shape = const [0, 0, 0],
    this.coarse = const [0, -12, -24],
    this.fine = const [0, 0, 0],
    this.pan = const [0, 0, 0],
    this.mix2 = 64,
    this.mix3 = 32,
    this.env = false,
    this.attack = 0,
    this.decay = 0,
    this.sustain = 1,
    this.release = 0,
  });

  /// 0 sine, 1 triangle, 2 square, 3 saw, 4 rounded saw, 5 noise.
  final List<int> shape;
  final List<int> coarse, fine, pan;
  final int mix2, mix3;
  final bool env;
  final double attack, decay, sustain, release;

  Map<String, dynamic> toJson() => {
        'shape': shape,
        'coarse': coarse,
        'fine': fine,
        'pan': pan,
        'mix2': mix2,
        'mix3': mix3,
        'env': env,
        'a': attack,
        'd': decay,
        's': sustain,
        'r': release,
      };

  factory OscParams.fromJson(Map<String, dynamic> j) {
    List<int> l(String k, List<int> d) => (j[k] as List?)?.map((e) => (e as num).toInt()).toList() ?? d;
    double n(String k, double d) => (j[k] as num?)?.toDouble() ?? d;
    return OscParams(
      shape: l('shape', const [0, 0, 0]),
      coarse: l('coarse', const [0, -12, -24]),
      fine: l('fine', const [0, 0, 0]),
      pan: l('pan', const [0, 0, 0]),
      mix2: (j['mix2'] as num?)?.toInt() ?? 64,
      mix3: (j['mix3'] as num?)?.toInt() ?? 32,
      env: j['env'] as bool? ?? false,
      attack: n('a', 0),
      decay: n('d', 0),
      sustain: n('s', 1),
      release: n('r', 0),
    );
  }
}

class SoundFontPreset {
  const SoundFontPreset(this.name, this.bank, this.program);
  final String name;
  final int bank, program;
}

class OrchardEngine {
  OrchardEngine._(this._h);

  final Pointer<b.OeHandle> _h;
  bool _disposed = false;
  List<SoundFontPreset> _presets = const [];

  /// Opens the default audio output and starts the engine thread.
  factory OrchardEngine.start() {
    final h = b.oeCreate();
    if (h == nullptr) throw EngineException(_lastError());
    return OrchardEngine._(h);
  }

  static String _lastError() {
    final err = b.oeLastError();
    return err == nullptr ? 'unknown error' : err.cast<Utf8>().toDartString();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    b.oeDestroy(_h);
  }

  void setTempo(double bpm) => b.oeSetTempo(_h, bpm);
  void setSwing(double swing) => b.oeSetSwing(_h, swing);
  void setMaster(double fader) => b.oeSetMaster(_h, fader);
  void play(bool on) => b.oePlay(_h, on);
  void setMetronome(bool on) => b.oeSetMetronome(_h, on);
  void setPatternLength(int pat, int steps) => b.oeSetPatternLen(_h, pat, steps);
  void selectPattern(int pat) => b.oeSelectPattern(_h, pat);
  void noteOn(int ch, int key, [int vel = 100]) => b.oeNoteOn(_h, ch, key.clamp(0, 127), vel.clamp(1, 128));
  void noteOff(int ch, int key) => b.oeNoteOff(_h, ch, key.clamp(0, 127));
  void collect() => b.oeCollect(_h);

  void setChannel(int ch, {required double vol, required double pan, double pitch = 0, bool mute = false, bool used = true}) =>
      b.oeSetChannel(_h, ch, vol, pan, pitch, mute, used);

  void setNotes(int pat, int ch, List<EngineNote> notes) {
    if (notes.isEmpty) {
      b.oeSetNotes(_h, pat, ch, nullptr, 0);
      return;
    }
    final p = calloc<b.OeNote>(notes.length);
    try {
      for (var i = 0; i < notes.length; i++) {
        final n = notes[i];
        (p + i).ref
          ..pos = n.pos
          ..len = n.len
          ..key = n.key.clamp(0, 127)
          ..vel = n.vel.clamp(0, 128);
      }
      b.oeSetNotes(_h, pat, ch, p, notes.length);
    } finally {
      calloc.free(p);
    }
  }

  void setSampler(int ch, int sample) => b.oeSetSampler(_h, ch, sample);

  void setOsc(int ch, OscParams o) {
    final p = calloc<b.OeOscParams>();
    try {
      final r = p.ref;
      for (var i = 0; i < 3; i++) {
        r.shape[i] = o.shape[i].clamp(0, 5);
        r.coarse[i] = o.coarse[i].clamp(-48, 48);
        r.fine[i] = o.fine[i].clamp(-100, 100);
        r.pan[i] = o.pan[i].clamp(-64, 64);
      }
      r
        ..mix2 = o.mix2.clamp(0, 128)
        ..mix3 = o.mix3.clamp(0, 128)
        ..env = o.env
        ..attack = o.attack
        ..decay = o.decay
        ..sustain = o.sustain
        ..release = o.release;
      b.oeSetOsc(_h, ch, p);
    } finally {
      calloc.free(p);
    }
  }

  /// False when no SoundFont is loaded yet.
  bool setSoundFont(int ch, int bank, int program) => b.oeSetSoundFont(_h, ch, bank, program);

  bool get hasSoundFont => _presets.isNotEmpty;
  List<SoundFontPreset> get soundFontPresets => _presets;

  /// Parses the .sf2 on a background isolate, then attaches it.
  Future<void> loadSoundFont(Uint8List bytes) async {
    final addr = await Isolate.run(() {
      final p = malloc<Uint8>(bytes.length);
      try {
        p.asTypedList(bytes.length).setAll(0, bytes);
        final sf = b.oeParseSoundFont(p, bytes.length);
        if (sf == nullptr) throw EngineException(_lastError());
        return sf.address;
      } finally {
        malloc.free(p);
      }
    });
    b.oeAttachSoundFont(_h, Pointer<b.OeSoundFont>.fromAddress(addr));
    final n = b.oeSfPresetCount(_h);
    final name = calloc<Uint8>(64);
    final bank = calloc<Uint16>();
    final prog = calloc<Uint8>();
    final list = <SoundFontPreset>[];
    try {
      for (var i = 0; i < n; i++) {
        if (b.oeSfPresetInfo(_h, i, name, 64, bank, prog)) {
          list.add(SoundFontPreset(name.cast<Utf8>().toDartString(), bank.value, prog.value));
        }
      }
    } finally {
      calloc
        ..free(name)
        ..free(bank)
        ..free(prog);
    }
    list.sort((a, b) => a.bank != b.bank ? a.bank.compareTo(b.bank) : a.program.compareTo(b.program));
    _presets = list;
  }

  /// Pattern-local position in ticks.
  double get position => b.oePosition(_h);

  /// Peak since last read; [ch] == kMaxChannels is the master.
  double takePeak(int ch) => b.oeTakePeak(_h, ch);
  int get sampleRate => b.oeSampleRate(_h);
  int get xruns => b.oeXruns(_h);
}
