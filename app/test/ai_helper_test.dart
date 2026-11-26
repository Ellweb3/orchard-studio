import 'package:flutter_test/flutter_test.dart';
import 'package:magenta_music/magenta_music.dart';
import 'package:orchardtab/ai_helper.dart';

List<MagentaNote> hits(int pitch, Iterable<int> steps) => [for (final s in steps) MagentaNote(s, s + 1, pitch)];

void main() {
  test('a real beat outscores a kick flood and an empty pattern', () {
    final good = [
      ...hits(36, [0, 8, 16, 24]),
      ...hits(38, [4, 12, 20, 28]),
      ...hits(42, [for (var s = 0; s < 32; s += 2) s]),
    ];
    final flood = hits(36, List.generate(30, (i) => i));
    final sparse = hits(42, [3]);
    expect(AiHelper.beatScore(good, 32), greaterThan(AiHelper.beatScore(flood, 32)));
    expect(AiHelper.beatScore(good, 32), greaterThan(AiHelper.beatScore(sparse, 32)));
  });

  test('melody score prefers a singable line', () {
    final tune = [for (var i = 0; i < 8; i++) MagentaNote(i * 4, i * 4 + 3, 60 + (i % 5) * 2)];
    final wild = [for (var i = 0; i < 30; i++) MagentaNote(i, i + 1, 24 + i * 3)];
    expect(AiHelper.melodyScore(tune, 32), greaterThan(AiHelper.melodyScore(wild, 32)));
  });

  test('boldness maps to a sane temperature range', () {
    expect(AiHelper.vaeTemperature(0.3), closeTo(0.3, 1e-9));
    expect(AiHelper.vaeTemperature(1.6), closeTo(1.1, 1e-9));
  });
}
