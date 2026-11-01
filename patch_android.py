#!/usr/bin/env python3
"""Run after `flutter create`: minSdk 24 (ffmpeg-kit), permissions, app label."""
import pathlib
import re

app = pathlib.Path("android/app")

for name in ("build.gradle.kts", "build.gradle"):
    p = app / name
    if p.exists():
        s = p.read_text()
        s2 = re.sub(r"minSdk(Version)?(\s*=\s*|\s+)flutter\.minSdkVersion",
                    lambda m: f"minSdk{m.group(1) or ''}{m.group(2)}24", s)
        if s2 != s:
            p.write_text(s2)
            print("patched minSdk ->", p)

manifest = app / "src/main/AndroidManifest.xml"
m = manifest.read_text()
if "RECORD_AUDIO" not in m:
    perms = [
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.RECORD_AUDIO"/>',
        '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>',
    ]
    m = m.replace("<application", "\n    ".join(perms) + "\n    <application", 1)
m = re.sub(r'android:label="[^"]*"', 'android:label="Islamic Shorts Generator"', m, count=1)
manifest.write_text(m)
print("patched manifest")
