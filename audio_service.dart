import 'ffmpeg_runner.dart';

class AudioService {
  /// Removes silences longer than 0.7 s (keeps ~0.22 s so phrases still breathe) and
  /// re-encodes to mono AAC. The same file feeds Groq Whisper and the final video,
  /// so word timestamps always match the video timeline. Returns the cleaned duration.
  static Future<double> trimSilence(String input, String output) async {
    const filter = 'silenceremove=start_periods=1:start_silence=0.1:start_threshold=-45dB:'
        'stop_periods=-1:stop_duration=0.7:stop_silence=0.22:stop_threshold=-45dB:detection=peak';
    await FfmpegRunner.run([
      '-y', '-i', input, '-vn', '-ac', '1', '-ar', '44100',
      '-af', filter, '-c:a', 'aac', '-b:a', '96k', output,
    ]);
    return FfmpegRunner.duration(output);
  }
}
