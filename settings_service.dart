import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class SettingsService {
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  Future<String> loadKey() async => (await _secure.read(key: 'groq_api_key')) ?? '';
  Future<void> saveKey(String key) => _secure.write(key: 'groq_api_key', value: key.trim());

  Future<OutputResolution> loadResolution() async {
    final p = await SharedPreferences.getInstance();
    return OutputResolution.values.firstWhere((r) => r.name == p.getString('resolution'),
        orElse: () => OutputResolution.hd);
  }

  Future<void> saveResolution(OutputResolution r) async =>
      (await SharedPreferences.getInstance()).setString('resolution', r.name);

  Future<ThemeMode> loadTheme() async {
    final p = await SharedPreferences.getInstance();
    return ThemeMode.values.firstWhere((m) => m.name == p.getString('theme'), orElse: () => ThemeMode.system);
  }

  Future<void> saveTheme(ThemeMode m) async => (await SharedPreferences.getInstance()).setString('theme', m.name);

  Future<StyleProfile> loadStyle() async {
    final raw = (await SharedPreferences.getInstance()).getString('style');
    if (raw == null) return StyleProfile.defaults;
    try {
      return StyleProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return StyleProfile.defaults;
    }
  }

  Future<void> saveStyle(StyleProfile s) async =>
      (await SharedPreferences.getInstance()).setString('style', jsonEncode(s.toJson()));
}
