import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class FfmpegException implements Exception {
  FfmpegException(this.message);
  final String message;
  @override
  String toString() => 'FFmpeg failed: $message';
}

class FfmpegRunner {
  /// Runs ffmpeg with an argument list (no shell, so no quoting problems).
  /// [onTime] receives the processed output time in milliseconds.
  static Future<void> run(List<String> args, {void Function(int ms)? onTime}) {
    final done = Completer<void>();
    FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          done.complete();
        } else {
          final out = await session.getOutput() ?? '';
          done.completeError(FfmpegException(
              out.length > 700 ? out.substring(out.length - 700) : out));
        }
      },
      null,
      onTime == null
          ? null
          : (stats) {
              final t = stats.getTime().toInt();
              if (t > 0) onTime(t);
            },
    );
    return done.future;
  }

  static Future<double> duration(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final d = session.getMediaInformation()?.getDuration();
    return double.tryParse(d ?? '') ?? 0;
  }
}
