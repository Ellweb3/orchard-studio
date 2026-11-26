import 'package:orchard_engine/orchard_engine.dart';

const int kPlaylistTracks = 8;
const int kPlaylistBars = 64;

/// A pattern clip on the Playlist, in bars.
class ClipData {
  ClipData(this.track, this.start, this.len, this.pattern);
  int track, start, len, pattern;

  int get end => start + len;
  EngineClip toEngine() => EngineClip(start * kTicksPerBar, len * kTicksPerBar, pattern);
  List<int> toJson() => [track, start, len, pattern];
  static ClipData fromJson(List<dynamic> j) =>
      ClipData((j[0] as num).toInt(), (j[1] as num).toInt(), (j[2] as num).toInt(), (j[3] as num).toInt());
}

/// Effect kinds, index = engine fx::FxKind.
class FxDef {
  const FxDef(this.name, this.params, this.defaults);
  final String name;
  final List<String> params;
  final List<double> defaults;
}

const List<FxDef> kFxDefs = [
  FxDef('Реверб', ['Размер', 'Глушение', 'Wet', 'Dry', 'Ширина'], [0.6, 0.4, 0.3, 1.0, 1.0, 0.0]),
  FxDef('Эхо', ['Время', 'Повторы', 'Wet', 'Dry', 'Пинг-понг'], [0.125, 0.4, 0.35, 1.0, 1.0, 0.0]),
  FxDef('Фильтр', ['Частота', 'Резонанс', 'Тип', 'Микс'], [0.6, 0.2, 0.0, 1.0, 0.0, 0.0]),
  FxDef('Дисторшн', ['Драйв', 'Тон', 'Микс', 'Выход'], [0.4, 0.7, 1.0, 0.7, 0.0, 0.0]),
  FxDef('Компрессор', ['Порог', 'Ratio', 'Атака', 'Релиз', 'Усиление'], [0.6, 0.4, 0.2, 0.4, 0.2, 0.0]),
];

class FxData {
  FxData(this.kind, [List<double>? params]) : params = List.of(params ?? kFxDefs[kind].defaults);
  final int kind;
  final List<double> params;
  bool bypass = false;

  Map<String, dynamic> toJson() => {'k': kind, 'p': params, 'b': bypass};
  static FxData fromJson(Map<String, dynamic> j) {
    final k = ((j['k'] as num?)?.toInt() ?? 0).clamp(0, kFxDefs.length - 1);
    final p = (j['p'] as List?)?.map((e) => (e as num).toDouble()).toList();
    return FxData(k, p != null && p.length == kFxParams ? p : null)..bypass = j['b'] as bool? ?? false;
  }
}

class InsertData {
  double vol = 0.8; // fader, 0.8 = 0 dB (FL)
  double pan = 0;
  bool mute = false;
  final List<FxData?> fx = List.filled(kFxSlots, null);

  Map<String, dynamic> toJson() => {'v': vol, 'p': pan, 'm': mute, 'fx': fx.map((f) => f?.toJson()).toList()};
  void loadJson(Map<String, dynamic> j) {
    vol = (j['v'] as num?)?.toDouble() ?? 0.8;
    pan = (j['p'] as num?)?.toDouble() ?? 0;
    mute = j['m'] as bool? ?? false;
    final list = (j['fx'] as List?) ?? const [];
    for (var s = 0; s < kFxSlots; s++) {
      fx[s] = s < list.length && list[s] != null ? FxData.fromJson((list[s] as Map).cast<String, dynamic>()) : null;
    }
  }
}
