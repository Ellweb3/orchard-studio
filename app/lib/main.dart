import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orchard_engine/orchard_engine.dart';

import 'project.dart';
import 'ui/channel_rack.dart';
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

class _StudioPageState extends State<StudioPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  OrchardEngine? _engine;
  Project? _project;
  EngineClock? _clock;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      final e = OrchardEngine.start();
      final p = Project(e);
      final clock = EngineClock(e, this);
      p.addListener(() => clock.playing = p.playing);
      _engine = e;
      _project = p;
      _clock = clock;
      p.restore();
    } on EngineException catch (e) {
      _error = e.message;
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
              Expanded(child: ChannelRack(project: p, clock: _clock!)),
            ]),
          ),
        ),
      ),
    );
  }
}
