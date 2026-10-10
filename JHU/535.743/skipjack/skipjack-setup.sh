#!/usr/bin/env bash
# Skipjack course 535743: module names from the supplied live module listing.
# Run: bash setup_535743_v2.sh   (inside an allocated GPU session)
# Does not delete environments or modify ~/.bashrc.

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "Run this installer with bash, not source." >&2
    return 1
fi

# Do not enable nounset: site module initialization may use unset variables.
set -Ee -o pipefail
trap 'rc=$?; echo "ERROR: setup stopped at line $LINENO (exit $rc). Read the error above." >&2; exit "$rc"' ERR

ENV_DIR="$HOME/virtual/535743"
GCC_MODULE="gcc/12.3.0"
PYTHON_MODULE="python/3.11.9"
EXPECTED_VERSION="3.11.9"

if [[ "$(uname -s)" != Linux || "$(hostname -s)" == login* ]]; then
    echo "STOP: Run this on Skipjack inside your allocated GPU session." >&2
    exit 1
fi

# A parent shell may still have an old/deleted environment in PATH.
# Remove only its bin entry in this child process, before loading the modules.
if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    OLD_VENV_BIN="$VIRTUAL_ENV/bin"
    IFS=: read -r -a PATH_PARTS <<< "$PATH"
    NEW_PATH=""
    for entry in "${PATH_PARTS[@]}"; do
        if [[ -n "$entry" && "$entry" != "$OLD_VENV_BIN" ]]; then
            NEW_PATH="${NEW_PATH:+$NEW_PATH:}$entry"
        fi
    done
    export PATH="$NEW_PATH"
    unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT
fi
unset PYTHONHOME PYTHONPATH
export PYTHONNOUSERSITE=1

# Make the module command available to this noninteractive Bash script.
if ! type module >/dev/null 2>&1; then
    for init in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh \
                /usr/share/lmod/lmod/init/bash /usr/share/Modules/init/bash; do
        if [[ -r "$init" ]]; then
            source "$init"
            if type module >/dev/null 2>&1; then break; fi
        fi
    done
fi
if ! type module >/dev/null 2>&1; then
    echo "STOP: The module command is unavailable in this shell." >&2
    exit 1
fi

echo "Loading $GCC_MODULE and $PYTHON_MODULE..."
if ! module load "$GCC_MODULE"; then
    echo "STOP: Could not load $GCC_MODULE. Check: module spider gcc/12.3.0" >&2
    exit 1
fi
if ! module load "$PYTHON_MODULE"; then
    echo "STOP: Could not load $PYTHON_MODULE. Check: module spider python/3.11.9" >&2
    exit 1
fi
hash -r

# Resolve the executable from the loaded module's PATH.
# No dependency on EBROOTPYTHON or other installation-specific variables.
BASE_PYTHON="$(type -P python3)"
"$BASE_PYTHON" -I - "$EXPECTED_VERSION" <<'PYTHON'
import platform
import sys

print("Base Python:", sys.executable)
print("Python version:", platform.python_version())
if platform.python_version() != sys.argv[1]:
    raise SystemExit("STOP: Expected Python " + sys.argv[1] + ". No fallback to system Python.")
if sys.prefix != sys.base_prefix:
    raise SystemExit("STOP: The selected base Python is still inside another virtual environment.")
PYTHON

if [[ ! -e "$ENV_DIR" && ! -L "$ENV_DIR" ]]; then
    echo "Creating $ENV_DIR..."
    mkdir -p "$(dirname "$ENV_DIR")"
    "$BASE_PYTHON" -I -m venv "$ENV_DIR"
elif [[ ! -f "$ENV_DIR/pyvenv.cfg" || ! -x "$ENV_DIR/bin/python" ]]; then
    echo "STOP: $ENV_DIR exists but is not a usable virtual environment. Nothing deleted." >&2
    exit 1
fi

PY="$ENV_DIR/bin/python"
"$PY" -I - "$ENV_DIR" "$EXPECTED_VERSION" <<'PYTHON'
import pathlib
import platform
import sys

if platform.python_version() != sys.argv[2]:
    raise SystemExit("STOP: Existing environment has the wrong Python version. Nothing deleted.")
if sys.prefix == sys.base_prefix or pathlib.Path(sys.prefix).resolve() != pathlib.Path(sys.argv[1]).resolve():
    raise SystemExit("STOP: This is not the intended virtual environment.")
print("Environment Python:", sys.executable)
PYTHON

echo "Upgrading pip, setuptools, and wheel..."
"$PY" -I -m pip install --upgrade pip setuptools wheel

echo "Installing course packages and TensorFlow CUDA dependencies..."
"$PY" -I -m pip install \
    numpy pandas matplotlib requests tqdm \
    "tensorflow[and-cuda]"

echo "Checking package dependencies and recording installed versions..."
"$PY" -I -m pip check
"$PY" -I -m pip list
"$PY" -I -m pip freeze > "$ENV_DIR/requirements-installed.txt"

echo "Testing imports and actual TensorFlow GPU execution..."
"$PY" -I - <<'PYTHON'
import sys
import numpy
import pandas
import matplotlib
import requests
import tqdm
import tensorflow as tf

print("Python:", sys.executable)
print("TensorFlow:", tf.__version__)
gpus = tf.config.list_physical_devices("GPU")
print("TensorFlow GPUs:", gpus)
if not gpus:
    raise SystemExit(
        "Packages installed, but TensorFlow detected no GPU. "
        "Keep the errors above; do not delete the environment."
    )

for gpu in gpus:
    tf.config.experimental.set_memory_growth(gpu, True)
tf.config.set_soft_device_placement(False)
with tf.device("/GPU:0"):
    x = tf.constant([[1.0, 2.0], [3.0, 4.0]])
    result = tf.matmul(x, x)
print("GPU calculation:\n", result.numpy())
print("Result device:", result.device)
if "GPU:0" not in result.device.upper():
    raise SystemExit("STOP: The test result is not on GPU:0.")
PYTHON

echo
echo "SUCCESS: Python $EXPECTED_VERSION, package checks, and GPU execution passed."
echo "Installed versions: $ENV_DIR/requirements-installed.txt"
echo "To activate in your working terminal, run:"
printf 'module load %s %s && source "%s/bin/activate"\n' \
    "$GCC_MODULE" "$PYTHON_MODULE" "$ENV_DIR"
