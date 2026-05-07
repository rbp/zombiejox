# Flutter dev environment setup (macOS)

Notes from setting up an Android build target on macOS (Apple Silicon). Flutter, Xcode, and Homebrew are assumed already installed — `flutter doctor` should already show ✓ for Flutter, Xcode, and Chrome before you start here.

## Android setup

### 1. USB cable + phone

- Use a **data-capable** USB cable. Many cables that ship with chargers are charge-only and the phone will not enumerate over USB. If `adb devices` shows nothing and the phone never prompts you to authorize USB debugging, suspect the cable first.
- On the phone: enable Developer Options → USB debugging. After plugging in, swipe down the notification shade and switch USB mode away from "Charging only" (File Transfer / PTP both work).
- First connection prompts an "Allow USB debugging?" dialog on the phone — tap Allow.

### 2. JDK

Gradle 8.14 (used by current Flutter) supports up to JDK 24. **JDK 25 will fail the build** with a cryptic `* What went wrong: 25.0.2` message. Install JDK 24:

```sh
brew install openjdk@24
```

JDK 21 (LTS) also works if you prefer it. Make sure `java -version` reports a supported version. If you have multiple JDKs, use `/usr/libexec/java_home -V` to list them and set `JAVA_HOME` to a supported one.

### 3. Android SDK (command-line, no Android Studio)

The `android-platform-tools` Homebrew cask is **not enough** — it only contains `adb` and `fastboot`. Flutter needs a full SDK with `sdkmanager`, `platforms/`, `build-tools/`, and `platform-tools/` all under one root.

```sh
brew install --cask android-commandlinetools
```

Add the following to your shell startup file — `~/.zshrc` for zsh (the macOS default), `~/.bashrc` for bash, or `~/.profile` if you want it loaded by both:

```sh
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

Open a new shell, then install the components Flutter looks for:

```sh
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.1.0"
```

Pick the most recent build-tools available — `sdkmanager --list | grep build-tools` will show what's on offer. Adjust the platform version to match what `flutter doctor` asks for if it differs.

### 4. Accept licenses

```sh
sdkmanager --licenses              # accept all (press y repeatedly)
flutter config --android-sdk "$ANDROID_HOME"
flutter doctor --android-licenses  # Flutter's own wrapper, separate from sdkmanager's
```

### 5. Verify

```sh
flutter doctor -v
flutter devices
```

Both should show the Android toolchain ✓ and your phone listed.

The first `flutter run` will trigger Gradle to download the NDK (a few hundred MB) — this is normal and only happens once.

## Common gotchas

- **`flutter devices` doesn't see the phone** → almost always a charge-only USB cable, or the phone is in "Charging only" USB mode. Verify with `adb devices` first; if adb sees it, Flutter will too (assuming a working SDK).
- **`* What went wrong: <version>` from Gradle with no other detail** → JDK too new for your Gradle version. Downgrade the JDK.
- **`Android SDK file not found: adb`** → `$ANDROID_HOME/platform-tools/` is missing. Run `sdkmanager "platform-tools"`. Don't rely on the standalone `android-platform-tools` cask; Flutter looks inside `$ANDROID_HOME`.
- **`No valid Android SDK platforms found ... Directory was empty`** → install at least one platform with `sdkmanager "platforms;android-XX"`.
- **`LicenceNotAcceptedException` for the NDK** → re-run `sdkmanager --licenses` and `flutter doctor --android-licenses`; both must succeed.
