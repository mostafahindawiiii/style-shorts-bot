# Islamic Shorts Generator - build guide

The repo ships only `lib/`, `pubspec.yaml`, `tools/` and CI files. The `android/` folder is generated
by `flutter create` (first CI run or `tools/setup.sh`) and patched by `tools/patch_android.py`
(minSdk 24 for ffmpeg-kit, INTERNET / RECORD_AUDIO permissions, app label).

## A. Local build (Flutter SDK + Android SDK installed)
    bash tools/setup.sh
    flutter run                                              # test on a connected phone
    flutter build apk --release --split-per-abi --no-shrink
    # -> build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   (install this one on modern phones)

## B. GitHub Actions (no local setup)
1. Create a GitHub repo and push the contents of this folder (the font is downloaded by the workflow).
2. Open the **Actions** tab -> **Build APK** -> **Run workflow** (it also runs on every push to `main`).
3. When it finishes (about 8-15 min), download the `islamic-shorts-apk` artifact and unzip it.
4. Copy `app-arm64-v8a-release.apk` to your phone and install it (allow "Install unknown apps").

## C. Codemagic
1. Sign in at codemagic.io with GitHub, add the repo, choose **Flutter App** with the `codemagic.yaml` workflow.
2. Start the `android-apk` workflow; download the APKs from the build's Artifacts section.

Notes
- `--no-shrink` avoids R8 stripping ffmpeg-kit's JNI classes in release builds.
- `--split-per-abi` keeps each APK small (the Full-GPL ffmpeg build is large); arm64-v8a fits nearly every current phone.
- Release APKs are signed with the debug key, which is fine for sideloading but not for Google Play.
- ffmpeg_kit_flutter_new is a Full-GPL build (libx264). If you distribute the app, comply with the GPL.
