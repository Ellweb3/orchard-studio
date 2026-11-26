import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:orchard_engine/orchard_engine.dart';
import 'package:path_provider/path_provider.dart';

import 'instruments.dart';

const double kDefaultVolume = 100 / 128; // FL default channel volume (-5.2 dB)
const int kDefaultVelocity = 100;
const int kStepKey = 60; // steps are notes on C5 (FL)

class NoteData {
  NoteData(this.pos, this.len, this.key, [this.vel = kDefaultVelocity]);
  int pos, len, key, vel;

  int get end => pos + (len == 0 ? kTicksPerStep : len);
  EngineNote toEngine() => EngineNote(pos, len, key, vel);
  List<int> toJson() => [pos, len, key, vel];
  static NoteData fromJson(List<dynamic> j) =>
      NoteData((j[0] as num).toInt(), (j[1] as num).toInt(), (j[2] as num).toInt(), (j[3] as num).toInt());
}

class ChannelData {
  ChannelData(this.inst, {String? name, this.vol = kDefaultVolume, this.pan = 0, this.pitch = 0})
      : name = name ?? inst.name;

  InstrumentSpec inst;
  String name;
  double vol;
  double pan;
  double pitch;
  bool mute = false;
  bool solo = false;

  Map<String, dynamic> toJson() =>
      {'inst': inst.toJson(), 'name': name, 'vol': vol, 'pan': pan, 'pitch': pitch, 'mute': mute, 'solo': solo};

  factory ChannelData.fromJson(Map<String, dynamic> j) {
    // v1 files: {'sample': n}
    final inst = j['inst'] != null
        ? InstrumentSpec.fromJson((j['inst'] as Map).cast<String, dynamic>())
        : InstrumentSpec.sampler(((j['sample'] as num?)?.toInt() ?? 0).clamp(0, kSounds.length - 1));
    return ChannelData(
      inst,
      name: j['name'] as String?,
      vol: (j['vol'] as num?)?.toDouble() ?? kDefaultVolume,
      pan: (j['pan'] as num?)?.toDouble() ?? 0,
      pitch: (j['pitch'] as num?)?.toDouble() ?? 0,
    )
      ..mute = j['mute'] as bool? ?? false
      ..solo = j['solo'] as bool? ?? false;
  }
}

/// The project: UI source of truth, mirrored into the Rust engine on every change.
class Project extends ChangeNotifier {
  Project(this.engine);

  final OrchardEngine engine;

  double tempo = 130;
  double swing = 0;
  double master = 0.8;
  bool metronome = false;
  bool playing = false;
  int pattern = 0;
  final List<int> patternLength = List.filled(kMaxPatterns, 16);
  final List<ChannelData> channels = [];

  /// notes[pat][ch]. Rows follow [channels].
  final List<List<List<NoteData>>> notes =
      List.generate(kMaxPatterns, (_) => List.generate(kMaxChannels, (_) => <NoteData>[]));

  Timer? _saveTimer;

  // ------------------------------------------------------------ engine sync
  void _syncChannel(int i) {
    final anySolo = channels.any((c) => c.solo);
    if (i >= channels.length) {
      engine.setChannel(i, vol: 0, pan: 0, used: false);
      return;
    }
    final c = channels[i];
    engine.setChannel(i, vol: c.vol, pan: c.pan, pitch: c.pitch, mute: c.mute || (anySolo && !c.solo), used: true);
  }

  void _syncAllChannels() {
    for (var i = 0; i < kMaxChannels; i++) {
      _syncChannel(i);
    }
  }

  void _syncInstrument(int i) {
    if (i < channels.length) channels[i].inst.applyTo(engine, i);
  }

  void _pushNotes(int pat, int ch) => engine.setNotes(pat, ch, [for (final n in notes[pat][ch]) n.toEngine()]);

  void _syncNotes() {
    for (var p = 0; p < kMaxPatterns; p++) {
      engine.setPatternLength(p, patternLength[p]);
      for (var c = 0; c < kMaxChannels; c++) {
        _pushNotes(p, c);
      }
    }
  }

  void syncAll() {
    engine
      ..setTempo(tempo)
      ..setSwing(swing)
      ..setMaster(master)
      ..setMetronome(metronome)
      ..selectPattern(pattern);
    for (var i = 0; i < channels.length; i++) {
      _syncInstrument(i);
    }
    _syncAllChannels();
    _syncNotes();
  }

  /// SoundFont channels restored before the .sf2 finished loading.
  void soundFontReady() {
    for (var i = 0; i < channels.length; i++) {
      if (channels[i].inst.kind == InstKind.soundfont) _syncInstrument(i);
    }
    notifyListeners();
  }

  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), save);
  }

  // ---------------------------------------------------------------- transport
  void togglePlay() {
    playing = !playing;
    engine.play(playing);
    notifyListeners();
  }

  void stop() {
    playing = false;
    engine.play(false);
    notifyListeners();
  }

  void setTempo(double v) {
    tempo = v.clamp(40, 300).roundToDouble();
    engine.setTempo(tempo);
    _changed();
  }

  void setSwing(double v) {
    swing = v.clamp(0, 1);
    engine.setSwing(swing);
    _changed();
  }

  void setMaster(double v) {
    master = v.clamp(0, 1);
    engine.setMaster(master);
    _changed();
  }

  void toggleMetronome() {
    metronome = !metronome;
    engine.setMetronome(metronome);
    _changed();
  }

  void selectPattern(int p) {
    pattern = p;
    engine.selectPattern(p);
    _changed();
  }

  int get patternTicks => patternLength[pattern] * kTicksPerStep;

  void setPatternLength(int steps) {
    patternLength[pattern] = steps;
    engine.setPatternLength(pattern, steps);
    _changed();
  }

  void clearPattern() {
    for (var c = 0; c < kMaxChannels; c++) {
      notes[pattern][c].clear();
      _pushNotes(pattern, c);
    }
    _changed();
  }

  // ---------------------------------------------------------------- steps
  bool stepOn(int ch, int s) => notes[pattern][ch].any((n) => n.pos == s * kTicksPerStep);

  void setStep(int ch, int s, bool on) {
    if (stepOn(ch, s) == on) return;
    final list = notes[pattern][ch];
    if (on) {
      list.add(NoteData(s * kTicksPerStep, 0, kStepKey));
    } else {
      list.removeWhere((n) => n.pos == s * kTicksPerStep);
    }
    _pushNotes(pattern, ch);
    _changed();
  }

  /// Notes that are not plain steps: the rack shows a piano roll preview (FL).
  bool hasMelody(int ch) => notes[pattern][ch].any((n) => n.len > 0 || n.key != kStepKey);

  // ---------------------------------------------------------------- piano roll
  List<NoteData> channelNotes(int ch) => notes[pattern][ch];

  NoteData addNote(int ch, int pos, int len, int key) {
    final n = NoteData(pos, len, key);
    notes[pattern][ch].add(n);
    _pushNotes(pattern, ch);
    _changed();
    return n;
  }

  void removeNote(int ch, NoteData n) {
    notes[pattern][ch].remove(n);
    _pushNotes(pattern, ch);
    _changed();
  }

  void noteChanged(int ch) {
    _pushNotes(pattern, ch);
    _changed();
  }

  void clearChannel(int ch) {
    notes[pattern][ch].clear();
    _pushNotes(pattern, ch);
    _changed();
  }

  // ---------------------------------------------------------------- channels
  bool get canAddChannel => channels.length < kMaxChannels;

  void addChannel(InstrumentSpec inst) {
    if (!canAddChannel) return;
    channels.add(ChannelData(inst));
    final i = channels.length - 1;
    _syncInstrument(i);
    _syncChannel(i);
    _changed();
  }

  void removeChannel(int i) {
    channels.removeAt(i);
    for (final pat in notes) {
      pat.removeAt(i);
      pat.add(<NoteData>[]);
    }
    for (var c = i; c < kMaxChannels; c++) {
      _syncInstrument(c);
    }
    _syncAllChannels();
    _syncNotes();
    _changed();
  }

  void setInstrument(int i, InstrumentSpec inst) {
    final c = channels[i];
    if (c.name == c.inst.name) c.name = inst.name;
    c.inst = inst;
    _syncInstrument(i);
    _changed();
  }

  void updateChannel(int i, void Function(ChannelData c) f) {
    f(channels[i]);
    _syncAllChannels(); // solo / mute affect every channel's effective mute
    _changed();
  }

  void noteOn(int ch, int key) => engine.noteOn(ch, key);
  void noteOff(int ch, int key) => engine.noteOff(ch, key);

  /// Short audition (rack name tap, piano roll edits).
  void preview(int ch, [int key = kStepKey]) {
    engine.noteOn(ch, key);
    Timer(const Duration(milliseconds: 250), () => engine.noteOff(ch, key));
  }

  // ----------------------------------------------------------- persistence
  Map<String, dynamic> toJson() => {
        'version': 2,
        'tempo': tempo,
        'swing': swing,
        'master': master,
        'metronome': metronome,
        'pattern': pattern,
        'patternLength': patternLength,
        'channels': channels.map((c) => c.toJson()).toList(),
        'notes': [
          for (var p = 0; p < kMaxPatterns; p++)
            for (var c = 0; c < channels.length; c++)
              if (notes[p][c].isNotEmpty) {'p': p, 'c': c, 'n': notes[p][c].map((n) => n.toJson()).toList()},
        ],
      };

  void loadJson(Map<String, dynamic> j) {
    tempo = (j['tempo'] as num?)?.toDouble() ?? 130;
    swing = (j['swing'] as num?)?.toDouble() ?? 0;
    master = (j['master'] as num?)?.toDouble() ?? 0.8;
    metronome = j['metronome'] as bool? ?? false;
    pattern = ((j['pattern'] as num?)?.toInt() ?? 0).clamp(0, kMaxPatterns - 1);
    final lens = (j['patternLength'] as List?)?.cast<num>() ?? const [];
    for (var p = 0; p < kMaxPatterns; p++) {
      patternLength[p] = p < lens.length ? lens[p].toInt().clamp(1, kMaxSteps) : 16;
    }
    channels
      ..clear()
      ..addAll(((j['channels'] as List?) ?? const [])
          .take(kMaxChannels)
          .map((c) => ChannelData.fromJson((c as Map).cast<String, dynamic>())));
    for (final pat in notes) {
      for (final row in pat) {
        row.clear();
      }
    }
    for (final e in (j['notes'] as List?) ?? const []) {
      final m = (e as Map).cast<String, dynamic>();
      final p = (m['p'] as num).toInt(), c = (m['c'] as num).toInt();
      if (p < kMaxPatterns && c < kMaxChannels) {
        notes[p][c].addAll((m['n'] as List).map((n) => NoteData.fromJson(n as List)));
      }
    }
    // v1: sparse steps [pat, ch, step, vel]
    for (final e in (j['steps'] as List?) ?? const []) {
      final v = (e as List).cast<num>().map((n) => n.toInt()).toList();
      if (v.length == 4 && v[0] < kMaxPatterns && v[1] < kMaxChannels && v[2] < kMaxSteps) {
        notes[v[0]][v[1]].add(NoteData(v[2] * kTicksPerStep, 0, kStepKey, v[3]));
      }
    }
    syncAll();
    notifyListeners();
  }

  /// FL's new-project rack (Kick, Clap, Hat, Snare) with a starter beat, plus a piano.
  void loadDefault() {
    channels
      ..clear()
      ..addAll([
        ChannelData(const InstrumentSpec.sampler(0)),
        ChannelData(const InstrumentSpec.sampler(1)),
        ChannelData(const InstrumentSpec.sampler(2)),
        ChannelData(const InstrumentSpec.sampler(4)),
        ChannelData(const InstrumentSpec.soundfont(0, 0, 'Piano')),
      ]);
    for (final s in [0, 4, 8, 12]) {
      notes[0][0].add(NoteData(s * kTicksPerStep, 0, kStepKey));
    }
    for (final s in [4, 12]) {
      notes[0][1].add(NoteData(s * kTicksPerStep, 0, kStepKey));
    }
    for (final s in [2, 6, 10, 14]) {
      notes[0][2].add(NoteData(s * kTicksPerStep, 0, kStepKey));
    }
    syncAll();
    notifyListeners();
  }

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/orchard_project.json');
  }

  Future<void> save() async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()));
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('save failed: $e');
    }
  }

  Future<void> restore() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        loadJson((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
        if (channels.isNotEmpty) return;
      }
    } catch (e) {
      debugPrint('restore failed: $e');
    }
    loadDefault();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
