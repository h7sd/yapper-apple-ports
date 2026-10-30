#!/usr/bin/env python3
"""Build an installable, self-signed Android APK without accepting SDK EULAs.

Uses pinned, open-source Maven artifacts. JDK 17+, Python 3.9+, curl required.
The AOSP framework jar is used only for compile/link; it is never packaged.
Signing secrets stay in the ignored work directory, outside source control.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import struct
import subprocess
import sys
import zipfile

ANDROID = Path(__file__).resolve().parents[1]
REPO = ANDROID.parent
APK_NAME = 'Yapper-1.1.0-Yapinplugger-0.1.0-android.apk'

def run(command, *, cwd=None, capture=False):
    result = subprocess.run([str(value) for value in command], cwd=cwd, check=True,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ''

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()

def java_home():
    candidate = os.environ.get('JAVA_HOME')
    if not candidate and sys.platform == 'darwin':
        candidate = run(['/usr/libexec/java_home', '-v', '17'], capture=True)
    if candidate:
        return Path(candidate) / 'bin'
    executable = shutil.which('javac')
    if not executable: raise SystemExit('JDK 17+ is required. Set JAVA_HOME to your installed JDK.')
    return Path(executable).resolve().parent

def fetch_dependencies(work):
    dependencies = work / 'deps'; dependencies.mkdir(parents=True, exist_ok=True)
    host = {'darwin': 'macos', 'linux': 'linux', 'win32': 'windows'}.get(sys.platform)
    if not host: raise SystemExit('Supported build hosts: macOS, Linux, Windows.')
    entries = json.loads((ANDROID / 'dependencies.lock.json').read_text())['artifacts']
    selected = [entry for entry in entries if not entry['role'].startswith('tool-') or entry['role'] == 'tool-' + host]
    for entry in selected:
        output = dependencies / entry['file']
        if not output.exists():
            temporary = output.with_suffix(output.suffix + '.download')
            run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', entry['url'], '-o', temporary])
            if sha(temporary) != entry['sha256']:
                temporary.unlink(); raise SystemExit('Dependency checksum mismatch: ' + entry['file'])
            temporary.replace(output)
        if sha(output) != entry['sha256']: raise SystemExit('Dependency checksum mismatch: ' + entry['file'])
    aapt = dependencies / ('aapt2.exe' if host == 'windows' else 'aapt2')
    aapt_archive = 'aapt2.jar' if host == 'macos' else 'aapt2-' + host + '.jar'
    with zipfile.ZipFile(dependencies / aapt_archive) as package: aapt.write_bytes(package.read(aapt.name))
    aapt.chmod(0o755)
    with zipfile.ZipFile(dependencies / 'webkit.aar') as package:
        (dependencies / 'webkit.jar').write_bytes(package.read('classes.jar'))
    # WebKit 1.18.0 references Pair and PackageInfoCompat from androidx.core;
    # Pair uses ObjectsCompat. Include these three unmodified class files, not the
    # unrelated Activity/lifecycle/storage libraries and unused resources.
    with zipfile.ZipFile(dependencies / 'core.aar') as package:
        import io
        with zipfile.ZipFile(io.BytesIO(package.read('classes.jar'))) as classes:
            with zipfile.ZipFile(dependencies / 'core-webkit-subset.jar', 'w') as subset:
                for name in ['androidx/core/util/Pair.class', 'androidx/core/util/ObjectsCompat.class', 'androidx/core/content/pm/PackageInfoCompat.class']:
                    subset.writestr(name, classes.read(name))
    return dependencies, aapt

def ensure_signing_key(work, java):
    signing = work / 'signing'; signing.mkdir(parents=True, exist_ok=True); signing.chmod(0o700)
    key = Path(os.environ.get('YAPINPLUGGER_ANDROID_KEYSTORE', signing / 'distribution.p12')).resolve()
    password = Path(os.environ.get('YAPINPLUGGER_ANDROID_PASSWORD_FILE', signing / 'password.txt')).resolve()
    reused = key.exists() and password.exists()
    if key.exists() != password.exists(): raise SystemExit('Both existing keystore and password file are required; refusing to replace an update signing identity.')
    if not key.exists():
        password.write_text(secrets.token_urlsafe(48) + '\n'); password.chmod(0o600)
        try:
            run([java / 'keytool', '-genkeypair', '-alias', 'distribution', '-keyalg', 'RSA', '-keysize', '3072',
                 '-sigalg', 'SHA256withRSA', '-validity', '10000', '-storetype', 'PKCS12', '-keystore', key,
                 '-storepass:file', password, '-keypass:file', password,
                 '-dname', 'CN=Yapinplugger Local Distribution,OU=Unofficial Yapper Port,O=Yapinplugger,C=DE', '-noprompt'])
        except Exception:
            if not key.exists(): password.unlink(missing_ok=True)
            raise
        key.chmod(0o600)
    return key, password, reused

def normalized_zip(source, target, dex):
    # Deterministic ZIP entry dates. Android apksig performs alignment as it signs.
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(target, 'w') as output:
        for item in original.infolist():
            entry = zipfile.ZipInfo(item.filename, (2026, 10, 30, 0, 0, 0))
            entry.compress_type = item.compress_type
            entry.external_attr = 0o644 << 16
            output.writestr(entry, original.read(item.filename))
        for file in sorted(dex.glob('classes*.dex')):
            entry = zipfile.ZipInfo(file.name, (2026, 10, 30, 0, 0, 0)); entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16; output.writestr(entry, file.read_bytes())

def verify_package(apk, aapt, java, dependencies, helpers, work):
    signature = json.loads(run([java / 'java', '-cp', str(helpers) + os.pathsep + str(dependencies / 'apksig.jar'), 'SignApk', 'verify', apk], capture=True))
    badging = run([aapt, 'dump', 'badging', apk], capture=True)
    manifest = run([aapt, 'dump', 'xmltree', apk, '--file', 'AndroidManifest.xml'], capture=True)
    (work / 'manifest.txt').write_text(manifest + '\n')
    assert "package: name='website.yapper.android'" in badging
    assert ("minSdkVersion:'29'" in badging or "sdkVersion:'29'" in badging) and "targetSdkVersion:'35'" in badging
    assert 'android:debuggable(0x0101000f)=false' in manifest or 'android:debuggable(0x0101000f)=(type 0x12)0x0' in manifest
    assert 'android:usesCleartextTraffic(0x010104ec)=false' in manifest or 'android:usesCleartextTraffic(0x010104ec)=(type 0x12)0x0' in manifest
    source_assets = ANDROID / 'app/src/main/assets'
    with zipfile.ZipFile(apk) as archive:
        assert archive.testzip() is None
        names = archive.namelist()
        assert 'classes.dex' in names and 'resources.arsc' in names
        assert not any(name.startswith('lib/') or name.endswith(('.p12', '.jks', '.keystore', '.class')) for name in names)
        assert not any('fixture' in name.lower() or 'test' in name.lower() for name in names)
        for asset in source_assets.iterdir(): assert archive.read('assets/' + asset.name) == asset.read_bytes()
        # Every uncompressed entry must be aligned for Android's mmap reader.
        with apk.open('rb') as stream:
            for entry in archive.infolist():
                if entry.compress_type != zipfile.ZIP_STORED: continue
                stream.seek(entry.header_offset)
                header = stream.read(30)
                name_length, extra_length = struct.unpack_from('<HH', header, 26)
                assert (entry.header_offset + 30 + name_length + extra_length) % 4 == 0, entry.filename
    return signature, badging

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, default=REPO / '.build/android')
    parser.add_argument('--output-dir', type=Path, default=REPO / '.build/android/artifacts')
    parser.add_argument('--dependencies-only', action='store_true')
    options = parser.parse_args()
    work = options.work_dir.resolve(); work.mkdir(parents=True, exist_ok=True)
    dependencies, aapt = fetch_dependencies(work)
    if options.dependencies_only: print('Pinned open-source dependencies verified.'); return
    for asset, canonical in [('YapperCord.js', REPO / 'extensions/yappercord/bundle.js'),
                             ('YapperAppearance.js', REPO / 'appearance/appearance.js')]:
        if (ANDROID / 'app/src/main/assets' / asset).read_bytes() != canonical.read_bytes():
            raise SystemExit('Shared asset differs from canonical source. Run python3 android/scripts/sync-assets.py: ' + asset)
    java = java_home()
    build = work / 'build'
    if build.exists(): shutil.rmtree(build)
    classes = build / 'classes'; classes.mkdir(parents=True)
    generated = build / 'generated'; generated.mkdir()
    dex = build / 'dex'; dex.mkdir()
    helpers = build / 'helpers'; helpers.mkdir()
    res = ANDROID / 'app/src/main/res'
    compiled_res = build / 'resources.zip'
    linked = build / 'linked.apk'
    run([aapt, 'compile', '--dir', res, '-o', compiled_res])
    run([aapt, 'link', '-o', linked, '--manifest', ANDROID / 'app/src/main/AndroidManifest.xml',
         '-I', dependencies / 'android-all.jar', '--java', generated, '--min-sdk-version', '29', '--target-sdk-version', '35',
         '-A', ANDROID / 'app/src/main/assets', compiled_res])
    classpath = os.pathsep.join(str(dependencies / name) for name in ['android-all.jar', 'webkit.jar', 'annotation.jar', 'kotlin-stdlib.jar', 'jspecify.jar'])
    sources = sorted((ANDROID / 'app/src/main/java').rglob('*.java')) + sorted(generated.rglob('*.java'))
    run([java / 'javac', '-source', '8', '-target', '8', '-g:none', '-Xlint:-options,-classfile', '-encoding', 'UTF-8', '-cp', classpath, '-d', classes, *sources])
    app_jar = build / 'app.jar'
    run([java / 'jar', 'cf', app_jar, '-C', classes, '.'])
    run([java / 'java', '-cp', dependencies / 'r8.jar', 'com.android.tools.r8.D8', '--release', '--min-api', '29',
         '--lib', dependencies / 'android-all.jar', '--lib', java.parent, '--output', dex, app_jar, dependencies / 'webkit.jar', dependencies / 'core-webkit-subset.jar'])
    unsigned = build / 'unsigned.apk'; normalized_zip(linked, unsigned, dex)
    run([java / 'javac', '-g:none', '-cp', dependencies / 'apksig.jar', '-d', helpers, ANDROID / 'scripts/SignApk.java'])
    key, password, key_reused = ensure_signing_key(work, java)
    options.output_dir.mkdir(parents=True, exist_ok=True)
    apk = options.output_dir.resolve() / APK_NAME
    run([java / 'java', '-cp', str(helpers) + os.pathsep + str(dependencies / 'apksig.jar'), 'SignApk', 'sign', unsigned, apk, key, password])
    signature, badging = verify_package(apk, aapt, java, dependencies, helpers, work)
    report = {
        'schemaVersion': 1, 'artifact': apk.name, 'sha256': sha(apk), 'bytes': apk.stat().st_size,
        'applicationId': 'website.yapper.android', 'versionCode': 11004, 'versionName': '1.1.0-yapinplugger.0.1.0',
        'minimumAndroidApi': 29, 'targetAndroidApi': 35, 'debuggable': False,
        'signing': {**signature, 'identity': 'Self-signed local project distribution certificate; not a Google Play identity.',
                    'privateKeyPublished': False, 'persistentKeyReused': key_reused},
        'packageChecks': ['AAPT2 manifest/package/minSDK/targetSDK', 'no debuggable flag', 'no native binaries',
                          'no test fixtures or private keys', 'all bundled asset bytes match source',
                          'APK ZIP CRC and uncompressed-entry alignment', 'official apksig v2/v3 signature verification'],
        'assetsSha256': {asset.name: sha(asset) for asset in sorted((ANDROID / 'app/src/main/assets').iterdir())},
        'runtimeVerification': {'installedOrLaunched': False, 'reason': 'No Android emulator or physical Android device was attached to this build host.'},
        'permissions': [line.split("name='")[1].split("'")[0] for line in badging.splitlines() if line.startswith('uses-permission:')],
        'pluginCoverage': {'independentAdaptations': 6, 'unportedPublicVencordPlugins': 161, 'enabledByDefault': False},
        'limits': ['Remote Yapper UI/backend can change independently.', 'No background push, screen sharing, system audio, global hotkeys or process enumeration.',
                   'Physical Android media/file-picker/notification/keyboard/edge-to-edge behavior still requires device verification.',
                   'External OAuth import is not authenticated in automated verification.'],
    }
    (ANDROID / 'reports/verification.json').write_text(json.dumps(report, indent=2) + '\n')
    (options.output_dir / (apk.name + '.sha256')).write_text(report['sha256'] + '  ' + apk.name + '\n')
    print('Built and verified: ' + str(apk))
    print('SHA-256: ' + report['sha256'])
    print('Signing certificate SHA-256: ' + signature['certificateSha256'])

if __name__ == '__main__': main()
