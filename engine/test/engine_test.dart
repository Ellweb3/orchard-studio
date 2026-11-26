import 'package:orchard_engine/orchard_engine.dart';
import 'package:test/test.dart';

void main() {
  test('engine starts, plays and reports position', () async {
    final e = OrchardEngine.start();
    expect(e.sampleRate, greaterThan(0));
    e.setChannel(0, sample: 0, vol: 0.78, pan: 0);
    e.setStep(0, 0, 0, 100);
    e.setMaster(0.0); // silent in CI
    e.setTempo(130);
    e.play(true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(e.position, greaterThan(0));
    e.play(false);
    e.dispose();
  });
}
