#!/usr/bin/env python3
"""Compile the shipping Swift script exporter, then test its JavaScript offline.

No browser session, credentials, CAPTCHA, network request or copied JavaScript is
used. The only Swift stub supplies the public API hostname from NativeAPI.swift.
"""

from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "YapperNative/Authentication/BrowserLoginScript.swift"
CONFIGURATION = ROOT / "YapperNative/Core/NativeAPI.swift"
TEST = ROOT / "tests/web-login-bridge.test.cjs"
FLOW_ID = "7EF4A8BC-5234-4A9C-8793-6F0053D49F64"


def main() -> None:
    configuration = CONFIGURATION.read_text(encoding="utf-8")
    host_match = re.search(r'static\s+let\s+apiHost\s*=\s*"([^"\r\n]+)"', configuration)
    if not host_match or not re.fullmatch(r"[a-z0-9.-]+", host_match.group(1)):
        raise SystemExit("Cannot read the public API hostname from NativeAPI.swift")
    api_host = host_match.group(1)
    with tempfile.TemporaryDirectory(prefix="yapin-web-login-bridge-") as temporary:
        directory = Path(temporary)
        exporter = directory / "Exporter.swift"
        executable = directory / "export-bridge"
        javascript = directory / "browser-login.js"
        exporter.write_text(
            "import Foundation\n"
            "nonisolated enum NativeConfiguration {\n"
            f"    static let apiHost = {json.dumps(api_host)}\n"
            "}\n"
            "@main struct Exporter {\n"
            "    static func main() {\n"
            f'        print(BrowserLoginScript.source(flowID: UUID(uuidString: "{FLOW_ID}")!))\n'
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", str(SOURCE), str(exporter), "-o", str(executable)],
            check=True,
        )
        with javascript.open("w", encoding="utf-8") as output:
            subprocess.run([str(executable)], stdout=output, check=True)
        environment = os.environ.copy()
        environment.update(
            BROWSER_LOGIN_SCRIPT_PATH=str(javascript),
            BROWSER_LOGIN_API_HOST=api_host,
            BROWSER_LOGIN_FLOW_ID=FLOW_ID,
        )
        result = subprocess.run(
            ["node", "--test", "--test-reporter=tap", str(TEST)],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        counts = {name: int(value) for name, value in re.findall(
            r"^# (tests|pass|fail|cancelled|skipped|todo) (\d+)\s*$", result.stdout, re.MULTILINE
        )}
        report = {
            "runner": "ios-native/scripts/test-web-login-bridge.py",
            "source": "ios-native/YapperNative/Authentication/BrowserLoginScript.swift",
            "test_source": "ios-native/tests/web-login-bridge.test.cjs",
            "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "test_source_sha256": hashlib.sha256(TEST.read_bytes()).hexdigest(),
            "tested_at_utc": datetime.now(timezone.utc).isoformat(),
            "runtime": subprocess.check_output(["node", "--version"], text=True).strip(),
            "transport": "mocked; no live auth, CAPTCHA, browser session or network",
            "result": "passed" if result.returncode == 0 and counts.get("fail") == 0 else "failed",
            **counts,
        }
        reports = ROOT / "reports"
        reports.mkdir(exist_ok=True)
        (reports / "web-login-bridge-tests.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if result.returncode or not counts:
            print(result.stdout, end="")
            raise SystemExit(result.returncode or 1)
        print("Actual Swift-exported browser login bridge: "
              f'{counts["pass"]}/{counts["tests"]} PASS; '
              f'{counts["fail"]} failed; {counts["skipped"]} skipped')
        print("Report: ios-native/reports/web-login-bridge-tests.json")


if __name__ == "__main__":
    main()
