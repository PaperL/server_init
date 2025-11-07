#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PYTHON_BIN="${PYTHON_BIN:-}"

detect_python() {
  local candidate
  if [[ -n "$PYTHON_BIN" ]]; then
    if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
      PYTHON_BIN=$(command -v "$PYTHON_BIN")
      return 0
    elif [[ -x "$PYTHON_BIN" ]]; then
      return 0
    fi
  fi
  for candidate in python python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON_BIN=$(command -v "$candidate")
      return 0
    fi
  done
  return 1
}

ensure_simple_term_menu() {
  detect_python || {
    echo "Python interpreter not found. Install Python 3 and retry." >&2
    exit 1
  }
  cat >&2 <<'EOF'
simple-term-menu is required. Install it with:
  pip install simple-term-menu
EOF
  exit 1
}

main() {
  local py_script

  detect_python || {
    echo "Python interpreter not found. Install Python 3 and retry." >&2
    exit 1
  }

  if "$PYTHON_BIN" - <<'PY'
import importlib
import sys
try:
    importlib.import_module('simple_term_menu')
except ImportError:
    sys.exit(1)
else:
    sys.exit(0)
PY
  then
    :
  else
    ensure_simple_term_menu
  fi

  py_script="$SCRIPT_DIR/main.py"
  if [[ ! -f "$py_script" ]]; then
    cat >&2 <<EOF
main.py not found next to this script.
Please implement the Python TUI per plan.md and place it at:
  $py_script
EOF
    exit 1
  fi
  exec "$PYTHON_BIN" "$py_script" "$@"
}

main "$@"


