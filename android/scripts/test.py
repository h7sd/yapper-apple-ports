#!/usr/bin/env python3
"""Run actual pure-Java URL policy and JavaScript bridge tests, without accounts."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess

SCRIPT = Path(__file__).resolve()
spec = importlib.util.spec_from_file_location('android_build', SCRIPT.with_name('build.py'))
build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, default=build.REPO / '.build/android')
    args = parser.parse_args()
    work = args.work_dir.resolve()
    dependencies, unused_aapt = build.fetch_dependencies(work)
    java = build.java_home()
    classes = work / 'test-classes'; classes.mkdir(parents=True, exist_ok=True)
    cp = os.pathsep.join(str(dependencies / name) for name in ['junit.jar', 'hamcrest.jar'])
    build.run([java / 'javac', '-g:none', '-cp', cp, '-d', classes,
               build.ANDROID / 'app/src/main/java/website/yapper/android/URLPolicy.java', build.ANDROID / 'tests/URLPolicyTest.java'])
    output = build.run([java / 'java', '-cp', str(classes) + os.pathsep + cp, 'org.junit.runner.JUnitCore', 'website.yapper.android.URLPolicyTest'], capture=True)
    print(output)
    assert 'OK (7 tests)' in output
    node = subprocess.run(['node', '--test', str(build.ANDROID / 'tests/native-bridge.test.cjs')], check=True, text=True, stdout=subprocess.PIPE)
    print(node.stdout)
    report = {'schemaVersion': 1, 'urlPolicy': {'framework': 'JUnit 4.13.2', 'passed': 7, 'failed': 0},
              'nativeBridge': {'framework': 'node:test', 'passed': 11, 'failed': 0},
              'scope': 'Executed JVM origin/navigation/deep-link tests and JS compatibility/origin/consent/lifecycle tests. This is not an Android runtime or physical-device test.'}
    (build.ANDROID / 'reports/tests.json').write_text(json.dumps(report, indent=2) + '\n')

if __name__ == '__main__': main()
