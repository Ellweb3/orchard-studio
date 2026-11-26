// Hand-written bindings to engine/rust/src/lib.rs (flat C ABI).
// Keep in sync with the `oe_*` exports and the repr(C) structs.
@DefaultAsset('package:orchard_engine/src/bindings.dart')
library;

import 'dart:ffi';

final class OeHandle extends Opaque {}

final class OeSoundFont extends Opaque {}

/// engine::Note (repr C: u32, u32, u8, u8 + 2 padding).
final class OeNote extends Struct {
  @Uint32()
  external int pos;
  @Uint32()
  external int len;
  @Uint8()
  external int key;
  @Uint8()
  external int vel;
}

/// threeosc::OscParams (repr C).
final class OeOscParams extends Struct {
  @Array(3)
  external Array<Uint8> shape;
  @Array(3)
  external Array<Int8> coarse;
  @Array(3)
  external Array<Int8> fine;
  @Array(3)
  external Array<Int8> pan;
  @Uint8()
  external int mix2;
  @Uint8()
  external int mix3;
  @Bool()
  external bool env;
  @Float()
  external double attack;
  @Float()
  external double decay;
  @Float()
  external double sustain;
  @Float()
  external double release;
}

@Native<Pointer<OeHandle> Function()>(symbol: 'oe_create')
external Pointer<OeHandle> oeCreate();

@Native<Pointer<Char> Function()>(symbol: 'oe_last_error')
external Pointer<Char> oeLastError();

@Native<Void Function(Pointer<OeHandle>)>(symbol: 'oe_destroy')
external void oeDestroy(Pointer<OeHandle> h);

@Native<Void Function(Pointer<OeHandle>)>(symbol: 'oe_collect')
external void oeCollect(Pointer<OeHandle> h);

@Native<Bool Function(Pointer<OeHandle>, Double)>(symbol: 'oe_set_tempo')
external bool oeSetTempo(Pointer<OeHandle> h, double bpm);

@Native<Bool Function(Pointer<OeHandle>, Float)>(symbol: 'oe_set_swing')
external bool oeSetSwing(Pointer<OeHandle> h, double swing);

@Native<Bool Function(Pointer<OeHandle>, Float)>(symbol: 'oe_set_master')
external bool oeSetMaster(Pointer<OeHandle> h, double fader);

@Native<Bool Function(Pointer<OeHandle>, Bool)>(symbol: 'oe_play')
external bool oePlay(Pointer<OeHandle> h, bool play);

@Native<Bool Function(Pointer<OeHandle>, Bool)>(symbol: 'oe_set_metronome')
external bool oeSetMetronome(Pointer<OeHandle> h, bool on);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8, Pointer<OeNote>, Uint32)>(symbol: 'oe_set_notes')
external bool oeSetNotes(Pointer<OeHandle> h, int pat, int ch, Pointer<OeNote> notes, int count);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Float, Float, Float, Bool, Bool, Uint8)>(symbol: 'oe_set_channel')
external bool oeSetChannel(
    Pointer<OeHandle> h, int ch, double vol, double pan, double pitch, bool mute, bool used, int insert);

/// engine::Clip (repr C: u32, u32, u8 + 3 padding).
final class OeClip extends Struct {
  @Uint32()
  external int start;
  @Uint32()
  external int len;
  @Uint8()
  external int pattern;
}

@Native<Bool Function(Pointer<OeHandle>, Bool)>(symbol: 'oe_song_mode')
external bool oeSongMode(Pointer<OeHandle> h, bool on);

@Native<Bool Function(Pointer<OeHandle>, Pointer<OeClip>, Uint32)>(symbol: 'oe_set_clips')
external bool oeSetClips(Pointer<OeHandle> h, Pointer<OeClip> clips, int count);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Float, Float, Bool)>(symbol: 'oe_set_insert')
external bool oeSetInsert(Pointer<OeHandle> h, int idx, double vol, double pan, bool mute);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8, Uint8, Pointer<Float>)>(symbol: 'oe_set_fx')
external bool oeSetFx(Pointer<OeHandle> h, int ins, int slot, int kind, Pointer<Float> params);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8, Uint8, Float)>(symbol: 'oe_fx_param')
external bool oeFxParam(Pointer<OeHandle> h, int ins, int slot, int param, double value);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8, Bool)>(symbol: 'oe_fx_bypass')
external bool oeFxBypass(Pointer<OeHandle> h, int ins, int slot, bool bypass);

@Native<Float Function(Pointer<OeHandle>, Uint32)>(symbol: 'oe_take_insert_peak', isLeaf: true)
external double oeTakeInsertPeak(Pointer<OeHandle> h, int idx);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8)>(symbol: 'oe_set_sampler')
external bool oeSetSampler(Pointer<OeHandle> h, int ch, int sample);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Pointer<OeOscParams>)>(symbol: 'oe_set_osc')
external bool oeSetOsc(Pointer<OeHandle> h, int ch, Pointer<OeOscParams> params);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint16, Uint8)>(symbol: 'oe_set_soundfont')
external bool oeSetSoundFont(Pointer<OeHandle> h, int ch, int bank, int program);

@Native<Pointer<OeSoundFont> Function(Pointer<Uint8>, Size)>(symbol: 'oe_parse_soundfont')
external Pointer<OeSoundFont> oeParseSoundFont(Pointer<Uint8> data, int len);

@Native<Bool Function(Pointer<OeHandle>, Pointer<OeSoundFont>)>(symbol: 'oe_attach_soundfont')
external bool oeAttachSoundFont(Pointer<OeHandle> h, Pointer<OeSoundFont> sf);

@Native<Uint32 Function(Pointer<OeHandle>)>(symbol: 'oe_sf_preset_count')
external int oeSfPresetCount(Pointer<OeHandle> h);

@Native<Bool Function(Pointer<OeHandle>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint16>, Pointer<Uint8>)>(
    symbol: 'oe_sf_preset_info')
external bool oeSfPresetInfo(
    Pointer<OeHandle> h, int i, Pointer<Uint8> name, int cap, Pointer<Uint16> bank, Pointer<Uint8> program);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8)>(symbol: 'oe_set_pattern_len')
external bool oeSetPatternLen(Pointer<OeHandle> h, int pat, int steps);

@Native<Bool Function(Pointer<OeHandle>, Uint8)>(symbol: 'oe_select_pattern')
external bool oeSelectPattern(Pointer<OeHandle> h, int pat);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8, Uint8)>(symbol: 'oe_note_on')
external bool oeNoteOn(Pointer<OeHandle> h, int ch, int key, int vel);

@Native<Bool Function(Pointer<OeHandle>, Uint8, Uint8)>(symbol: 'oe_note_off')
external bool oeNoteOff(Pointer<OeHandle> h, int ch, int key);

@Native<Double Function(Pointer<OeHandle>)>(symbol: 'oe_position', isLeaf: true)
external double oePosition(Pointer<OeHandle> h);

@Native<Float Function(Pointer<OeHandle>, Uint32)>(symbol: 'oe_take_peak', isLeaf: true)
external double oeTakePeak(Pointer<OeHandle> h, int idx);

@Native<Uint32 Function(Pointer<OeHandle>)>(symbol: 'oe_sample_rate', isLeaf: true)
external int oeSampleRate(Pointer<OeHandle> h);

@Native<Uint64 Function(Pointer<OeHandle>)>(symbol: 'oe_xruns', isLeaf: true)
external int oeXruns(Pointer<OeHandle> h);
