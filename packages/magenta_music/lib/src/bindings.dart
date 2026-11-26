// Hand-written bindings to rust/src/ffi.rs (flat C ABI, `mm_*`).
@DefaultAsset('package:magenta_music/src/bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class MmRnn extends Opaque {}

final class MmVae extends Opaque {}

/// convert::Note (repr C: u32 start, u32 end, u8 pitch + 3 padding).
final class MmNote extends Struct {
  @Uint32()
  external int start;
  @Uint32()
  external int end;
  @Uint8()
  external int pitch;
}

@Native<Pointer<Utf8> Function()>(symbol: 'mm_last_error')
external Pointer<Utf8> mmLastError();

@Native<Pointer<MmRnn> Function(Pointer<Utf8>)>(symbol: 'mm_rnn_load')
external Pointer<MmRnn> mmRnnLoad(Pointer<Utf8> dir);

@Native<Void Function(Pointer<MmRnn>)>(symbol: 'mm_rnn_free')
external void mmRnnFree(Pointer<MmRnn> m);

@Native<Uint8 Function(Pointer<MmRnn>)>(symbol: 'mm_rnn_kind')
external int mmRnnKind(Pointer<MmRnn> m);

@Native<
    Int32 Function(Pointer<MmRnn>, Pointer<MmNote>, Uint32, Uint32, Uint32, Float, Uint64, Pointer<Utf8>,
        Pointer<MmNote>, Uint32)>(symbol: 'mm_rnn_continue')
external int mmRnnContinue(Pointer<MmRnn> m, Pointer<MmNote> primer, int primerLen, int primerSteps, int steps,
    double temperature, int seed, Pointer<Utf8> chords, Pointer<MmNote> out, int outCap);

@Native<Pointer<MmVae> Function(Pointer<Utf8>)>(symbol: 'mm_vae_load')
external Pointer<MmVae> mmVaeLoad(Pointer<Utf8> dir);

@Native<Void Function(Pointer<MmVae>)>(symbol: 'mm_vae_free')
external void mmVaeFree(Pointer<MmVae> m);

@Native<Uint8 Function(Pointer<MmVae>)>(symbol: 'mm_vae_kind')
external int mmVaeKind(Pointer<MmVae> m);

@Native<Uint32 Function(Pointer<MmVae>)>(symbol: 'mm_vae_steps')
external int mmVaeSteps(Pointer<MmVae> m);

@Native<Int32 Function(Pointer<MmVae>, Float, Uint64, Pointer<MmNote>, Uint32)>(symbol: 'mm_vae_sample')
external int mmVaeSample(Pointer<MmVae> m, double temperature, int seed, Pointer<MmNote> out, int outCap);

@Native<
    Int32 Function(Pointer<MmVae>, Pointer<MmNote>, Uint32, Pointer<MmNote>, Uint32, Float, Float, Uint64,
        Pointer<MmNote>, Uint32)>(symbol: 'mm_vae_interpolate')
external int mmVaeInterpolate(Pointer<MmVae> m, Pointer<MmNote> a, int aLen, Pointer<MmNote> b, int bLen,
    double alpha, double temperature, int seed, Pointer<MmNote> out, int outCap);

@Native<Int32 Function(Pointer<MmVae>, Pointer<MmNote>, Uint32, Float, Float, Uint64, Pointer<MmNote>, Uint32)>(
    symbol: 'mm_vae_similar')
external int mmVaeSimilar(Pointer<MmVae> m, Pointer<MmNote> src, int srcLen, double amount, double temperature,
    int seed, Pointer<MmNote> out, int outCap);
