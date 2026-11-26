/// Dart API over the Rust engine. One instance per app.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart' as b;

const int kMaxChannels = 16;
const int kMaxPatterns = 8;
const int kMaxSteps = 64;
const double kPpq = 96;
const double kTicksPerStep = 24;

/// Built-in kit, index = sample id in the engine (engine/rust/src/drumkit.rs).
const List<String> kSounds = ['Kick', 'Clap', 'Hat', 'Open Hat', 'Snare', '808 Bass', 'Chord Stab'];

class EngineException implements Exception {
  EngineException(this.message);
  final String message;
  @override
  String toString() => 'EngineException: $message';
}

class OrchardEngine {
  OrchardEngine._(this._h);

  final Pointer<b.OeHandle> _h;
  bool _disposed = false;

  /// Opens the default audio output and starts the engine thread.
  factory OrchardEngine.start() {
    final h = b.oeCreate();
    if (h == nullptr) {
      final err = b.oeLastError();
      throw EngineException(err == nullptr ? 'unknown error' : err.cast<Utf8>().toDartString());
    }
    return OrchardEngine._(h);
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
  void setStep(int pat, int ch, int step, int vel) => b.oeSetStep(_h, pat, ch, step, vel);
  void setChannel(int ch,
          {required int sample,
          required double vol,
          required double pan,
          double pitch = 0,
          bool mute = false,
          bool used = true}) =>
      b.oeSetChannel(_h, ch, sample, vol, pan, pitch, mute, used);
  void setPatternLength(int pat, int steps) => b.oeSetPatternLen(_h, pat, steps);
  void selectPattern(int pat) => b.oeSelectPattern(_h, pat);
  void preview(int ch) => b.oePreview(_h, ch);
  void clearPattern(int pat) => b.oeClearPattern(_h, pat);

  /// Pattern-local position in ticks.
  double get position => b.oePosition(_h);

  /// Peak since last read; [ch] == kMaxChannels is the master.
  double takePeak(int ch) => b.oeTakePeak(_h, ch);
  int get sampleRate => b.oeSampleRate(_h);
  int get xruns => b.oeXruns(_h);
}
