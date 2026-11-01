import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'settings_drawer.dart';
import 'video_preview.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Islamic Shorts Generator')),
      drawer: const SettingsDrawer(),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (s.apiKey.isEmpty)
            _Banner(
              icon: Icons.key,
              text: 'Open the menu (top-left) and add your Groq API key to get started.',
              color: Theme.of(context).colorScheme.tertiaryContainer,
            ),
          const _StyleCard(),
          const SizedBox(height: 12),
          const _AudioCard(),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: s.running || s.analyzingStyle || s.isRecording ? null : s.generate,
            icon: const Icon(Icons.auto_awesome),
            label: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Generate video')),
          ),
          const SizedBox(height: 16),
          if (s.running) const _ProgressCard(),
          if (s.error != null) _Banner(icon: Icons.error_outline, text: s.error!, color: Theme.of(context).colorScheme.errorContainer),
          if (s.info != null) _Banner(icon: Icons.check_circle_outline, text: s.info!, color: Theme.of(context).colorScheme.secondaryContainer),
          if (s.outputPath != null) const _ResultCard(),
        ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
        color: color,
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [Icon(icon), const SizedBox(width: 12), Expanded(child: Text(text))]),
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.subtitle, required this.child});
  final String title, subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.titleMedium),
          Text(subtitle, style: t.bodySmall),
          const SizedBox(height: 12),
          child,
        ]),
      ),
    );
  }
}

class _StyleCard extends StatelessWidget {
  const _StyleCard();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final busy = s.analyzingStyle || s.running;
    return _SectionCard(
      title: '1 · Style reference',
      subtitle: 'Icons are drawn to match this image or video.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 84,
              height: 84,
              color: s.style.bgColor,
              child: s.styleThumbPath != null
                  ? Image.file(File(s.styleThumbPath!), fit: BoxFit.cover)
                  : Icon(Icons.brush, color: s.style.fgColor),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _Swatch(s.style.bgColor),
                const SizedBox(width: 6),
                _Swatch(s.style.fgColor),
                const SizedBox(width: 8),
                Text(s.styleThumbPath == null ? 'Default style' : 'Custom style',
                    style: Theme.of(context).textTheme.labelLarge),
              ]),
              const SizedBox(height: 6),
              Text(s.style.prompt, maxLines: 4, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        if (s.analyzingStyle) const LinearProgressIndicator(),
        Wrap(spacing: 8, runSpacing: 4, children: [
          OutlinedButton.icon(onPressed: busy ? null : s.pickStyleImage, icon: const Icon(Icons.image), label: const Text('Image')),
          OutlinedButton.icon(onPressed: busy ? null : s.pickStyleVideo, icon: const Icon(Icons.videocam), label: const Text('Video')),
          TextButton(onPressed: busy ? null : s.useDefaultStyle, child: const Text('Use default')),
        ]),
      ]),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color);
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
      );
}

class _AudioCard extends StatelessWidget {
  const _AudioCard();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return _SectionCard(
      title: '2 · Audio',
      subtitle: 'Record a voice note or pick .mp3 / .wav / .m4a (max ~3 min after silence trimming).',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          FilledButton.tonalIcon(
            onPressed: s.running ? null : s.toggleRecording,
            icon: Icon(s.isRecording ? Icons.stop_circle : Icons.mic),
            label: Text(s.isRecording ? 'Stop recording' : 'Record'),
          ),
          OutlinedButton.icon(
            onPressed: s.running || s.isRecording ? null : s.pickAudio,
            icon: const Icon(Icons.audio_file),
            label: const Text('Pick file'),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Icon(s.isRecording ? Icons.fiber_manual_record : Icons.music_note,
              size: 18, color: s.isRecording ? Colors.red : null),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.isRecording ? 'Recording… tap stop when finished' : (s.audioName ?? 'No audio selected'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ]),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.status),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: s.progress <= 0 ? null : s.progress),
          const SizedBox(height: 6),
          Text('${(s.progress * 100).round()}%  ·  keep the app open while it renders',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          VideoPreview(path: s.outputPath!),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: s.saveToGallery, icon: const Icon(Icons.download), label: const Text('Save to gallery'))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(onPressed: s.shareVideo, icon: const Icon(Icons.share), label: const Text('Share'))),
          ]),
        ]),
      ),
    );
  }
}
