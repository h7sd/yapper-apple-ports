#!/usr/bin/env python3
"""Copy the shared, prebuilt local extensions without changing their bytes."""
from pathlib import Path
import hashlib
import shutil

android = Path(__file__).resolve().parents[1]
repo = android.parent
assets = android / 'app/src/main/assets'
pairs = {
    'YapperCord.js': repo / 'extensions/yappercord/bundle.js',
    'LICENSE.Vencord': repo / 'extensions/yappercord/LICENSE.Vencord',
    'YapperAppearance.js': repo / 'appearance/appearance.js',
    'LICENSE.Appearance': repo / 'appearance/LICENSE',
}
for name, source in pairs.items():
    if not source.is_file(): raise SystemExit('Missing shared source: ' + str(source))
    shutil.copyfile(source, assets / name)
    print(name + ': ' + hashlib.sha256((assets / name).read_bytes()).hexdigest())
