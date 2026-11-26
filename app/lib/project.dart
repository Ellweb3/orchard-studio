import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:orchard_engine/orchard_engine.dart';
import 'package:path_provider/path_provider.dart';

const double kDefaultVolume = 100 / 128; // FL default channel volume (-5.2 dB)
const int kDefaultVelocity = 100;

class ChannelData {
  ChannelData({required this.sample, String? name, this.vol = kDefaultVolume, this.pan = 0, this.pitch = 0})
      : name = name ?? kSounds[sample];

  int sample;
  String name;
  double vol;
  double pan;
  double pitch;
  bool mute = false;
  bool solo = false;

  Map<String, dynamic> toJson() =>
      {'sample': sample, 'name': name, 'vol': vol, 'pan': pan, 'pitch': pitch, 'mute': mute, 'solo': solo};

  factory ChannelData.fromJson(Map<String, dynamic> j) => ChannelData(
        sample: (j['sample'] as num).toInt().clamp(0, kSounds.length - 1),
        name: j['name'] as String?,
        vol: (j['vol'] as num?)?.toDouble() ?? kDefaultVolume,
        pan: (j['pan'] as num?)?.toDouble() ?? 0,
        pitch: (j['pitch'] as num?)?.toDouble() ?? 0,
      )
        ..mute = j['mute'] as bool? ?? false
        ..solo = j['solo'] as bool? ?? false;
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

  /// steps[pat][ch][step] = velocity, 0 = off. Rows follow [channels].
  final List<List<List<int>>> steps =
      List.generate(kMaxPatterns, (_) => List.generate(kMaxChannels, (_) => List.filled(kMaxSteps, 0)));

  Timer? _saveTimer;

  // ------------------------------------------------------------ engine sync
  void _syncChannel(int i) {
    final anySolo = channels.any((c) => c.solo);
    if (i >= channels.length) {
      engine.setChannel(i, sample: 0, vol: 0, pan: 0, used: false);
      return;
    }
    final c = channels[i];
    engine.setChannel(i,
        sample: c.sample, vol: c.vol, pan: c.pan, pitch: c.pitch, mute: c.mute || (anySolo && !c.solo), used: true);
  }

  void _syncAllChannels() {
    for (var i = 0; i < kMaxChannels; i++) {
      _syncChannel(i);
    }
  }

  void _syncSteps() {
    for (var p = 0; p < kMaxPatterns; p++) {
      engine.setPatternLength(p, patternLength[p]);
      for (var c = 0; c < kMaxChannels; c++) {
        for (var s = 0; s < kMaxSteps; s++) {
          engine.setStep(p, c, s, steps[p][c][s]);
        }
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
    _syncAllChannels();
    _syncSteps();
  }

  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), save);
  }

  // ---------------------------------------------------------------- actions
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

  void setPatternLength(int steps) {
    patternLength[pattern] = steps;
    engine.setPatternLength(pattern, steps);
    _changed();
  }

  void clearPattern() {
    for (final row in steps[pattern]) {
      row.fillRange(0, kMaxSteps, 0);
    }
    engine.clearPattern(pattern);
    _changed();
  }

  int step(int ch, int s) => steps[pattern][ch][s];

  void setStep(int ch, int s, bool on) {
    final vel = on ? kDefaultVelocity : 0;
    if (steps[pattern][ch][s] == vel) return;
    steps[pattern][ch][s] = vel;
    engine.setStep(pattern, ch, s, vel);
    _changed();
  }

  bool get canAddChannel => channels.length < kMaxChannels;

  void addChannel(int sample) {
    if (!canAddChannel) return;
    channels.add(ChannelData(sample: sample));
    _syncChannel(channels.length - 1);
    _changed();
  }

  void removeChannel(int i) {
    channels.removeAt(i);
    for (final pat in steps) {
      pat.removeAt(i);
      pat.add(List.filled(kMaxSteps, 0));
    }
    _syncAllChannels();
    _syncSteps();
    _changed();
  }

  void updateChannel(int i, void Function(ChannelData c) f) {
    f(channels[i]);
    // solo/mute change affects every channel's effective mute
    _syncAllChannels();
    _changed();
  }

  void preview(int ch) => engine.preview(ch);

  // ----------------------------------------------------------- persistence
  Map<String, dynamic> toJson() => {
        'version': 1,
        'tempo': tempo,
        'swing': swing,
        'master': master,
        'metronome': metronome,
        'pattern': pattern,
        'patternLength': patternLength,
        'channels': channels.map((c) => c.toJson()).toList(),
        // sparse: [pat, ch, step, vel]
        'steps': [
          for (var p = 0; p < kMaxPatterns; p++)
            for (var c = 0; c < channels.length; c++)
              for (var s = 0; s < kMaxSteps; s++)
                if (steps[p][c][s] > 0) [p, c, s, steps[p][c][s]],
        ],
      };

  void loadJson(Map<String, dynamic> j) {
    tempo = (j['tempo'] as num?)?.toDouble() ?? 130;
    swing = (j['swing'] as num?)?.toDouble() ?? 0;
    master = (j['master'] as num?)?.toDouble() ?? 0.8;
    metronome = j['metronome'] as bool? ?? false;
    pattern = (j['pattern'] as num?)?.toInt() ?? 0;
    final lens = (j['patternLength'] as List?)?.cast<num>() ?? const [];
    for (var p = 0; p < kMaxPatterns; p++) {
      patternLength[p] = p < lens.length ? lens[p].toInt().clamp(1, kMaxSteps) : 16;
    }
    channels
      ..clear()
      ..addAll(((j['channels'] as List?) ?? const [])
          .take(kMaxChannels)
          .map((c) => ChannelData.fromJson((c as Map).cast<String, dynamic>())));
    for (final pat in steps) {
      for (final row in pat) {
        row.fillRange(0, kMaxSteps, 0);
      }
    }
    for (final e in (j['steps'] as List?) ?? const []) {
      final v = (e as List).cast<num>().map((n) => n.toInt()).toList();
      if (v.length == 4 && v[0] < kMaxPatterns && v[1] < kMaxChannels && v[2] < kMaxSteps) {
        steps[v[0]][v[1]][v[2]] = v[3].clamp(0, 128);
      }
    }
    syncAll();
    notifyListeners();
  }

  /// FL's new-project rack: Kick, Clap, Hat, Snare with a starter beat.
  void loadDefault() {
    channels
      ..clear()
      ..addAll([ChannelData(sample: 0), ChannelData(sample: 1), ChannelData(sample: 2), ChannelData(sample: 4)]);
    for (final s in [0, 4, 8, 12]) {
      steps[0][0][s] = kDefaultVelocity;
    }
    for (final s in [4, 12]) {
      steps[0][1][s] = kDefaultVelocity;
    }
    for (final s in [2, 6, 10, 14]) {
      steps[0][2][s] = kDefaultVelocity;
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
