# Android build provenance

`dependencies.lock.json` pins the URL and SHA-256 of each downloaded artifact. Downloads use verified HTTPS from Google's official Maven repository or Maven Central. The build rejects any mismatch. No SDK manager is executed and no proprietary Android SDK EULA is automatically accepted.

Runtime contents:

- **AndroidX WebKit 1.18.0**, Apache-2.0, official `androidx.webkit:webkit` AAR. The compatibility library supplies the narrowly used, feature-gated origin/frame-scoped message listener and document-start injection APIs. It does not replace the device's updatable System WebView engine. Classes are bundled unmodified, then translated to DEX by D8.
- **AndroidX Core 1.1.0**, Apache-2.0, official `androidx.core:core` AAR. Only the unmodified `androidx.core.util.Pair`, `ObjectsCompat` and `androidx.core.content.pm.PackageInfoCompat` class files are included. Bytecode dependency inspection of WebKit 1.18.0 identifies Pair and PackageInfoCompat as its executable Core dependencies; ObjectsCompat is Pair's sole Core helper. PackageInfoCompat uses only Android framework APIs. No lifecycle/Activity/resource replacement is added.
- The same **Yapper Appearance 0.1.0** MIT source and **Yapinplugger 0.1.0** GPL runtime/catalogue bytes already shipped in the Apple ports. Pinned Vencord catalogue commit: `644434941b515a2626a2161e219653cb36e723e7`. These are local assets, not remotely loaded executable plugins. Six independent adaptations are available; 161 public plugins remain unported.

Build/compile/test dependencies, not included as app executables:

- AAPT2 `9.5.0-16666295`, Apache-2.0, official Google Maven host binaries for macOS/Linux/Windows.
- R8/D8 `9.5.28`, BSD-3-Clause and notices in its official distribution, Google Maven. D8 translates the app and narrowly bundled AndroidX bytecode into release DEX. No R8 obfuscation or shrinking is applied.
- Android `apksig 9.5.0`, Apache-2.0, Google Maven. `scripts/SignApk.java` is a small MIT wrapper around its documented signing/verification API, not a substitute signature implementation.
- `org.robolectric:android-all:15-robolectric-12650502`, Apache-2.0 AOSP framework build from Maven Central. Used as the Android API-35 Java/resource compile-link input only. No framework classes or resources from this jar are bundled as executable app code; the app links references to Android's system resources. The artifact POM explicitly distinguishes this open-source framework build from proprietary Android SDK binaries.
- AndroidX `annotation-jvm 1.8.1`, Kotlin `kotlin-stdlib 1.9.24` and JSpecify `1.0.0`, Apache-2.0. Compile-only annotations, never put into app DEX.
- JUnit `4.13.2`, EPL-1.0, and Hamcrest Core `1.3`, BSD-3-Clause, executed JVM tests only.
- The locally installed Eclipse Temurin JDK 17 supplies javac/java/keytool/jar and Java core compile/desugaring symbols. The JDK itself is not bundled with the APK.

The complete Apache license and runtime notices are in `app/src/main/assets/`. Upstream source and API references:

- [AndroidX WebViewCompat](https://developer.android.com/reference/androidx/webkit/WebViewCompat)
- [AndroidX source](https://android.googlesource.com/platform/frameworks/support/)
- [AAPT2 standalone Maven build instructions](https://developer.android.com/tools/aapt2)
- [AOSP apksig source](https://android.googlesource.com/platform/tools/apksig/)
- [AOSP R8 source](https://r8.googlesource.com/r8/)
- [Robolectric android-all artifact and license](https://repo.maven.apache.org/maven2/org/robolectric/android-all/15-robolectric-12650502/android-all-15-robolectric-12650502.pom)
