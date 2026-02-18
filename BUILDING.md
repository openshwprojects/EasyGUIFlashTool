# Building EasyGUIFlashTool

## Prerequisites

- **Flutter SDK** (stable channel, ≥ 3.0.0)
- **Git**

Platform-specific:

| Target   | Extra Requirements                            |
|----------|-----------------------------------------------|
| Web      | Chrome (for testing)                          |
| Windows  | Visual Studio 2022 with C++ desktop workload  |
| Android  | JDK 17, Android SDK                           |

## Getting Started

```bash
cd Project
flutter pub get
```

## Building

### Web

```bash
flutter build web --release
```

The output is in `Project/build/web`.

To run locally:

```bash
flutter run -d chrome
```

> **Note:** For GitHub Pages deployment, the CI uses `--base-href "/EasyGUIFlashTool/"`.

### Windows

```bash
flutter build windows --release
```

The output is in `Project/build/windows/x64/runner/Release`.

To run locally:

```bash
flutter run -d windows
```

### Android (APK)

```bash
flutter build apk --release
```

The output APK is at `Project/build/app/outputs/flutter-apk/app-release.apk`.

## CI / CD

Two GitHub Actions workflows run on every push to `main`:

| Workflow          | File                                  | What it does                                                  |
|-------------------|---------------------------------------|---------------------------------------------------------------|
| **Deploy**        | `.github/workflows/deploy.yml`        | Builds the web app and deploys to GitHub Pages                |
| **Release**       | `.github/workflows/release.yml`       | Builds APK + Windows zip and creates a GitHub Release         |

## Project Structure

```
Project/
├── lib/
│   ├── main.dart            # App entry point
│   ├── constants.dart       # App-wide constants
│   ├── flasher/             # Flashing protocol logic
│   ├── models/              # Data models
│   ├── providers/           # State management (Provider)
│   ├── screens/             # UI screens
│   ├── serial/              # Serial port abstraction (Web / Windows / Android)
│   ├── services/            # Business-logic services
│   └── widgets/             # Reusable UI widgets
├── android/                 # Android runner
├── windows/                 # Windows runner
├── web/                     # Web runner
├── test/                    # Tests
└── pubspec.yaml             # Dependencies & metadata
```
