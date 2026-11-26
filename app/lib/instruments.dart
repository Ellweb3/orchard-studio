import 'package:orchard_engine/orchard_engine.dart';

enum InstKind { sampler, osc, soundfont }

/// What a channel plays: a kit sample, a 3x Osc patch or a SoundFont preset.
class InstrumentSpec {
  const InstrumentSpec.sampler(this.sample)
      : kind = InstKind.sampler,
        osc = const OscParams(),
        bank = 0,
        program = 0,
        label = '';
  const InstrumentSpec.osc(this.osc, this.label)
      : kind = InstKind.osc,
        sample = 0,
        bank = 0,
        program = 0;
  const InstrumentSpec.soundfont(this.bank, this.program, this.label)
      : kind = InstKind.soundfont,
        sample = 0,
        osc = const OscParams();

  final InstKind kind;
  final int sample;
  final OscParams osc;
  final int bank, program;
  final String label;

  String get name => switch (kind) {
        InstKind.sampler => kSounds[sample],
        InstKind.osc => label,
        InstKind.soundfont => label,
      };

  /// Drum sounds default to steps; the others to the piano roll.
  bool get melodic => kind != InstKind.sampler && !(kind == InstKind.soundfont && bank >= 128);

  Map<String, dynamic> toJson() => switch (kind) {
        InstKind.sampler => {'kind': 'sampler', 'sample': sample},
        InstKind.osc => {'kind': 'osc', 'label': label, 'osc': osc.toJson()},
        InstKind.soundfont => {'kind': 'sf', 'bank': bank, 'program': program, 'label': label},
      };

  static InstrumentSpec fromJson(Map<String, dynamic> j) => switch (j['kind']) {
        'osc' => InstrumentSpec.osc(
            OscParams.fromJson((j['osc'] as Map).cast<String, dynamic>()), j['label'] as String? ?? '3x Osc'),
        'sf' => InstrumentSpec.soundfont(
            (j['bank'] as num).toInt(), (j['program'] as num).toInt(), j['label'] as String? ?? 'Piano'),
        _ => InstrumentSpec.sampler(((j['sample'] as num?)?.toInt() ?? 0).clamp(0, kSounds.length - 1)),
      };

  void applyTo(OrchardEngine e, int ch) {
    switch (kind) {
      case InstKind.sampler:
        e.setSampler(ch, sample);
      case InstKind.osc:
        e.setOsc(ch, osc);
      case InstKind.soundfont:
        e.setSoundFont(ch, bank, program); // no-op until the SoundFont is loaded
    }
  }
}

/// 3x Osc patches. The first is FL's fresh 3x Osc.
const List<InstrumentSpec> kOscPresets = [
  InstrumentSpec.osc(OscParams(), '3x Osc'),
  InstrumentSpec.osc(
      OscParams(
          shape: [3, 3, 2],
          coarse: [0, 0, -12],
          fine: [0, 8, 0],
          mix2: 64,
          mix3: 24,
          env: true,
          attack: 0.005,
          decay: 0.2,
          sustain: 0.7,
          release: 0.15),
      'Пила-лид'),
  InstrumentSpec.osc(
      OscParams(
          shape: [0, 1, 0],
          coarse: [-12, -12, -24],
          mix2: 40,
          mix3: 48,
          env: true,
          attack: 0.002,
          decay: 0.3,
          sustain: 0.8,
          release: 0.08),
      'Саб-бас'),
  InstrumentSpec.osc(
      OscParams(
          shape: [3, 3, 1],
          coarse: [0, 0, 12],
          fine: [-10, 10, 0],
          mix2: 64,
          mix3: 30,
          env: true,
          attack: 0.6,
          decay: 0.5,
          sustain: 0.8,
          release: 1.0),
      'Пэд'),
  InstrumentSpec.osc(
      OscParams(
          shape: [2, 2, 1],
          coarse: [0, 12, -12],
          mix2: 20,
          mix3: 20,
          env: true,
          attack: 0,
          decay: 0.1,
          sustain: 0.6,
          release: 0.05),
      'Чиптюн'),
  InstrumentSpec.osc(
      OscParams(
          shape: [0, 0, 1],
          coarse: [12, 19, 24],
          mix2: 50,
          mix3: 20,
          env: true,
          attack: 0,
          decay: 0.9,
          sustain: 0,
          release: 0.6),
      'Колокольчик'),
  InstrumentSpec.osc(
      OscParams(
          shape: [4, 4, 0],
          coarse: [-12, -12, -24],
          fine: [0, 12, 0],
          mix2: 64,
          mix3: 40,
          env: true,
          attack: 0.003,
          decay: 0.25,
          sustain: 0.3,
          release: 0.1),
      'Аналог-бас'),
];

/// General MIDI families (program / 8), Russian names for the picker.
const List<String> kGmFamilies = [
  'Пианино',
  'Хроматические',
  'Органы',
  'Гитары',
  'Басы',
  'Струнные',
  'Ансамбль, хор',
  'Медные',
  'Язычковые',
  'Флейты',
  'Синт-лиды',
  'Синт-пэды',
  'Синт-эффекты',
  'Этнические',
  'Перкуссия',
  'Звуковые эффекты',
];
