import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orchard_engine/orchard_engine.dart';

import 'project.dart';
import 'ui/channel_rack.dart';
import 'ui/mixer.dart';
import 'ui/playlist.dart';
import 'ui/engine_clock.dart';
import 'ui/theme.dart';
import 'ui/transport_bar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const OrchardApp());
}

class OrchardApp extends StatelessWidget {
  const OrchardApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Orchard',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const StudioPage(),
      );
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> with WidgetsBindingObserver {
  OrchardEngine? _engine;
  Project? _project;
  EngineClock? _clock;
  String? _error;
  int _view = 0; // 0 rack, 1 playlist, 2 mixer

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      final e = OrchardEngine.start();
      final p = Project(e);
      final clock = EngineClock(e);
      p.addListener(() => clock.playing = p.playing);
      _engine = e;
      _project = p;
      _clock = clock;
      p.restore();
      _loadSoundFont(e, p);
    } on EngineException catch (e) {
      _error = e.message;
    }
  }

  Future<void> _loadSoundFont(OrchardEngine e, Project p) async {
    try {
      final data = await rootBundle.load('assets/GeneralUser-GS.sf2');
      await e.loadSoundFont(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      if (mounted) p.soundFontReady();
    } catch (err) {
      debugPrint('SoundFont not loaded: $err');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // stop and save when the tablet goes to sleep / app is hidden
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _project?.stop();
      _project?.save();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.dispose();
    _project?.dispose();
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(body: Center(child: Text('Не удалось запустить звук:\n$_error', textAlign: TextAlign.center)));
    }
    final p = _project!;
    return Scaffold(
      body: SafeArea(
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.space) {
              p.togglePlay();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ListenableBuilder(
            listenable: p,
            builder: (context, _) => Column(children: [
              TransportBar(project: p, clock: _clock!),
              Container(
                color: C.bar,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(children: [
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, icon: Icon(Icons.view_list), label: Text('Channel rack')),
                      ButtonSegment(value: 1, icon: Icon(Icons.view_timeline), label: Text('Playlist')),
                      ButtonSegment(value: 2, icon: Icon(Icons.tune), label: Text('Mixer')),
                    ],
                    selected: {_view},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => setState(() => _view = v.first),
                  ),
                ]),
              ),
              Expanded(
                child: IndexedStack(index: _view, children: [
                  ChannelRack(project: p, clock: _clock!),
                  PlaylistView(project: p, clock: _clock!),
                  MixerView(project: p, clock: _clock!),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
