import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'caption_renderer.dart';
import 'ffmpeg_runner.dart';

String _f(double v) => v.toStringAsFixed(3);

/// Scene boundaries come straight from Whisper word timestamps.
void assignSceneTimes(List<Scene> scenes, List<Word> words, double total) {
  for (var i = 0; i < scenes.length; i++) {
    scenes[i].t0 = i == 0 ? 0.0 : (words[scenes[i].startWord].start - 0.10).clamp(0.0, total);
  }
  for (var i = 0; i < scenes.length; i++) {
    scenes[i].t1 = i + 1 < scenes.length ? scenes[i + 1].t0 : total;
  }
}

List<Chunk> buildChunks(List<Word> words, List<Scene> scenes, double total,
    {int maxWords = 4, double maxGap = 0.6}) {
  final starts = scenes.map((s) => s.startWord).toSet();
  final groups = <List<Word>>[];
  var cur = <Word>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (cur.isNotEmpty && (cur.length >= maxWords || starts.contains(i) || w.start - cur.last.end > maxGap)) {
      groups.add(cur);
      cur = <Word>[];
    }
    cur.add(w);
  }
  if (cur.isNotEmpty) groups.add(cur);

  final chunks = [for (final g in groups) Chunk(g.map((w) => w.text).join(' '), g.first.start, g.last.end)];
  for (var i = 0; i < chunks.length; i++) {
    final c = chunks[i];
    final nxt = i + 1 < chunks.length ? chunks[i + 1].start : null;
    if (nxt != null && nxt - c.lastEnd < 0.4) {
      c.end = nxt; // continuous speech: hand over seamlessly
    } else {
      c.end = (c.lastEnd + 0.35).clamp(0.0, nxt ?? total);
    }
    if (c.end < c.start + 0.2) c.end = c.start + 0.2;
  }
  return chunks;
}

/// Pop-in (ease-out-back overshoot, 0.5 s) x shrink-out (smoothstep, last 0.25 s) as an ffmpeg expression
/// of the absolute timestamp `t`. Evaluated per frame by `scale=...:eval=frame`.
String _scaleExpr(int baseDim, double t0, double t1) {
  final x = 'clip((t-${_f(t0)})/0.5,0,1)';
  final u = 'clip((${_f(t1)}-t)/0.25,0,1)';
  final s = '((1+2.70158*pow($x-1,3)+1.70158*pow($x-1,2))*($u*$u*(3-2*$u)))';
  return 'max(2,trunc($baseDim*$s/2)*2)';
}

class VideoComposer {
  static const fps = 24;

  /// Builds ONE ffmpeg filter graph: flat background + per-scene icons (pop-in, floating bob, shrink-out)
  /// + a caption stream (transparent PNGs rendered by Flutter, timed with the concat demuxer) + the voice.
  static Future<void> compose({
    required String audioPath,
    required double audioDuration,
    required List<Word> words,
    required List<Scene> scenes,
    required StyleProfile style,
    required OutputResolution res,
    required String workDir,
    required String outPath,
    required void Function(double fraction, String label) onProgress,
  }) async {
    final w = res.width, h = res.height;
    final total = audioDuration + 0.5;
    assignSceneTimes(scenes, words, total);
    final chunks = buildChunks(words, scenes, total);

    final iconCy = (h * 0.41).round();
    final capH = (h * 0.20).round();
    final capY = (h * 0.76).round() - capH ~/ 2;
    final bob = 14.0 * w / 1080.0;

    // ---- captions -> PNGs + concat timeline (blank frames fill the gaps)
    onProgress(0, 'Rendering Arabic captions…');
    final blank = p.join(workDir, 'blank.png');
    await File(blank).writeAsBytes(await renderBlankPng(w, capH));
    final list = StringBuffer('ffconcat version 1.0\n');
    var cursor = 0.0;
    String lastFile = blank;
    void seg(String file, double dur) {
      if (dur < 0.001) return;
      list.writeln("file '$file'");
      list.writeln('duration ${_f(dur)}');
      lastFile = file;
    }

    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      final start = c.start < cursor ? cursor : c.start;
      final file = p.join(workDir, 'cap_$i.png');
      await File(file).writeAsBytes(await renderCaptionPng(c.text,
          width: w, height: capH, fontSize: w * 0.072, rgb: style.fg));
      seg(blank, start - cursor);
      seg(file, c.end - start);
      cursor = c.end;
    }
    seg(blank, total - cursor + 0.2);
    list.writeln("file '$lastFile'"); // concat demuxer quirk: repeat the last entry (no duration)
    final listPath = p.join(workDir, 'captions.txt');
    await File(listPath).writeAsString(list.toString());

    // ---- inputs
    final args = <String>[
      '-y',
      '-f', 'lavfi', '-i', 'color=c=0x${style.bgHex}:s=${w}x$h:r=$fps:d=${_f(total)}', // 0: background
      '-i', audioPath, //                                                                    1: voice
      '-f', 'concat', '-safe', '0', '-i', listPath, //                                       2: captions
    ];
    for (final s in scenes) {
      args.addAll(['-loop', '1', '-framerate', '$fps', '-t', _f(s.t1 - s.t0 + 0.3), '-i', s.iconPath!]); // 3..
    }

    // ---- filter graph
    final g = <String>[];
    var prev = '0:v';
    for (var i = 0; i < scenes.length; i++) {
      final s = scenes[i];
      final t0 = _f(s.t0), t1 = _f(s.t1);
      g.add("[${3 + i}:v]format=rgba,setpts=PTS+$t0/TB,"
          "scale=w='${_scaleExpr(s.iconW, s.t0, s.t1)}':h='${_scaleExpr(s.iconH, s.t0, s.t1)}':eval=frame[ic$i]");
      g.add("[$prev][ic$i]overlay=x='(main_w-overlay_w)/2':"
          "y='$iconCy-overlay_h/2+${_f(bob)}*sin(2*PI*(t-$t0)/2.6)':"
          "enable='between(t,$t0,$t1)':eof_action=pass:format=auto[v$i]");
      prev = 'v$i';
    }
    g.add('[2:v]fps=$fps,format=rgba[cap]');
    g.add("[$prev][cap]overlay=x=0:y=$capY:format=auto[vc]");
    g.add('[vc]format=yuv420p[vout]');

    args.addAll([
      '-filter_complex', g.join(';'),
      '-map', '[vout]', '-map', '1:a',
      '-c:v', 'libx264', '-preset', w >= 1080 ? 'superfast' : 'veryfast', '-crf', '24',
      '-pix_fmt', 'yuv420p', '-r', '$fps',
      '-c:a', 'aac', '-b:a', '128k',
      '-movflags', '+faststart',
      '-t', _f(total),
      outPath,
    ]);

    onProgress(0, 'Encoding video…');
    await FfmpegRunner.run(args, onTime: (ms) => onProgress((ms / 1000 / total).clamp(0.0, 1.0), 'Encoding video…'));
  }
}
