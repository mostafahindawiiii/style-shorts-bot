#!/usr/bin/env bash
# One-time local setup:  bash tools/setup.sh
set -e
[ -d android ] || flutter create --platforms=android --org com.islamicshorts --project-name islamic_shorts_generator .
rm -rf test
python3 tools/patch_android.py
mkdir -p assets/fonts
[ -f assets/fonts/Amiri-Bold.ttf ] || curl -fL -o assets/fonts/Amiri-Bold.ttf \
  https://github.com/google/fonts/raw/main/ofl/amiri/Amiri-Bold.ttf
flutter pub get
echo "Ready. Run:  flutter run   |   flutter build apk --release --split-per-abi --no-shrink"
