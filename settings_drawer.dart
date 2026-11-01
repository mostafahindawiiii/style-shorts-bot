import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';

class SettingsDrawer extends StatefulWidget {
  const SettingsDrawer({super.key});
  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  late final TextEditingController _key;
  bool _hide = true;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: context.read<AppState>().apiKey);
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final t = Theme.of(context).textTheme;
    return Drawer(
      child: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Settings', style: t.headlineSmall),
          const SizedBox(height: 20),
          Text('Groq API key', style: t.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: _hide,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'gsk_…',
              helperText: 'Stored encrypted on this device. Free key: console.groq.com/keys',
              helperMaxLines: 2,
              suffixIcon: IconButton(
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
            onChanged: (v) => s.setApiKey(v),
          ),
          const SizedBox(height: 24),
          Text('Video resolution', style: t.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<OutputResolution>(
            segments: [for (final r in OutputResolution.values) ButtonSegment(value: r, label: Text(r.label))],
            selected: {s.resolution},
            onSelectionChanged: (v) => s.setResolution(v.first),
          ),
          const SizedBox(height: 6),
          Text('720p renders much faster on a phone.', style: t.bodySmall),
          const SizedBox(height: 24),
          Text('Theme', style: t.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('Auto')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Dark')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => s.setTheme(v.first),
          ),
        ]),
      ),
    );
  }
}
