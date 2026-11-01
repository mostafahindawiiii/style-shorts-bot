import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

class IconResult {
  IconResult(this.png, this.width, this.height);
  final Uint8List png;
  final int width;
  final int height;
}

class Palette {
  Palette(this.bg, this.fg);
  final int bg; // 0xRRGGBB
  final int fg;
}

class _IconJob {
  _IconJob(this.bytes, this.maxSize);
  final Uint8List bytes;
  final int maxSize;
}

/// Runs in a background isolate so the UI never janks.
Future<IconResult> processIcon(Uint8List bytes, int maxSize) => compute(_processIcon, _IconJob(bytes, maxSize));
Future<Palette> derivePalette(Uint8List jpg) => compute(_palette, jpg);

int _median(List<int> v) {
  v.sort();
  return v[v.length ~/ 2];
}

List<int> _borderMedian(img.Image im) {
  final r = <int>[], g = <int>[], b = <int>[];
  void add(int x, int y) {
    final p = im.getPixel(x, y);
    r.add(p.r.toInt());
    g.add(p.g.toInt());
    b.add(p.b.toInt());
  }

  for (var x = 0; x < im.width; x++) {
    add(x, 0);
    add(x, im.height - 1);
  }
  for (var y = 0; y < im.height; y++) {
    add(0, y);
    add(im.width - 1, y);
  }
  return [_median(r), _median(g), _median(b)];
}

int _dist(img.Pixel p, List<int> bg) => math.max(
    (p.r.toInt() - bg[0]).abs(), math.max((p.g.toInt() - bg[1]).abs(), (p.b.toInt() - bg[2]).abs()));

/// Pollinations returns an opaque picture on a flat background. We (1) find the content bounding box,
/// (2) crop + resize the opaque RGB picture, then (3) key out the flat background and un-premultiply
/// edge pixels, so the icon composites cleanly on ANY background colour with no halo.
IconResult _processIcon(_IconJob job) {
  final src = img.decodeImage(job.bytes);
  if (src == null) throw const FormatException('Cannot decode generated image');
  final bg = _borderMedian(src);

  var minX = src.width, minY = src.height, maxX = -1, maxY = -1;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      if (_dist(src.getPixel(x, y), bg) > 40) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) throw const FormatException('Generated image is blank');

  const margin = 6;
  final x0 = math.max(0, minX - margin), y0 = math.max(0, minY - margin);
  final cw = math.min(src.width, maxX + margin + 1) - x0;
  final ch = math.min(src.height, maxY + margin + 1) - y0;
  final cropped = img.copyCrop(src, x: x0, y: y0, width: cw, height: ch);

  final scale = math.min(job.maxSize / cw, job.maxSize / ch);
  final tw = math.max(2, (cw * scale).round()), th = math.max(2, (ch * scale).round());
  final scaled = img.copyResize(cropped, width: tw, height: th, interpolation: img.Interpolation.cubic);

  final out = img.Image(width: tw, height: th, numChannels: 4);
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      final p = scaled.getPixel(x, y);
      final a = ((_dist(p, bg) - 22) / 50).clamp(0.0, 1.0);
      if (a <= 0) continue; // stays fully transparent
      int un(num v, int b) => ((v - b * (1 - a)) / a).round().clamp(0, 255);
      out.setPixelRgba(x, y, un(p.r, bg[0]), un(p.g, bg[1]), un(p.b, bg[2]), (a * 255).round());
    }
  }
  return IconResult(Uint8List.fromList(img.encodePng(out)), tw, th);
}

Palette _palette(Uint8List jpg) {
  final src = img.decodeImage(jpg);
  if (src == null) return Palette(0xFFFFFF, 0x141414);
  final small = img.copyResize(src, width: 96);
  final m = _borderMedian(small);
  final bg = (m[0] << 16) | (m[1] << 8) | m[2];
  final lum = 0.299 * m[0] + 0.587 * m[1] + 0.114 * m[2];
  return Palette(bg, lum > 140 ? 0x141414 : 0xF5F5F5);
}

/// Simple ring used when icon generation fails completely.
Uint8List fallbackIconPng(int size, int rgb) {
  final im = img.Image(width: size, height: size, numChannels: 4);
  final c = img.ColorRgba8((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, 255);
  final r = size ~/ 2 - 8;
  for (var i = 0; i < math.max(4, size ~/ 25); i++) {
    img.drawCircle(im, x: size ~/ 2, y: size ~/ 2, radius: r - i, color: c);
  }
  return Uint8List.fromList(img.encodePng(im));
}
