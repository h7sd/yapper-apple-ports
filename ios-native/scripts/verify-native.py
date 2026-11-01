#!/usr/bin/env python3
"""Inspect packaged native artifacts without executing or authenticating them."""
import argparse
import base64
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import stat
import tempfile
import zipfile
from macho_entitlements import read_simulator_entitlements

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=pathlib.Path, help='Optional unsigned build reference; the shipped Simulator ZIP is inspected directly.')
parser.add_argument('--simulator-zip', required=True, type=pathlib.Path)
parser.add_argument('--ipa', required=True, type=pathlib.Path)
parser.add_argument('--report', required=True, type=pathlib.Path)
parser.add_argument('--expected-version', default='0.2.3')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
checks = []

def check(condition, message):
    if not condition:
        raise AssertionError(message)
    checks.append(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

# Inspect the exact delivered bytes outside synced directories that recreate Finder metadata.
reference_app = args.app
inspection = tempfile.TemporaryDirectory(prefix='yapper-native-inspect-')
inspection_root = pathlib.Path(inspection.name)
with zipfile.ZipFile(args.simulator_zip) as archive:
    members = archive.infolist()
    check(all(not pathlib.PurePosixPath(m.filename).is_absolute()
              and pathlib.PurePosixPath(m.filename).parts[0] == 'YapperNative.app'
              and '..' not in pathlib.PurePosixPath(m.filename).parts
              and '\\' not in m.filename
              and not stat.S_ISLNK(m.external_attr >> 16) for m in members), 'Simulator ZIP uses safe bundle-local member paths')
    archive.extractall(inspection_root)
    for member in members:
        path = inspection_root / member.filename
        if path.exists():
            path.chmod((member.external_attr >> 16) & 0o777 or (0o755 if path.is_dir() else 0o644))
args.app = inspection_root / 'YapperNative.app'

sources = sorted((root / 'YapperNative').rglob('*.swift'))
for path in sources:
    text = path.read_text()
    if 'Authentication' not in path.relative_to(root).parts:
        check(not re.search(r'\b(?:WKWebView|UIWebView|JavaScriptCore|SFSafariViewController|ASWebAuthenticationSession)\b|import\s+WebKit', text), f'Native-only application screen/core: {path.relative_to(root)}')
    check(not re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|/Users/', text), f'No private material: {path.relative_to(root)}')

api = (root / 'YapperNative/Core/NativeAPI.swift').read_text()
key = re.search(r'static let anonymousKey = "([^"]+)"', api).group(1)
payload = json.loads(base64.urlsafe_b64decode(key.split('.')[1] + '==='))
check(payload.get('role') == 'anon', 'Bundled Supabase key is the public anonymous role')

info = plistlib.loads((args.app / 'Info.plist').read_bytes())
if reference_app:
    reference_info = plistlib.loads((reference_app / 'Info.plist').read_bytes())
    check(all(info[key] == reference_info[key] for key in ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion']), 'Delivered Simulator identity/version matches the build reference')
check(info['CFBundleIdentifier'] == 'website.yapper.native.ios', 'Native app uses its separate bundle identifier')
check(info['CFBundleShortVersionString'] == args.expected_version, f'Native development version is {args.expected_version}')
check(info.get('MinimumOSVersion') == '17.0', 'Native application retains the iOS 17 minimum')
check(not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False), 'No arbitrary insecure transport exception')
for permission in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription']:
    check(bool(info.get(permission)), f'User-started native calls/recording have a purpose string: {permission}')
check('NSContactsUsageDescription' not in info, 'No address-book permission requested')
check('NSPhotoLibraryUsageDescription' not in info and 'NSPhotoLibraryAddUsageDescription' not in info, 'Gallery selection requires no broad photo-library read/write permission')
check(info.get('UIBackgroundModes', []) == ['audio'], 'Background capability is limited to active native audio')
check((args.app / 'PrivacyInfo.xcprivacy').exists(), 'Required-reason privacy manifest packaged')
privacy = plistlib.loads((args.app / 'PrivacyInfo.xcprivacy').read_bytes())
check(privacy.get('NSPrivacyTracking') is False, 'No tracking declared by the native app')
binary = args.app / info['CFBundleExecutable']
linked = subprocess.check_output(['otool', '-L', str(binary)], text=True)
dependency_lines = '\n'.join(line for line in linked.splitlines() if line.startswith('\t'))
check('/Users/' not in dependency_lines and '/work/' not in dependency_lines, 'Runtime dependencies do not reference a developer build directory')
check('WebKit.framework' in linked, 'WebKit is linked for the explicitly approved sign-in component')
check('PhotosUI.framework' in linked, 'Native PhotosUI picker is linked for selected photo/video attachments')
check('JavaScriptCore.framework' not in linked, 'No separate JavaScript application runtime is directly linked')
signature_check = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], capture_output=True, text=True)
check(signature_check.returncode == 0, 'Delivered Simulator app and nested frameworks have valid local signatures')
simulated_entitlements = read_simulator_entitlements(binary)
check(set(simulated_entitlements) == set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()), 'Every Simulator architecture has an inspected synthetic identity section')
for architecture, entitlements in simulated_entitlements.items():
    check(entitlements.get('application-identifier') == info['CFBundleIdentifier']
          and entitlements.get('keychain-access-groups') == [info['CFBundleIdentifier']], f'Simulator has only its own keychain identity: {architecture}')
for language in ['en', 'de']:
    check((args.app / f'{language}.lproj/Localizable.strings').exists(), f'Welcome and sign-in localization packaged: {language}')
    check((args.app / f'{language}.lproj/InfoPlist.strings').exists(), f'Native media permission explanations localized: {language}')
check((args.app / 'ThirdPartyNotices.txt').read_bytes() == (root / 'YapperNative/ThirdPartyNotices.txt').read_bytes(), 'Pinned media dependency notices are bundled intact')
for relative in ['Fonts/Inter-Latin-Variable.ttf', 'Icons/OriginalIconPaths.json', 'Licenses/Inter-OFL.txt', 'Brand/apple-icon.png', 'Sounds/message.mp3']:
    original = root / 'YapperNative/OriginalAssets' / relative
    packaged = args.app / 'OriginalAssets' / relative
    check(packaged.is_file() and digest(packaged) == digest(original), f'Original visual resource bundled intact: {relative}')
check(digest(root / 'YapperNative/OriginalAssets/Fonts/Inter-Latin-Variable.ttf') == '4555141acf75a7f89902d034afc7f66551ef0e7ab1579c982da1f1a0f3a5d7e6', 'Inter has the recorded original font table digest')

resolved = root / 'YapperNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
pins = json.loads(resolved.read_text())['pins']
expected_pins = {
    'client-sdk-swift': ('2.19.0', '43c1c0870e51eedbfd95b20b1b5c43a767886786'),
    'livekit-ffi-xcframework': ('0.13.1', '685cfd95e23edf734450125eb58bb3bb21b4133b'),
    'webrtc-xcframework': ('150.7871.4', 'f843fb1c12017bd17fde38e7293649c204548467'),
}
check({p['identity'] for p in pins} == set(expected_pins), 'Native media dependency inventory matches the reviewed lockfile')
for pin in pins:
    version, revision = expected_pins[pin['identity']]
    check(pin['state'] == {'version': version, 'revision': revision}, f'Pinned native dependency: {pin["identity"]} {version}')
check(not any(p.suffix.lower() in ['.html', '.js', '.asar'] for p in args.app.rglob('*')), 'Application embeds no website or JavaScript application resources')
release_bytes = binary.read_bytes()
for marker in [b'--native-ui-fixtures', b'--native-ui-login-fixture', b'fixture-chat', b'fixture-password', b'demo@example.invalid']:
    check(marker not in release_bytes, f'Debug fixture marker excluded from Release: {marker.decode()}')

assets = []
for path in [args.simulator_zip, args.ipa]:
    with zipfile.ZipFile(path) as archive:
        check(archive.testzip() is None, f'ZIP member integrity: {path.name}')
        names = archive.namelist()
        check(not any('/YapperNativeTests' in n or '/YapperNativeUITests' in n for n in names), f'No test bundles packaged: {path.name}')
        check(not any(n.lower().endswith(('.p12', '.mobileprovision', '.key', '.pem')) for n in names), f'No signing credentials packaged: {path.name}')
        if path == args.ipa:
            device_info = plistlib.loads(archive.read('Payload/YapperNative.app/Info.plist'))
            check(device_info['CFBundleIdentifier'] == info['CFBundleIdentifier'], 'IPA bundle identity matches native application')
            check(device_info['CFBundleShortVersionString'] == args.expected_version, 'IPA version matches inspected simulator application')
            check(device_info['CFBundleVersion'] == info['CFBundleVersion'], 'Device and simulator build numbers match')
            check('NSPhotoLibraryUsageDescription' not in device_info and 'NSPhotoLibraryAddUsageDescription' not in device_info, 'iPhone gallery uses selected items without broad library permission')
            device_binary = inspection_root / 'DeviceExecutable'
            device_binary.write_bytes(archive.read('Payload/YapperNative.app/' + device_info['CFBundleExecutable']))
            try:
                read_simulator_entitlements(device_binary)
            except ValueError as error:
                check(str(error) == 'Missing __TEXT,__entitlements Simulator section', 'Simulator-only identity is excluded from the iPhone executable')
            else:
                check(False, 'Simulator-only identity must never be embedded into the iPhone executable')
    assets.append({'name': path.name, 'bytes': path.stat().st_size, 'sha256': digest(path)})

report = {
    'schemaVersion': 1, 'passed': True, 'checks': checks, 'artifacts': assets,
    'sourceSHA256': {str(p.relative_to(root)): digest(p) for p in sources},
    'verificationLimits': {
        'realAccountSignIn': False, 'liveMessageSend': False,
        'physicalDevice': False, 'liveCallsAndE2EEInterop': False,
        'fullWebParity': False,
        'serverCaptchaEnforcement': 'Human completion and real-account acceptance remain unverified.',
        'testResults': 'See separate native test report; package inspection is not a runtime test.',
        'webContentScope': 'Temporary official web sign-in only; application screens use SwiftUI/UIKit and native media SDKs.'
    }
}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'passed': True, 'checks': len(checks), 'artifacts': assets}, indent=2))
inspection.cleanup()
