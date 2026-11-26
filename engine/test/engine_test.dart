import 'dart:io';

import 'package:orchard_engine/orchard_engine.dart';
import 'package:test/test.dart';

void main() {
  test('engine starts, plays notes on every instrument type', () async {
    final e = OrchardEngine.start();
    expect(e.sampleRate, greaterThan(0));
    e.setMaster(0.0); // silent while testing
    e.setSampler(0, 0);
    e.setChannel(0, vol: 0.78, pan: 0);
    e.setNotes(0, 0, const [EngineNote(0, 0, 60, 100)]);
    e.setOsc(1, const OscParams(shape: [3, 3, 2], env: true, attack: 0.01, decay: 0.1, sustain: 0.5, release: 0.1));
    e.setChannel(1, vol: 0.78, pan: 0);
    e.setNotes(0, 1, const [EngineNote(0, 96, 60, 100), EngineNote(96, 48, 64, 100)]);

    final sf = File('../app/assets/GeneralUser-GS.sf2');
    if (sf.existsSync()) {
      await e.loadSoundFont(sf.readAsBytesSync());
      expect(e.soundFontPresets.length, greaterThan(200));
      expect(e.soundFontPresets.first.program, 0);
      expect(e.setSoundFont(2, 0, 0), isTrue);
      e.setChannel(2, vol: 0.78, pan: 0);
      e.setNotes(0, 2, const [EngineNote(0, 96, 60, 100)]);
    }
    e.setInsert(1, vol: 0.8, pan: 0);
    e.setFx(1, 0, 0); // reverb
    e.setFxParam(1, 0, 2, 0.5);
    e.setClips(const [EngineClip(0, kTicksPerBar, 0)]);
    e.setTempo(130);
    e.play(true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(e.position, greaterThan(0));
    e.setSongMode(true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(e.position, greaterThan(0));
    // peaks are measured before the master fader
    expect(e.takePeak(0) + e.takePeak(1), greaterThan(0));
    e.play(false);
    e.collect();
    e.dispose();
  });
}
