import 'dart:math' as math;
import 'dart:ui' show Color;

class Word {
  const Word(this.text, this.start, this.end);
  final String text;
  final double start;
  final double end;
}

class Scene {
  Scene(this.startWord, this.concept);
  final int startWord;
  final String concept;
  double t0 = 0;
  double t1 = 0;
  String? iconPath;
  int iconW = 0;
  int iconH = 0;
}

class Chunk {
  Chunk(this.text, this.start, this.lastEnd) : end = lastEnd;
  final String text;
  final double start;
  final double lastEnd;
  double end;
}

/// CURRENT_STYLE_PROMPT + palette (colours stored as 0xRRGGBB).
class StyleProfile {
  const StyleProfile({required this.prompt, required this.bg, required this.fg});

  final String prompt;
  final int bg;
  final int fg;

  static const defaults = StyleProfile(
    prompt: 'minimalist black line art vector icon, bold clean outline, flat, no shading',
    bg: 0xFFFFFF,
    fg: 0x141414,
  );

  Color get bgColor => Color(0xFF000000 | bg);
  Color get fgColor => Color(0xFF000000 | fg);
  String get bgHex => bg.toRadixString(16).padLeft(6, '0');

  String get bgDescription {
    final r = (bg >> 16) & 255, g = (bg >> 8) & 255, b = bg & 255;
    final lum = 0.299 * r + 0.587 * g + 0.114 * b;
    final sat = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    if (sat < 25 && lum > 225) return 'white';
    if (sat < 25 && lum < 45) return 'black';
    return 'flat solid color #$bgHex';
  }

  Map<String, dynamic> toJson() => {'prompt': prompt, 'bg': bg, 'fg': fg};

  factory StyleProfile.fromJson(Map<String, dynamic> j) => StyleProfile(
        prompt: (j['prompt'] as String?) ?? defaults.prompt,
        bg: (j['bg'] as int?) ?? defaults.bg,
        fg: (j['fg'] as int?) ?? defaults.fg,
      );
}

enum OutputResolution {
  hd(720, 1280, '720 × 1280'),
  fullHd(1080, 1920, '1080 × 1920');

  const OutputResolution(this.width, this.height, this.label);
  final int width;
  final int height;
  final String label;
}
