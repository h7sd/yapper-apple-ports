#!/bin/sh
# User-local integration only. The client itself stays in this extracted folder.
set -eu
APPDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$APPDIR" in
  *'%'*|*'"'*|*'`'*|*'$'*|*'\'*|*'
'*) printf '%s\n' 'Move the folder to a path without %, quotes, $, backticks, backslashes or newlines.' >&2; exit 1 ;;
esac
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
mkdir -p "$DATA_HOME/applications" "$DATA_HOME/icons/hicolor/512x512/apps"
while IFS= read -r line; do
  case "$line" in
    Exec=*) printf 'Exec="%s/AppRun" %%u\n' "$APPDIR" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$APPDIR/yapinplugger.desktop" > "$DATA_HOME/applications/yapinplugger.desktop"
cp "$APPDIR/yapinplugger.png" "$DATA_HOME/icons/hicolor/512x512/apps/yapinplugger.png"
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$DATA_HOME/applications"; fi
if command -v xdg-mime >/dev/null 2>&1; then xdg-mime default yapinplugger.desktop x-scheme-handler/yapper; fi
printf '%s\n' 'Yapinplugger launcher installed for this user. Keep this extracted folder in place.'
