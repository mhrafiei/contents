#!/usr/bin/env bash
# Skipjack course 535743: module names from the supplied live module listing.
# Run: bash setup_535743_v3.sh   (inside an allocated GPU session)
# Does not delete environments or modify ~/.bashrc.
# v3: installs every third-party library used by the course notebooks
#     (JHU/535.743/codes), plus spaCy models, NLTK data and ffmpeg for pydub.
#     Safe to re-run on an existing 535743 environment.

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

# Every third-party package imported by the course notebooks.
# Installed in ONE pip call so the resolver picks versions that work together
# (TensorFlow and PyTorch both pull CUDA libraries from pip).
PACKAGES=(
    # Core scientific stack and Jupyter
    numpy pandas scipy matplotlib seaborn tqdm requests pillow
    ipykernel "ipywidgets==7.7.1"
    # Classical ML
    scikit-learn imbalanced-learn
    # TensorFlow / Keras (pydot is used by tf.keras.utils.plot_model)
    "tensorflow[and-cuda]" tensorflow-datasets keras-tuner pydot
    # PyTorch and Hugging Face
    torch torchvision
    transformers timm sentencepiece huggingface_hub diffusers accelerate safetensors
    # Computer vision
    opencv-python mediapipe ultralytics pycocotools
    # NLP
    nltk spacy gensim textblob
    # PDF / documents
    PyPDF2 reportlab
    # Web app, media and APIs (Modules 13-14)
    flask pyngrok pexels-api-py gtts pydub static-ffmpeg
    google-cloud-aiplatform google-cloud-storage google-cloud-texttospeech
)

echo "Installing course packages (TensorFlow + PyTorch with CUDA). This can take 10-20 minutes..."
"$PY" -I -m pip install --upgrade "${PACKAGES[@]}"

echo "Downloading spaCy language models..."
"$PY" -I -m spacy download en_core_web_sm
"$PY" -I -m spacy download en_core_web_md

# NLTK searches <env>/nltk_data, so the data stays inside this environment.
echo "Downloading NLTK data into $ENV_DIR/nltk_data..."
"$PY" -I - "$ENV_DIR/nltk_data" <<'PYTHON'
import sys
import nltk

target = sys.argv[1]
for pkg in ("punkt", "punkt_tab", "stopwords", "vader_lexicon"):
    if not nltk.download(pkg, download_dir=target, quiet=True):
        raise SystemExit("STOP: NLTK could not download " + pkg)
print("NLTK data ready:", target)
PYTHON

# pydub needs ffmpeg and ffprobe to read/write mp3 (Module 14B).
# No root needed: if they are not already on PATH, use the static-ffmpeg
# binaries and link them into the environment's bin directory.
echo "Checking ffmpeg/ffprobe for pydub..."
if type -P ffmpeg >/dev/null 2>&1 && type -P ffprobe >/dev/null 2>&1; then
    echo "Using ffmpeg already on PATH: $(type -P ffmpeg)"
else
    "$PY" -I - "$ENV_DIR/bin" <<'PYTHON'
import os
import sys
from static_ffmpeg import run

ffmpeg, ffprobe = run.get_or_fetch_platform_executables_else_raise()
for src, name in ((ffmpeg, "ffmpeg"), (ffprobe, "ffprobe")):
    dst = os.path.join(sys.argv[1], name)
    if os.path.lexists(dst):
        os.remove(dst)
    os.symlink(src, dst)
    print("Linked", dst, "->", src)
PYTHON
fi

# Graphviz 'dot' is a system program (no pip package). It is only needed for
# tf.keras.utils.plot_model cells (Modules 02B, 06B, 06C).
if ! type -P dot >/dev/null 2>&1; then
    module load graphviz >/dev/null 2>&1 || true
    hash -r
fi
if type -P dot >/dev/null 2>&1; then
    echo "Graphviz found: $(type -P dot)"
    GRAPHVIZ_OK=1
else
    echo "WARNING: Graphviz 'dot' not found (try: module spider graphviz)." >&2
    echo "         Only the plot_model cells need it; everything else will work." >&2
    GRAPHVIZ_OK=0
fi

echo "Checking package dependencies and recording installed versions..."
PIP_CHECK_OK=1
if ! "$PY" -I -m pip check; then
    PIP_CHECK_OK=0
    echo "WARNING: pip check reported conflicts (above). Continuing to the import tests." >&2
fi
"$PY" -I -m pip list
"$PY" -I -m pip freeze > "$ENV_DIR/requirements-installed.txt"

echo "Testing that every course library imports..."
PATH="$ENV_DIR/bin:$PATH" "$PY" -I - <<'PYTHON'
import importlib
import warnings

warnings.filterwarnings("ignore")
modules = [
    "numpy", "pandas", "scipy", "matplotlib", "seaborn", "tqdm", "requests",
    "PIL", "IPython", "ipywidgets",
    "sklearn", "imblearn",
    "tensorflow", "tensorflow_datasets", "keras_tuner", "pydot",
    "torch", "torchvision",
    "transformers", "timm", "sentencepiece", "huggingface_hub", "diffusers",
    "accelerate", "safetensors",
    "cv2", "mediapipe", "ultralytics", "pycocotools.coco",
    "nltk", "spacy", "gensim.models", "textblob",
    "PyPDF2", "reportlab",
    "flask", "pyngrok", "pexelsapi.pexels", "gtts", "pydub",
    "vertexai", "vertexai.generative_models",
    "google.cloud.storage", "google.cloud.texttospeech",
]
failed = []
for name in modules:
    try:
        importlib.import_module(name)
    except Exception as exc:
        failed.append(f"{name}: {type(exc).__name__}: {exc}")

# Checks for the specific APIs the notebooks call.
checks = {
    "kerastuner (old import name, Module 01D)": lambda: importlib.import_module("kerastuner.tuners"),
    "mediapipe mp.solutions.pose (Module 10B)": lambda: importlib.import_module("mediapipe").solutions.pose,
    "spaCy en_core_web_sm": lambda: importlib.import_module("spacy").load("en_core_web_sm"),
    "spaCy en_core_web_md": lambda: importlib.import_module("spacy").load("en_core_web_md"),
    "NLTK word_tokenize + stopwords + VADER": lambda: (
        importlib.import_module("nltk").word_tokenize("Hello world."),
        importlib.import_module("nltk.corpus").stopwords.words("english"),
        importlib.import_module("nltk.sentiment.vader").SentimentIntensityAnalyzer(),
    ),
    "pydub finds ffmpeg": lambda: (
        importlib.import_module("pydub").AudioSegment.silent(duration=50).export(format="mp3")
    ),
}
warn = []
for label, fn in checks.items():
    try:
        fn()
    except Exception as exc:
        target = warn if label.startswith(("kerastuner", "mediapipe")) else failed
        target.append(f"{label}: {type(exc).__name__}: {exc}")

for line in warn:
    print("WARNING:", line)
if any(w.startswith("kerastuner") for w in warn):
    print("  Fix in Module 01D: use 'from keras_tuner.tuners import RandomSearch'.")
if any(w.startswith("mediapipe") for w in warn):
    print("  This mediapipe build lacks the legacy mp.solutions API used in Module 10B.")
if failed:
    print("\nFAILED:")
    for line in failed:
        print("  ", line)
    raise SystemExit("STOP: Some course libraries failed. Keep the errors above; do not delete the environment.")
print(f"All {len(modules)} course libraries imported.")
PYTHON

echo "Testing actual PyTorch GPU execution..."
"$PY" -I - <<'PYTHON'
import torch

print("PyTorch:", torch.__version__, "| CUDA build:", torch.version.cuda)
if not torch.cuda.is_available():
    raise SystemExit(
        "Packages installed, but PyTorch detected no GPU. "
        "Keep the errors above; do not delete the environment."
    )
x = torch.tensor([[1.0, 2.0], [3.0, 4.0]], device="cuda:0")
result = x @ x
print("PyTorch GPU:", torch.cuda.get_device_name(0))
print("GPU calculation:\n", result.cpu().numpy())
PYTHON

echo "Testing actual TensorFlow GPU execution..."
"$PY" -I - <<'PYTHON'
import sys
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

# Put the environment's bin first on the kernel's PATH, so notebooks find
# ffmpeg/ffprobe (pydub), the env's pip for '!pip', and dot if a module provided it.
"$PY" -m ipykernel install --user --name=535743 --display-name="Python (535743)" \
    --env PATH "$ENV_DIR/bin:$PATH"

echo
echo "SUCCESS: Python $EXPECTED_VERSION, all course libraries, and GPU execution (TensorFlow + PyTorch) passed."
if [[ "$PIP_CHECK_OK" != 1 ]]; then
    echo "NOTE: pip check reported dependency warnings; see above."
fi
if [[ "$GRAPHVIZ_OK" != 1 ]]; then
    echo "NOTE: Graphviz is missing, so only the plot_model cells will not draw diagrams."
fi
echo "Not installable outside Colab: google.colab (comment out 'from google.colab import ...' lines)."
echo "Installed versions: $ENV_DIR/requirements-installed.txt"
echo "To activate in your working terminal, run:"
printf 'module load %s %s && source "%s/bin/activate"\n' \
    "$GCC_MODULE" "$PYTHON_MODULE" "$ENV_DIR"