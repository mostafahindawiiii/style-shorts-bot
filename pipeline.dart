import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'audio_service.dart';
import 'groq_service.dart';
import 'image_processing.dart';
import 'pollinations_service.dart';
import 'video_composer.dart';

class PipelineException implements Exception {
  PipelineException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef StatusCallback = void Function(String message, double progress);

class Pipeline {
  Pipeline(this.apiKey);
  final String apiKey;

  static const maxAudioSeconds = 170; // YouTube Shorts limit is 3 min

  /// audio -> trim -> Groq Whisper -> Groq scenes -> Pollinations icons -> ffmpeg video. Returns the MP4 path.
  Future<String> run({
    required String audioPath,
    required StyleProfile style,
    required OutputResolution res,
    required StatusCallback status,
  }) async {
    final groq = GroqService(apiKey);
    final pollinations = PollinationsService();
    final tmp = await getTemporaryDirectory();
    final work = Directory(p.join(tmp.path, 'job_${DateTime.now().millisecondsSinceEpoch}'))
      ..createSync(recursive: true);

    try {
      status('Trimming silences…', 0.02);
      final clean = p.join(work.path, 'clean.m4a');
      final dur = await AudioService.trimSilence(audioPath, clean);
      if (dur < 1) throw PipelineException('No speech detected in this audio.');
      if (dur > maxAudioSeconds) {
        throw PipelineException('Audio is ${dur.round()} s after trimming; the limit is $maxAudioSeconds s.');
      }

      status('Transcribing with Whisper large-v3…', 0.08);
      final words = await groq.transcribe(clean);
      if (words.length < 3) throw PipelineException('Not enough speech was recognised.');

      status('Planning scenes…', 0.25);
      List<Scene> scenes;
      try {
        scenes = await groq.planScenes(words);
      } catch (_) {
        scenes = fallbackScenes(words.length);
      }

      final iconSize = (res.width * 0.72).round();
      for (var i = 0; i < scenes.length; i++) {
        status('Drawing “${scenes[i].concept}” (${i + 1}/${scenes.length})…', 0.30 + 0.25 * i / scenes.length);
        final prompt = 'a single ${scenes[i].concept}, ${style.prompt}, centered, isolated on a plain '
            '${style.bgDescription} background, no text, no watermark, no border';
        IconResult? icon;
        final bytes = await pollinations.fetch(prompt);
        if (bytes != null) {
          try {
            icon = await processIcon(bytes, iconSize);
          } catch (_) {/* fall through to placeholder */}
        }
        final png = icon?.png ?? fallbackIconPng(iconSize ~/ 2, style.fg);
        final file = File(p.join(work.path, 'icon_$i.png'));
        await file.writeAsBytes(png);
        scenes[i]
          ..iconPath = file.path
          ..iconW = icon?.width ?? iconSize ~/ 2
          ..iconH = icon?.height ?? iconSize ~/ 2;
      }

      final rawOut = p.join(work.path, 'short.mp4');
      await VideoComposer.compose(
        audioPath: clean,
        audioDuration: dur,
        words: words,
        scenes: scenes,
        style: style,
        res: res,
        workDir: work.path,
        outPath: rawOut,
        onProgress: (f, label) => status(label, 0.58 + 0.42 * f),
      );

      final docs = await getApplicationDocumentsDirectory();
      final outDir = Directory(p.join(docs.path, 'outputs'))..createSync(recursive: true);
      final finalPath = p.join(outDir.path, 'short_${DateTime.now().millisecondsSinceEpoch}.mp4');
      await File(rawOut).copy(finalPath);
      status('Done', 1.0);
      return finalPath;
    } finally {
      try {
        work.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
