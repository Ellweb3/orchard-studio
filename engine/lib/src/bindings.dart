// Hand-written bindings to engine/rust/src/lib.rs (flat C ABI).
// Keep in sync with the `oe_*` exports.
@DefaultAsset('package:orchard_engine/src/bindings.dart')
library;

import 'dart:ffi';

final class OeHandle extends Opaque {}

@Native<Pointer<OeHandle> Function()>(symbol: 'oe_create')
external Pointer<OeHandle> oeCreate();

@Native<Pointer<Char> Function()>(symbol: 'oe_last_error')
external Pointer<Char> oeLastError();

@Native<Void Function(Pointer<OeHandle>)>(symbol: 'oe_destroy')
external void oeDestroy(Pointer<OeHandle> h);

@Native<Bool Function(Pointer<OeHandle>, Double)>(symbol: 'oe_set_tempo', isLeaf: true)
external bool oeSetTempo(Pointer<OeHandle> h, double bpm);

@Native<Bool Function(Pointer<OeHandle>, Float)>(symbol: 'oe_set_swing', isLeaf: true)
external bool oeSetSwing(Pointer<OeHandle> h, double swing);

@Native<Bool Function(Pointer<OeHandle>, Float)>(symbol: 'oe_set_master', isLeaf: true)
external bool oeSetMaster(Pointer<OeHandle> h, double fader);

@Native<Bool Function(Pointer<OeHandle>, Bool)>(symbol: 'oe_play', isLeaf: true)
external bool oePlay(Pointer<OeHandle> h, bool play);

@Native<Bool Function(Pointer<OeHandle>, Bool)>(symbol: 'oe_set_metronome', isLeaf: true)
external bool oeSetMetronome(Pointer<OeHandle> h, bool on);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8, Uint8, Uint8)>(symbol: 'oe_set_step', isLeaf: true)
external bool oeSetStep(Pointer<OeHandle> h, int pat, int ch, int step, int vel);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8, Float, Float, Float, Bool, Bool)>(
    symbol: 'oe_set_channel', isLeaf: true)
external bool oeSetChannel(
    Pointer<OeHandle> h, int ch, int sample, double vol, double pan, double pitch, bool mute, bool used);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8)>(symbol: 'oe_set_pattern_len', isLeaf: true)
external bool oeSetPatternLen(Pointer<OeHandle> h, int pat, int steps);

@Native<Bool Function(Pointer<OeHandle>, Uint8)>(symbol: 'oe_select_pattern', isLeaf: true)
external bool oeSelectPattern(Pointer<OeHandle> h, int pat);

@Native<Bool Function(Pointer<OeHandle>, Uint8)>(symbol: 'oe_preview', isLeaf: true)
external bool oePreview(Pointer<OeHandle> h, int ch);

@Native<Bool Function(Pointer<OeHandle>, Uint8)>(symbol: 'oe_clear_pattern', isLeaf: true)
external bool oeClearPattern(Pointer<OeHandle> h, int pat);

@Native<Double Function(Pointer<OeHandle>)>(symbol: 'oe_position', isLeaf: true)
external double oePosition(Pointer<OeHandle> h);

@Native<Float Function(Pointer<OeHandle>, Uint32)>(symbol: 'oe_take_peak', isLeaf: true)
external double oeTakePeak(Pointer<OeHandle> h, int idx);

@Native<Uint32 Function(Pointer<OeHandle>)>(symbol: 'oe_sample_rate', isLeaf: true)
external int oeSampleRate(Pointer<OeHandle> h);

@Native<Uint64 Function(Pointer<OeHandle>)>(symbol: 'oe_xruns', isLeaf: true)
external int oeXruns(Pointer<OeHandle> h);
