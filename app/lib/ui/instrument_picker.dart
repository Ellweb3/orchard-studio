import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';

import '../instruments.dart';
import 'theme.dart';

/// Bottom sheet: drums / synth (3x Osc) / instruments (SoundFont) / drum kits.
Future<InstrumentSpec?> pickInstrument(BuildContext context, OrchardEngine engine, {InstrumentSpec? current}) {
  return showModalBottomSheet<InstrumentSpec>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: double.infinity),
    backgroundColor: C.panel,
    builder: (c) => SizedBox(
      height: MediaQuery.of(c).size.height * 0.8,
      child: _Picker(engine: engine, current: current),
    ),
  );
}

class _Picker extends StatefulWidget {
  const _Picker({required this.engine, this.current});
  final OrchardEngine engine;
  final InstrumentSpec? current;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _family = 0;

  @override
  void initState() {
    super.initState();
    final cur = widget.current;
    final initial = switch (cur?.kind) {
      InstKind.osc => 1,
      InstKind.soundfont => cur!.bank >= 128 ? 3 : 2,
      _ => 0,
    };
    if (cur?.kind == InstKind.soundfont && cur!.bank < 128) _family = cur.program ~/ 8;
    _tabs = TabController(length: 4, vsync: this, initialIndex: initial);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Widget _tile(String label, InstrumentSpec spec, {IconData? icon, bool selected = false}) => SizedBox(
        width: 190,
        height: 60,
        child: FilledButton.tonal(
          key: ValueKey('inst:$label'),
          style: FilledButton.styleFrom(
            backgroundColor: selected ? C.accent : C.panelHi,
            foregroundColor: selected ? Colors.black : C.text,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          onPressed: () => Navigator.pop(context, spec),
          child: Row(children: [
            if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
            Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15))),
          ]),
        ),
      );

  Widget _grid(List<Widget> children) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 10, runSpacing: 10, children: children),
      );

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    final cur = widget.current;
    final presets = e.soundFontPresets;
    final melodic = presets.where((p) => p.bank == 0).toList();
    final kits = presets.where((p) => p.bank == 128).toList();
    bool isCur(InstrumentSpec s) =>
        cur != null &&
        cur.kind == s.kind &&
        switch (s.kind) {
          InstKind.sampler => cur.sample == s.sample,
          InstKind.osc => cur.label == s.label,
          InstKind.soundfont => cur.bank == s.bank && cur.program == s.program,
        };
    Widget noSf() => const Center(child: Text('Инструменты ещё загружаются…', style: TextStyle(color: C.textDim)));

    return Column(children: [
      TabBar(
        controller: _tabs,
        labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        tabs: const [
          Tab(icon: Icon(Icons.album), text: 'Ударные'),
          Tab(icon: Icon(Icons.graphic_eq), text: 'Синтезатор'),
          Tab(icon: Icon(Icons.piano), text: 'Инструменты'),
          Tab(icon: Icon(Icons.grid_view), text: 'Наборы ударных'),
        ],
      ),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _grid([
            for (var s = 0; s < kSounds.length; s++)
              _tile(kSounds[s], InstrumentSpec.sampler(s), selected: isCur(InstrumentSpec.sampler(s))),
          ]),
          _grid([for (final p in kOscPresets) _tile(p.label, p, icon: Icons.waves, selected: isCur(p))]),
          if (melodic.isEmpty)
            noSf()
          else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 220,
                child: ListView(children: [
                  for (var f = 0; f < kGmFamilies.length; f++)
                    ListTile(
                      selected: _family == f,
                      selectedTileColor: C.panelHi,
                      title: Text(kGmFamilies[f]),
                      onTap: () => setState(() => _family = f),
                    ),
                ]),
              ),
              Expanded(
                child: _grid([
                  for (final p in melodic.where((p) => p.program ~/ 8 == _family))
                    _tile(p.name, InstrumentSpec.soundfont(p.bank, p.program, p.name),
                        selected: isCur(InstrumentSpec.soundfont(p.bank, p.program, p.name))),
                ]),
              ),
            ]),
          if (kits.isEmpty)
            noSf()
          else
            _grid([
              for (final p in kits)
                _tile(p.name, InstrumentSpec.soundfont(p.bank, p.program, p.name),
                    icon: Icons.grid_view, selected: isCur(InstrumentSpec.soundfont(p.bank, p.program, p.name))),
            ]),
        ]),
      ),
    ]);
  }
}
