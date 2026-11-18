#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Python 3.12+ ARM64 est requis. Définis PYTHON_BIN si nécessaire." >&2
  exit 1
fi
"$PYTHON_BIN" - <<'PY'
import platform, sys
if sys.version_info < (3, 12):
    raise SystemExit("Python 3.12 ou supérieur est requis.")
if platform.system() != "Darwin" or platform.machine() != "arm64":
    raise SystemExit("La création de NXManager.app doit être exécutée sur macOS Apple Silicon.")
PY

"$PYTHON_BIN" -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e '.[macos]' pyinstaller

rm -rf build dist
pyinstaller --noconfirm --clean --windowed \
  --name NXManager \
  --osx-bundle-identifier app.nxmanager.desktop \
  --collect-all PySide6 \
  --hidden-import=GameController \
  --hidden-import=Foundation \
  --hidden-import=CoreFoundation \
  run_nxmanager.py

echo "Application créée : $(pwd)/dist/NXManager.app"
echo "Teste le lancement depuis Finder sur le Mac cible."
