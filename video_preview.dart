import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPreview extends StatefulWidget {
  const VideoPreview({super.key, required this.path});
  final String path;
  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoPreview old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  Future<void> _load() async {
    final old = _c;
    final c = VideoPlayerController.file(File(widget.path));
    await c.initialize();
    await c.setLooping(true);
    if (!mounted) {
      c.dispose();
      return;
    }
    setState(() => _c = c);
    old?.dispose();
    c.play();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return const AspectRatio(aspectRatio: 9 / 16, child: Center(child: CircularProgressIndicator()));
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: Stack(alignment: Alignment.center, children: [
            ClipRRect(borderRadius: BorderRadius.circular(16), child: VideoPlayer(c)),
            GestureDetector(
              onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
              behavior: HitTestBehavior.opaque,
              child: AnimatedOpacity(
                opacity: c.value.isPlaying ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: const CircleAvatar(radius: 28, child: Icon(Icons.play_arrow, size: 36)),
              ),
            ),
            Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.all(8))),
          ]),
        ),
      ),
    );
  }
}
