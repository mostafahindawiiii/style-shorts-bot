import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class PollinationsService {
  static const host = 'image.pollinations.ai';
  final _rng = Random();

  Future<Uint8List?> fetch(String prompt) async {
    final clean = prompt.replaceAll(RegExp(r'[\r\n]+'), ' ');
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final uri = Uri(
          scheme: 'https',
          host: host,
          pathSegments: ['prompt', clean],
          queryParameters: {
            'width': '768',
            'height': '768',
            'nologo': 'true',
            'model': 'flux',
            'seed': '${_rng.nextInt(1000000)}',
          },
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 120));
        final type = res.headers['content-type'] ?? '';
        if (res.statusCode == 200 && type.startsWith('image') && res.bodyBytes.length > 2000) {
          return res.bodyBytes;
        }
      } catch (_) {/* retry */}
      await Future.delayed(Duration(seconds: 3 * (attempt + 1)));
    }
    return null;
  }
}
