import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:orchard_engine/orchard_engine.dart';
import 'package:path_provider/path_provider.dart';

import 'instruments.dart';
import 'song.dart';

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

  /// Mixer insert (0 = master).
  int insert = 0;

  Map<String, dynamic> toJson() => {
        'inst': inst.toJson(),
        'name': name,
        'vol': vol,
        'pan': pan,
        'pitch': pitch,
        'mute': mute,
        'solo': solo,
        'insert': insert,
      };

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
      ..solo = j['solo'] as bool? ?? false
      ..insert = ((j['insert'] as num?)?.toInt() ?? 0).clamp(0, kMixerInserts - 1);
  }
}

/// The project: UI source of truth, mirrored into the Rust engine on every change.
class Project extends ChangeNotifier {
  Project(this.engine);

  /// The live engine (swapped for an offline one only inside [exportTrack]).
  OrchardEngine engine;

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

  /// Song mode (FL's SONG switch): the Playlist plays instead of the pattern.
  bool songMode = false;
  final List<ClipData> clips = [];
  final List<bool> trackMute = List.filled(kPlaylistTracks, false);
  final List<InsertData> inserts = List.generate(kMixerInserts, (_) => InsertData());

  Timer? _saveTimer;

  // ------------------------------------------------------------ engine sync
  void _syncChannel(int i) {
    final anySolo = channels.any((c) => c.solo);
    if (i >= channels.length) {
      engine.setChannel(i, vol: 0, pan: 0, used: false);
      return;
    }
    final c = channels[i];
    engine.setChannel(i,
        vol: c.vol, pan: c.pan, pitch: c.pitch, mute: c.mute || (anySolo && !c.solo), used: true, insert: c.insert);
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

  void _syncClips() =>
      engine.setClips([for (final c in clips) if (!trackMute[c.track]) c.toEngine()]);

  void _syncInsert(int i) {
    final ins = inserts[i];
    engine.setInsert(i, vol: i == 0 ? master : ins.vol, pan: ins.pan, mute: ins.mute);
  }

  void _syncFx(int i, int slot) {
    final f = inserts[i].fx[slot];
    engine.setFx(i, slot, f?.kind, f?.params);
    if (f != null && f.bypass) engine.setFxBypass(i, slot, true);
  }

  void syncAll() {
    engine
      ..setTempo(tempo)
      ..setSwing(swing)
      ..setMetronome(metronome)
      ..selectPattern(pattern)
      ..setSongMode(songMode);
    for (var i = 0; i < kMixerInserts; i++) {
      _syncInsert(i);
      for (var s = 0; s < kFxSlots; s++) {
        _syncFx(i, s);
      }
    }
    _syncClips();
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
    inserts[0].vol = master;
    _syncInsert(0);
    _changed();
  }

  // ---------------------------------------------------------------- song
  void setSongMode(bool on) {
    songMode = on;
    engine.setSongMode(on);
    _changed();
  }

  /// Bars the pattern takes (at least one).
  int patternBars(int p) => ((patternLength[p] + 15) ~/ 16).clamp(1, 4);

  ClipData? clipAt(int track, int bar) {
    for (final c in clips.reversed) {
      if (c.track == track && bar >= c.start && bar < c.end) return c;
    }
    return null;
  }

  ClipData addClip(int track, int bar, int pat) {
    final c = ClipData(track, bar, patternBars(pat), pat);
    clips.add(c);
    _syncClips();
    _changed();
    return c;
  }

  void removeClip(ClipData c) {
    clips.remove(c);
    _syncClips();
    _changed();
  }

  void clipChanged() {
    _syncClips();
    _changed();
  }

  void toggleTrackMute(int t) {
    trackMute[t] = !trackMute[t];
    _syncClips();
    _changed();
  }

  int get songBars => clips.fold(0, (m, c) => c.end > m ? c.end : m);

  // ---------------------------------------------------------------- mixer
  void updateInsert(int i, void Function(InsertData d) f) {
    f(inserts[i]);
    if (i == 0) master = inserts[0].vol;
    _syncInsert(i);
    _changed();
  }

  void setFx(int i, int slot, int? kind) {
    inserts[i].fx[slot] = kind == null ? null : FxData(kind);
    _syncFx(i, slot);
    _changed();
  }

  void setFxParam(int i, int slot, int param, double v) {
    final f = inserts[i].fx[slot];
    if (f == null) return;
    f.params[param] = v.clamp(0, 1);
    engine.setFxParam(i, slot, param, f.params[param]);
    _changed();
  }

  void setFxBypass(int i, int slot, bool b) {
    final f = inserts[i].fx[slot];
    if (f == null) return;
    f.bypass = b;
    engine.setFxBypass(i, slot, b);
    _changed();
  }

  /// Names of the channels routed to insert [i].
  String insertLabel(int i) {
    if (i == 0) return 'Master';
    final names = [for (final c in channels) if (c.insert == i) c.name];
    return names.isEmpty ? 'Insert $i' : names.join(', ');
  }

  int _freeInsert() {
    for (var i = 1; i < kMixerInserts; i++) {
      if (!channels.any((c) => c.insert == i)) return i;
    }
    return 0;
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
    channels.add(ChannelData(inst)..insert = _freeInsert());
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
        'version': 3,
        'songMode': songMode,
        'clips': clips.map((c) => c.toJson()).toList(),
        'trackMute': trackMute,
        'inserts': inserts.map((i) => i.toJson()).toList(),
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
    songMode = j['songMode'] as bool? ?? false;
    clips
      ..clear()
      ..addAll(((j['clips'] as List?) ?? const []).map((c) => ClipData.fromJson(c as List)).where(
          (c) => c.track < kPlaylistTracks && c.pattern < kMaxPatterns && c.len > 0 && c.start >= 0));
    final tm = (j['trackMute'] as List?) ?? const [];
    for (var t = 0; t < kPlaylistTracks; t++) {
      trackMute[t] = t < tm.length && tm[t] == true;
    }
    final ins = (j['inserts'] as List?) ?? const [];
    for (var i = 0; i < kMixerInserts; i++) {
      inserts[i] = InsertData();
      if (i < ins.length && ins[i] is Map) inserts[i].loadJson((ins[i] as Map).cast<String, dynamic>());
    }
    if (ins.isEmpty) inserts[0].vol = master;
    master = inserts[0].vol;
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
    for (var i = 0; i < channels.length; i++) {
      channels[i].insert = i + 1; // one insert per channel
    }
    // a starter song: the beat for 4 bars
    clips
      ..clear()
      ..add(ClipData(0, 0, 4, 0));
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

  // ---------------------------------------------------------------- export
  /// Renders the song (or [repeats] loops of the current pattern) with an
  /// offline engine to `Documents/Orchard/<name>.<wav or mp3>`. Returns the path.
  Future<String> exportTrack({
    required String name,
    required ExportFormat format,
    required bool song,
    int repeats = 1,
    void Function(double)? onProgress,
  }) async {
    final live = engine;
    final off = live.offline();
    final (wasMetro, wasSong) = (metronome, songMode);
    try {
      // replay the whole project into the offline engine
      engine = off;
      metronome = false;
      songMode = song;
      syncAll();
    } finally {
      engine = live;
      metronome = wasMetro;
      songMode = wasSong;
    }
    final ticks = song ? songBars * kTicksPerBar : patternTicks * repeats;
    final frames = (ticks * 60 / (tempo * kPpq) * 44100).round();
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/Orchard');
    await dir.create(recursive: true);
    final safe = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final path = '${dir.path}/${safe.isEmpty ? 'track' : safe}.${format.name}';
    try {
      off.play(true);
      await off.export(path, playFrames: frames, format: format, onProgress: onProgress);
    } finally {
      off.dispose();
    }
    return path;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
