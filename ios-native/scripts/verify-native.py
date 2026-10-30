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
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--app', required=True, type=pathlib.Path)
parser.add_argument('--simulator-zip', required=True, type=pathlib.Path)
parser.add_argument('--ipa', required=True, type=pathlib.Path)
parser.add_argument('--report', required=True, type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
checks = []

def check(condition, message):
    if not condition:
        raise AssertionError(message)
    checks.append(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

sources = sorted((root / 'YapperNative').rglob('*.swift'))
for path in sources:
    text = path.read_text()
    check(not re.search(r'\b(?:WKWebView|UIWebView|JavaScriptCore|SFSafariViewController|ASWebAuthenticationSession)\b|import\s+WebKit', text), f'Native-only source: {path.relative_to(root)}')
    check(not re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|/Users/', text), f'No private material: {path.relative_to(root)}')

api = (root / 'YapperNative/Core/NativeAPI.swift').read_text()
key = re.search(r'static let anonymousKey = "([^"]+)"', api).group(1)
payload = json.loads(base64.urlsafe_b64decode(key.split('.')[1] + '==='))
check(payload.get('role') == 'anon', 'Bundled Supabase key is the public anonymous role')

info = plistlib.loads((args.app / 'Info.plist').read_bytes())
check(info['CFBundleIdentifier'] == 'website.yapper.native.ios', 'Native app uses its separate bundle identifier')
check(info['CFBundleShortVersionString'] == '0.1.0', 'Native preview version is 0.1.0')
check(not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False), 'No arbitrary insecure transport exception')
check(not any(key in info for key in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSContactsUsageDescription']), 'No unused capture or contacts permission prompts')
check((args.app / 'PrivacyInfo.xcprivacy').exists(), 'Required-reason privacy manifest packaged')
privacy = plistlib.loads((args.app / 'PrivacyInfo.xcprivacy').read_bytes())
check(privacy.get('NSPrivacyTracking') is False, 'No tracking declared by the native app')
binary = args.app / info['CFBundleExecutable']
linked = subprocess.check_output(['otool', '-L', str(binary)], text=True)
check('WebKit.framework' not in linked and 'JavaScriptCore.framework' not in linked, 'Executable does not directly link a web or JavaScript UI runtime')
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
    assets.append({'name': path.name, 'bytes': path.stat().st_size, 'sha256': digest(path)})

report = {
    'schemaVersion': 1, 'passed': True, 'checks': checks, 'artifacts': assets,
    'sourceSHA256': {str(p.relative_to(root)): digest(p) for p in sources},
    'verificationLimits': {
        'realAccountSignIn': False, 'liveMessageSend': False,
        'physicalDevice': False, 'serverCaptchaEnforcement': 'unknown',
        'testResults': 'See separate native test report; package inspection is not a runtime test.'
    }
}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'passed': True, 'checks': len(checks), 'artifacts': assets}, indent=2))
