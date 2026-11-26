import 'dart:async';
import 'dart:io';

import 'package:magenta_music/magenta_music.dart';
import 'package:orchard_engine/orchard_engine.dart';
import 'package:path_provider/path_provider.dart';

import 'instruments.dart';
import 'project.dart';

/// GM drum pitches Magenta uses -> our starter-kit samples (drumkit.rs ids).
const Map<int, int> kDrumToSample = {36: 0, 38: 4, 42: 2, 46: 3};

/// Chord progressions offered for "melody over chords".
const List<List<String>> kProgressions = [
  ['C', 'G', 'Am', 'F'],
  ['Am', 'F', 'C', 'G'],
  ['C', 'Am', 'F', 'G'],
  ['Dm', 'G', 'C', 'Am'],
  ['Em', 'C', 'G', 'D'],
  ['F', 'G', 'Em', 'Am'],
];

/// The "Помощник": Magenta models applied to the project. Every action
/// snapshots the project first so [undo] can take it back.
class AiHelper {
  AiHelper(this.p);

  final Project p;
  final Map<MagentaModel, Future<Object>> _models = {};
  Map<String, dynamic>? _undo;

  bool get canUndo => _undo != null;

  Future<Directory> _cache() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/magenta');
    await d.create(recursive: true);
    return d;
  }

  Future<bool> isReady(MagentaModel m) async => MagentaModels.isReady(m, await _cache());

  Future<T> _model<T>(MagentaModel m, void Function(double)? onDownload) {
    return (_models[m] ??= () async {
      try {
        final dir = await MagentaModels.ensure(m, await _cache(), onProgress: onDownload);
        return m.name.endsWith('Vae') ? await MusicVae.load(dir) as Object : await MusicRnn.load(dir);
      } catch (_) {
        _models.remove(m); // allow a retry (e.g. no internet the first time)
        rethrow;
      }
    }())
        .then((o) => o as T);
  }

  void _snapshot() => _undo = p.toJson();

  void undo() {
    final s = _undo;
    if (s == null) return;
    _undo = null;
    final wasPlaying = p.playing;
    if (wasPlaying) p.stop();
    p.loadJson(s);
    if (wasPlaying) p.togglePlay();
  }

  // ------------------------------------------------------------ drums
  /// Drum hits of pattern [pat] as Magenta notes (steps), from the kit
  /// channels and GM drum-kit channels.
  List<MagentaNote> drumsOf(int pat) {
    final out = <MagentaNote>[];
    for (var c = 0; c < p.channels.length; c++) {
      final inst = p.channels[c].inst;
      for (final n in p.notes[pat][c]) {
        final step = n.pos ~/ kTicksPerStep;
        if (inst.kind == InstKind.sampler) {
          final gm = kDrumToSample.entries.where((e) => e.value == inst.sample).map((e) => e.key).firstOrNull;
          if (gm != null) out.add(MagentaNote(step, step + 1, gm));
        } else if (inst.kind == InstKind.soundfont && inst.bank >= 128) {
          out.add(MagentaNote(step, step + 1, n.key));
        }
      }
    }
    return out;
  }

  /// Writes drum hits into pattern [pat]: kick / snare / hats on the starter
  /// kit channels, everything else on a GM drum kit (SoundFont) channel.
  void _writeDrums(int pat, List<MagentaNote> hits, int steps) {
    final byChannel = <int, List<NoteData>>{};
    for (final h in hits) {
      final sample = kDrumToSample[h.pitch];
      final int ch;
      final int key;
      if (sample != null) {
        ch = p.ensureSamplerChannel(sample);
        key = kStepKey;
      } else {
        if (!p.engine.hasSoundFont) continue;
        ch = p.ensureChannel(
            (c) => c.kind == InstKind.soundfont && c.bank >= 128, const InstrumentSpec.soundfont(128, 0, 'Ударная установка'));
        key = h.pitch;
      }
      if (ch < 0) continue;
      (byChannel[ch] ??= []).add(NoteData(h.start * kTicksPerStep, 0, key));
    }
    p.setPatternLengthOf(pat, steps);
    for (var c = 0; c < p.channels.length; c++) {
      if (_isDrumChannel(c)) p.replaceNotes(pat, c, byChannel[c] ?? const []);
    }
  }

  bool _isDrumChannel(int c) {
    final i = p.channels[c].inst;
    return (i.kind == InstKind.sampler && kDrumToSample.containsValue(i.sample)) ||
        (i.kind == InstKind.soundfont && i.bank >= 128);
  }

  int _targetPattern() => p.firstEmptyPattern() ?? (p.pattern + 1) % kMaxPatterns;

  Future<void> _toNewPattern(Future<List<MagentaNote>> Function() make, int steps) async {
    final hits = await make();
    _snapshot();
    final pat = _targetPattern();
    _writeDrums(pat, hits, steps);
    p.selectPattern(pat);
  }

  /// How much a drum sequence sounds like a usable beat (higher is better):
  /// kick on the one, backbeat snare / clap, some hats, no flooded voice.
  static double beatScore(List<MagentaNote> hits, int steps) {
    final byPitch = <int, Set<int>>{};
    for (final h in hits) {
      (byPitch[h.pitch] ??= {}).add(h.start);
    }
    final kick = byPitch[36] ?? const {};
    final snare = {...?byPitch[38], ...?byPitch[39]};
    final hats = {...?byPitch[42], ...?byPitch[46], ...?byPitch[51]};
    var score = 0.0;
    if (kick.contains(0)) score += 3;
    if (kick.length >= 2 && kick.length <= steps ~/ 3) score += 2;
    for (var bar = 0; bar < steps; bar += 16) {
      if (snare.contains(bar + 4)) score += 1;
      if (snare.contains(bar + 12)) score += 1;
    }
    if (snare.length >= 2 && snare.length <= steps ~/ 3) score += 1;
    if (hats.length >= steps ~/ 8) score += 2;
    for (final s in byPitch.values) {
      if (s.length > steps * 3 ~/ 4) score -= 4; // a voice on (almost) every step
    }
    if (hits.length < steps ~/ 4) score -= 2;
    return score;
  }

  /// Best of [n] samples by [score].
  static Future<List<MagentaNote>> _bestOf(
      int n, Future<List<MagentaNote>> Function() make, double Function(List<MagentaNote>) score) async {
    List<MagentaNote>? best;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      final c = await make();
      final s = score(c);
      if (s > bestScore) {
        best = c;
        bestScore = s;
      }
    }
    return best!;
  }

  /// UI boldness (0.3..1.6) -> VAE temperature (0.3..1.1).
  static double vaeTemperature(double boldness) => (0.3 + (boldness - 0.3) * 0.8 / 1.3).clamp(0.3, 1.1);

  Future<void> newBeat({double temperature = 1.0, void Function(double)? onDownload}) async {
    final vae = await _model<MusicVae>(MagentaModel.drumsVae, onDownload);
    final t = vaeTemperature(temperature);
    await _toNewPattern(
        () => _bestOf(8, () => vae.sample(temperature: t), (h) => beatScore(h, vae.steps)), vae.steps);
  }

  Future<void> varyBeat({double amount = 0.5, void Function(double)? onDownload}) async {
    final vae = await _model<MusicVae>(MagentaModel.drumsVae, onDownload);
    final src = _fit(drumsOf(p.pattern), p.patternLength[p.pattern], vae.steps);
    await _toNewPattern(
        () => _bestOf(4, () => vae.similar(src, amount: amount), (h) => beatScore(h, vae.steps)), vae.steps);
  }

  Future<void> continueBeat({double temperature = 1.0, void Function(double)? onDownload}) async {
    final rnn = await _model<MusicRnn>(MagentaModel.drumKitRnn, onDownload);
    final len = p.patternLength[p.pattern].clamp(1, 32);
    final primer = drumsOf(p.pattern).where((n) => n.start < len).toList();
    final total = len <= 16 ? 32 : 64;
    await _toNewPattern(() async {
      final cont = await rnn.continueSequence(primer, primerSteps: len, steps: total - len, temperature: temperature);
      return [...primer, ...cont];
    }, total);
  }

  Future<void> mixBeats(int a, int b, {double alpha = 0.5, void Function(double)? onDownload}) async {
    final vae = await _model<MusicVae>(MagentaModel.drumsVae, onDownload);
    final da = _fit(drumsOf(a), p.patternLength[a], vae.steps);
    final db = _fit(drumsOf(b), p.patternLength[b], vae.steps);
    await _toNewPattern(() => vae.interpolate(da, db, alpha: alpha), vae.steps);
  }

  /// Loops (or cuts) a pattern of [len] steps to exactly [steps] steps.
  List<MagentaNote> _fit(List<MagentaNote> notes, int len, int steps) {
    final out = <MagentaNote>[];
    for (var off = 0; off < steps; off += len) {
      for (final n in notes) {
        final s = n.start + off;
        if (s < steps) out.add(MagentaNote(s, (n.end + off).clamp(s + 1, steps), n.pitch));
      }
    }
    return out;
  }

  // ------------------------------------------------------------ melody
  /// Melodic channels (piano roll instruments) a melody can go to.
  List<int> melodicChannels() => [
        for (var c = 0; c < p.channels.length; c++)
          if (p.channels[c].inst.melodic) c,
      ];

  /// Channel for a new melody: [preferred] if melodic, else a new piano.
  int _melodyChannel(int? preferred) {
    if (preferred != null && preferred < p.channels.length && p.channels[preferred].inst.melodic) return preferred;
    return p.ensureChannel((c) => c.kind == InstKind.soundfont && c.bank == 0 && c.program == 0,
        const InstrumentSpec.soundfont(0, 0, 'Piano'));
  }

  List<MagentaNote> melodyOf(int pat, int ch) => [
        for (final n in p.notes[pat][ch])
          MagentaNote(n.pos ~/ kTicksPerStep, (n.pos + (n.len == 0 ? kTicksPerStep : n.len)) ~/ kTicksPerStep, n.key),
      ];

  void _writeMelody(int ch, List<MagentaNote> notes, int steps) {
    p.setPatternLengthOf(p.pattern, steps.clamp(p.patternLength[p.pattern], kMaxSteps));
    p.replaceNotes(p.pattern, ch, [
      for (final n in notes)
        if (n.start < kMaxSteps)
          NoteData(n.start * kTicksPerStep, (n.end.clamp(n.start + 1, kMaxSteps) - n.start) * kTicksPerStep, n.pitch),
    ]);
  }

  /// A singable melody: enough notes, not a flood, a compact range.
  static double melodyScore(List<MagentaNote> m, int steps) {
    if (m.isEmpty) return -10;
    final pitches = m.map((n) => n.pitch).toList();
    final range = pitches.reduce((a, b) => a > b ? a : b) - pitches.reduce((a, b) => a < b ? a : b);
    var score = 0.0;
    if (m.length >= steps ~/ 8 && m.length <= steps * 3 ~/ 4) score += 3;
    if (range <= 15) score += 2;
    if (m.first.start == 0) score += 1;
    score -= (m.where((n) => n.pitch < 48 || n.pitch > 84).length) * 0.5;
    return score;
  }

  Future<int> newMelody({int? channel, double temperature = 1.0, void Function(double)? onDownload}) async {
    final vae = await _model<MusicVae>(MagentaModel.melodyVae, onDownload);
    final t = vaeTemperature(temperature);
    final notes = await _bestOf(6, () => vae.sample(temperature: t), (m) => melodyScore(m, vae.steps));
    _snapshot();
    final ch = _melodyChannel(channel);
    _writeMelody(ch, notes, vae.steps);
    return ch;
  }

  Future<int> continueMelody({required int channel, double temperature = 1.0, void Function(double)? onDownload}) async {
    final rnn = await _model<MusicRnn>(MagentaModel.melodyRnn, onDownload);
    final len = p.patternLength[p.pattern];
    final primer = melodyOf(p.pattern, channel).where((n) => n.start < len).toList();
    if (primer.isEmpty) throw StateError('В канале нет нот: сначала нарисуй начало мелодии в Piano roll');
    final last = primer.map((n) => n.end).reduce((a, b) => a > b ? a : b).clamp(1, kMaxSteps - 1);
    final total = (last <= 16 ? 32 : 64).clamp(last + 1, kMaxSteps);
    final cont = await rnn.continueSequence(primer, primerSteps: last, steps: total - last, temperature: temperature);
    _snapshot();
    _writeMelody(channel, [...primer, ...cont], total);
    return channel;
  }

  /// ImprovRNN melody over [chords] (2 bars, one chord per half bar) plus a
  /// sustained chord channel.
  Future<int> melodyOverChords(List<String> chords,
      {int? channel, double temperature = 1.0, void Function(double)? onDownload}) async {
    final rnn = await _model<MusicRnn>(MagentaModel.improvRnn, onDownload);
    const steps = 32;
    // ImprovRNN needs a primer step; generate from step 1 and shift back.
    final raw = await rnn.continueSequence(const [], primerSteps: 1, steps: steps, chords: chords, temperature: temperature);
    final notes = [for (final n in raw) MagentaNote(n.start - 1, n.end - 1, n.pitch)];
    _snapshot();
    final ch = _melodyChannel(channel);
    _writeMelody(ch, notes, steps);
    // chords: one held triad per chord, an octave below the melody
    final padCh = p.ensureChannel((c) => c.kind == InstKind.soundfont && c.bank == 0 && c.program == 48,
        const InstrumentSpec.soundfont(0, 48, 'Аккорды'));
    final per = steps ~/ chords.length;
    final pad = <NoteData>[];
    for (var i = 0; i < chords.length; i++) {
      for (final pc in _chordPitchClasses(chords[i])) {
        pad.add(NoteData(i * per * kTicksPerStep, per * kTicksPerStep, 48 + pc, 80));
      }
    }
    p.replaceNotes(p.pattern, padCh, pad);
    return ch;
  }

  static List<int> _chordPitchClasses(String sym) {
    const roots = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
    var root = roots[sym[0].toUpperCase()] ?? 0;
    var rest = sym.substring(1);
    if (rest.startsWith('#')) {
      root++;
      rest = rest.substring(1);
    } else if (rest.startsWith('b')) {
      root--;
      rest = rest.substring(1);
    }
    final minor = rest.startsWith('m') && !rest.startsWith('maj');
    return [root % 12, (root + (minor ? 3 : 4)) % 12, (root + 7) % 12];
  }

  void dispose() {
    for (final f in _models.values) {
      f.then((m) {
        if (m is MusicVae) m.dispose();
        if (m is MusicRnn) m.dispose();
      }).ignore();
    }
  }
}
