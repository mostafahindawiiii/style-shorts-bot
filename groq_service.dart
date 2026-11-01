import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';

class GroqException implements Exception {
  GroqException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GroqService {
  GroqService(this.apiKey);
  final String apiKey;

  static const _base = 'https://api.groq.com/openai/v1';
  static const sttModel = 'whisper-large-v3';
  // llama-3.3-70b-versatile and llama-4-scout were retired by Groq in mid-2026.
  // Each list is tried in order; a model that is rejected falls through to the next one.
  static const textModels = ['openai/gpt-oss-120b', 'qwen/qwen3.6-27b'];
  static const visionModels = ['qwen/qwen3.8-27b', 'qwen/qwen3.6-27b'];

  Map<String, String> get _auth => {'Authorization': 'Bearer $apiKey'};

  Duration _retryDelay(http.Response r, int attempt) {
    final s = double.tryParse(r.headers['retry-after'] ?? '') ?? 2.0 * (attempt + 1);
    return Duration(milliseconds: (s.clamp(1, 30) * 1000).round());
  }

  // ---------------------------------------------------------------- Whisper
  Future<List<Word>> transcribe(String audioPath) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final req = http.MultipartRequest('POST', Uri.parse('$_base/audio/transcriptions'))
        ..headers.addAll(_auth)
        ..fields.addAll({
          'model': sttModel,
          'language': 'ar',
          'temperature': '0',
          'response_format': 'verbose_json',
          'timestamp_granularities[]': 'word',
        })
        ..files.add(await http.MultipartFile.fromPath('file', audioPath));
      final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 4)));
      if (res.statusCode == 429 || res.statusCode >= 500) {
        await Future.delayed(_retryDelay(res, attempt));
        continue;
      }
      if (res.statusCode == 401) throw GroqException('Invalid Groq API key.');
      if (res.statusCode >= 400) {
        throw GroqException('Transcription failed (${res.statusCode}): ${_short(res)}');
      }
      return _parseWords(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    }
    throw GroqException('Groq is rate-limited right now. Try again in a minute.');
  }

  List<Word> _parseWords(Map<String, dynamic> j) {
    final words = <Word>[];
    for (final w in (j['words'] as List? ?? const [])) {
      final t = (w['word'] as String? ?? '').trim();
      if (t.isEmpty) continue;
      final s = (w['start'] as num).toDouble();
      final e = (w['end'] as num).toDouble();
      words.add(Word(t, s, e > s ? e : s + 0.05));
    }
    if (words.isEmpty) {
      // fallback: spread each segment's words evenly
      for (final seg in (j['segments'] as List? ?? const [])) {
        final toks = ((seg['text'] as String?) ?? '').split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
        if (toks.isEmpty) continue;
        final s = (seg['start'] as num).toDouble();
        final step = ((seg['end'] as num).toDouble() - s) / toks.length;
        for (var i = 0; i < toks.length; i++) {
          words.add(Word(toks[i], s + i * step, s + (i + 1) * step));
        }
      }
    }
    return words;
  }

  // ---------------------------------------------------------------- chat helpers
  Future<String> _chat(List<String> models, List<Map<String, dynamic>> messages,
      {double temperature = 0.3, int maxTokens = 3000}) async {
    GroqException? last;
    for (final model in models) {
      for (var attempt = 0; attempt < 3; attempt++) {
        final res = await http
            .post(Uri.parse('$_base/chat/completions'),
                headers: {..._auth, 'Content-Type': 'application/json'},
                body: jsonEncode({
                  'model': model,
                  'temperature': temperature,
                  'max_tokens': maxTokens,
                  'messages': messages,
                }))
            .timeout(const Duration(seconds: 90));
        if (res.statusCode == 429 || res.statusCode >= 500) {
          await Future.delayed(_retryDelay(res, attempt));
          continue;
        }
        if (res.statusCode == 401) throw GroqException('Invalid Groq API key.');
        if (res.statusCode >= 400) {
          last = GroqException('$model rejected (${res.statusCode}): ${_short(res)}');
          break; // try the next model
        }
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final content = (data['choices'][0]['message']['content'] as String?) ?? '';
        if (content.trim().isNotEmpty) return content;
        last = GroqException('Empty reply from $model');
        break;
      }
    }
    throw last ?? GroqException('Groq is rate-limited right now. Try again in a minute.');
  }

  static Map<String, dynamic> extractJson(String text) {
    final cleaned = text.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    final a = cleaned.indexOf('{'), b = cleaned.lastIndexOf('}');
    if (a < 0 || b <= a) throw const FormatException('No JSON in model output');
    return jsonDecode(cleaned.substring(a, b + 1)) as Map<String, dynamic>;
  }

  String _short(http.Response r) {
    final s = utf8.decode(r.bodyBytes, allowMalformed: true);
    return s.length > 220 ? s.substring(0, 220) : s;
  }

  // ---------------------------------------------------------------- scene planning
  static const _sceneSystem = '''You are a visual director for short Arabic Islamic reminder videos.
You receive a transcript as numbered words: [0]word [1]word ...
Split it into 3 to 5 CONSECUTIVE scenes. For each scene give:
 - "start_word": index of the scene's first word (first scene = 0, strictly increasing)
 - "concept": ONE concrete drawable object in English, 1-2 words (e.g. Prison, Crown, Heart, Scale, Door, Book).
   Never a person, prophet, angel or any living being.
Return ONLY JSON: {"scenes": [{"start_word": 0, "concept": "Prison"}]}''';

  Future<List<Scene>> planScenes(List<Word> words) async {
    final numbered = [for (var i = 0; i < words.length; i++) '[$i]${words[i].text}'].join(' ');
    final raw = await _chat(textModels, [
      {'role': 'system', 'content': _sceneSystem},
      {'role': 'user', 'content': numbered},
    ], temperature: 0.4);
    final data = extractJson(raw);
    final scenes = <Scene>[];
    var last = -1;
    for (final s in (data['scenes'] as List? ?? const [])) {
      final sw = int.tryParse('${s['start_word']}');
      final concept = ('${s['concept'] ?? ''}').replaceAll(RegExp(r'[^A-Za-z0-9 \-]'), '').trim();
      if (sw == null || concept.isEmpty) continue;
      final idx = sw.clamp(0, words.length - 1);
      if (idx <= last) continue;
      scenes.add(Scene(idx, concept.length > 40 ? concept.substring(0, 40) : concept));
      last = idx;
    }
    if (scenes.isEmpty) throw GroqException('Scene planning returned nothing usable.');
    final capped = scenes.take(5).toList();
    return [Scene(0, capped.first.concept), ...capped.skip(1)];
  }

  // ---------------------------------------------------------------- vision (style mimic)
  static const _visionPrompt =
      'Analyze the ARTISTIC STYLE of this reference image so other objects can be drawn in the same style. '
      'Describe medium, line weight, color palette, texture, shading and level of detail as ONE comma-separated '
      'English phrase (max 35 words) usable as an image-generation style suffix. Do NOT mention the subject matter, '
      'people, text, paper, grid or background. Return ONLY JSON: {"style_prompt": "..."}';

  Future<String> analyzeStyle(Uint8List jpegBytes) async {
    final b64 = base64Encode(jpegBytes);
    final raw = await _chat(visionModels, [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': _visionPrompt},
          {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,$b64'}},
        ],
      }
    ], temperature: 0.2, maxTokens: 1500);
    final style = ('${extractJson(raw)['style_prompt'] ?? ''}').trim();
    if (style.length < 8) throw GroqException('The vision model returned no usable style description.');
    return style.length > 400 ? style.substring(0, 400) : style;
  }
}

/// Used when Groq scene planning fails: evenly split with generic concepts.
List<Scene> fallbackScenes(int wordCount) {
  const concepts = ['Heart', 'Light', 'Book', 'Crown', 'Star'];
  final k = (wordCount ~/ 4).clamp(1, 4);
  return [for (var i = 0; i < k; i++) Scene(i * wordCount ~/ k, concepts[i % concepts.length])];
}
