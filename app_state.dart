import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

import 'models/models.dart';
import 'services/ffmpeg_runner.dart';
import 'services/groq_service.dart';
import 'services/image_processing.dart';
import 'services/pipeline.dart';
import 'services/settings_service.dart';

class AppState extends ChangeNotifier {
  final _settings = SettingsService();
  final _recorder = AudioRecorder();
  final _picker = ImagePicker();

  // settings
  String apiKey = '';
  OutputResolution resolution = OutputResolution.hd;
  ThemeMode themeMode = ThemeMode.system;

  // style reference
  StyleProfile style = StyleProfile.defaults;
  String? styleThumbPath;
  bool analyzingStyle = false;

  // audio
  String? audioPath;
  String? audioName;
  bool isRecording = false;

  // job
  bool running = false;
  String status = '';
  double progress = 0;
  String? error;
  String? info;
  String? outputPath;

  Future<void> init() async {
    apiKey = await _settings.loadKey();
    resolution = await _settings.loadResolution();
    themeMode = await _settings.loadTheme();
    style = await _settings.loadStyle();
    final docs = await getApplicationDocumentsDirectory();
    final thumb = File(p.join(docs.path, 'style_ref.jpg'));
    if (thumb.existsSync() && style.prompt != StyleProfile.defaults.prompt) styleThumbPath = thumb.path;
    notifyListeners();
  }

  // ------------------------------------------------------------ settings
  Future<void> setApiKey(String v) async {
    apiKey = v.trim();
    await _settings.saveKey(apiKey);
    notifyListeners();
  }

  Future<void> setResolution(OutputResolution r) async {
    resolution = r;
    await _settings.saveResolution(r);
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode m) async {
    themeMode = m;
    await _settings.saveTheme(m);
    notifyListeners();
  }

  // ------------------------------------------------------------ style reference
  Future<void> pickStyleImage() async {
    final f = await _picker.pickImage(source: ImageSource.gallery);
    if (f != null) await _analyzeStyle(f.path, isVideo: false);
  }

  Future<void> pickStyleVideo() async {
    final f = await _picker.pickVideo(source: ImageSource.gallery);
    if (f != null) await _analyzeStyle(f.path, isVideo: true);
  }

  Future<void> useDefaultStyle() async {
    style = StyleProfile.defaults;
    styleThumbPath = null;
    await _settings.saveStyle(style);
    notifyListeners();
  }

  Future<void> _analyzeStyle(String path, {required bool isVideo}) async {
    if (apiKey.isEmpty) return _fail('Add your Groq API key in the settings drawer first.');
    analyzingStyle = true;
    error = null;
    notifyListeners();
    try {
      final docs = await getApplicationDocumentsDirectory();
      final jpg = p.join(docs.path, 'style_ref.jpg');
      Future<void> extract(List<String> pre) =>
          FfmpegRunner.run(['-y', ...pre, '-i', path, '-frames:v', '1', '-vf', 'scale=768:-2', '-q:v', '3', jpg]);
      try {
        await extract(isVideo ? ['-ss', '1'] : []);
      } catch (_) {
        await extract([]); // very short clip
      }
      final bytes = await File(jpg).readAsBytes();
      final prompt = await GroqService(apiKey).analyzeStyle(bytes);
      final pal = await derivePalette(bytes);
      style = StyleProfile(prompt: prompt, bg: pal.bg, fg: pal.fg);
      styleThumbPath = jpg;
      await _settings.saveStyle(style);
      info = 'Style saved.';
    } catch (e) {
      error = 'Style analysis failed: $e';
    } finally {
      analyzingStyle = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ audio input
  Future<void> pickAudio() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = r?.files.single.path;
    if (path == null) return;
    audioPath = path;
    audioName = p.basename(path);
    error = null;
    notifyListeners();
  }

  Future<void> toggleRecording() async {
    try {
      if (isRecording) {
        final path = await _recorder.stop();
        isRecording = false;
        if (path != null) {
          audioPath = path;
          audioName = 'Recording (${p.basename(path)})';
        }
      } else {
        if (!await _recorder.hasPermission()) return _fail('Microphone permission denied.');
        final dir = await getTemporaryDirectory();
        await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
            path: p.join(dir.path, 'rec_${DateTime.now().millisecondsSinceEpoch}.m4a'));
        isRecording = true;
        error = null;
      }
    } catch (e) {
      isRecording = false;
      error = 'Recording failed: $e';
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ generation
  Future<void> generate() async {
    if (apiKey.isEmpty) return _fail('Add your Groq API key in the settings drawer first.');
    if (audioPath == null) return _fail('Record or pick an audio file first.');
    running = true;
    error = null;
    info = null;
    outputPath = null;
    progress = 0;
    status = 'Starting…';
    notifyListeners();
    try {
      outputPath = await Pipeline(apiKey).run(
        audioPath: audioPath!,
        style: style,
        res: resolution,
        status: (m, f) {
          status = m;
          progress = f;
          notifyListeners();
        },
      );
    } catch (e) {
      error = e.toString();
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<void> saveToGallery() async {
    if (outputPath == null) return;
    try {
      await Gal.putVideo(outputPath!, album: 'Islamic Shorts');
      info = 'Saved to gallery.';
    } catch (e) {
      error = 'Could not save: $e';
    }
    notifyListeners();
  }

  Future<void> shareVideo() async {
    if (outputPath == null) return;
    await Share.shareXFiles([XFile(outputPath!)], text: 'Made with Islamic Shorts Generator');
  }

  void _fail(String m) {
    error = m;
    notifyListeners();
  }
}
