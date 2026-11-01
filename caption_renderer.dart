import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Arabic captions are drawn by Flutter's own text engine (HarfBuzz + ICU), which already performs
/// glyph joining (reshaping) and bidi reordering. No arabic_reshaper / bidi packages are needed;
/// we only have to set TextDirection.rtl and bundle an Arabic font (Amiri).
Future<Uint8List> renderCaptionPng(
  String text, {
  required int width,
  required int height,
  required double fontSize,
  required int rgb,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Amiri',
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        height: 1.5,
        color: Color(0xFF000000 | rgb),
      ),
    ),
    textDirection: TextDirection.rtl,
    textAlign: TextAlign.center,
    maxLines: 3,
  )..layout(maxWidth: width * 0.87);
  tp.paint(canvas, Offset((width - tp.width) / 2, (height - tp.height) / 2));
  tp.dispose();
  return _toPng(recorder, width, height);
}

Future<Uint8List> renderBlankPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble())); // starts recording, draws nothing
  return _toPng(recorder, width, height);
}

Future<Uint8List> _toPng(ui.PictureRecorder recorder, int w, int h) async {
  final pic = recorder.endRecording();
  final image = await pic.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  pic.dispose();
  return data!.buffer.asUint8List();
}
