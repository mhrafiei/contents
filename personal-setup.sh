#!/usr/bin/env bash
# ============================================================================
# Skipjack GPU VS Code Setup  (Linux and macOS, including Apple silicon)
# ============================================================================
# How to use this script:
#
#   1. Ensure you already have a working JHU Skipjack account, password, and OTP.
#   2. Run this script on your local machine (not on a Skipjack shell):
#          bash setup.sh
#      or:
#          SKIPJACK_USERNAME=your_jhu_username bash setup.sh
#   3. The script will:
#         - create or reuse ~/.ssh/id_skipjack
#         - open the login-node master session (password + OTP asked ONCE here)
#         - install the public key onto your Skipjack login account
#         - write the correct ~/.ssh/config entries for skipjack and skipjack-compute
#         - create GPU-focused launcher scripts used by VS Code
#         - configure the VS Code SSH timeout to avoid Slurm allocation timeouts
#   4. The master session stays open in the background for 8 hours. After that
#      (or after a reboot), open a local terminal and run:
#          ssh skipjack
#      Enter your password and OTP once. Leave that session open.
#   5. In VS Code, connect to the host named:
#          skipjack-compute
#      or the GPU-specific host:
#          skipjack-gpu
#   6. The default GPU partition is a100, but you can target other Skipjack GPU
#      partitions by setting SKIPJACK_PARTITION before running the script, such as:
#          SKIPJACK_PARTITION=h100 bash setup.sh
#          SKIPJACK_PARTITION=h200 bash setup.sh
#          SKIPJACK_PARTITION=b200 bash setup.sh
#          SKIPJACK_PARTITION=b300 bash setup.sh
#
# What this script is for:
#   This script sets up the SSH and VS Code configuration needed to connect to a
#   compute node on the Skipjack cluster, specifically for GPU workloads. It is
#   designed to match the workflow described by the official ARCH docs for VS Code
#   on Skipjack and to reduce setup friction when using GPU nodes from the
#   hardware page.
#
# macOS notes (Intel and Apple silicon):
#   - Works with the bash 3.2 that ships with macOS; nothing from Homebrew is needed.
#   - Uses macOS's own tools: BSD sed-safe profile edits, the macOS VS Code
#     settings path (~/Library/Application Support/Code/User/settings.json), and
#     JavaScript for Automation (osascript) to edit that JSON, so the python3
#     stub never triggers the "install Command Line Developer Tools" dialog.
#   - Finds the `code` CLI inside "Visual Studio Code.app" even if you never ran
#     "Shell Command: Install 'code' command in PATH".
#   - Saves SKIPJACK_USERNAME in ~/.zshrc (macOS's default shell), creating the
#     file if needed, and in ~/.bashrc / ~/.bash_profile if they exist.
#
# Important notes:
#   - Do not run this from inside a Skipjack login shell unless you specifically
#     want to modify remote configuration.
#   - The `skipjack` host is the login host; the `skipjack-compute` and
#     `skipjack-gpu` entries are the actual compute-node targets used by VS Code.
#   - The base master session (`ssh skipjack`) authenticates the login-node hop
#     only; compute-node authentication still uses ~/.ssh/id_skipjack.
#   - All remote setup steps go through that one master session, so you enter
#     your password and OTP once instead of once per step.
#   - If you plan to use a different Slurm account or different GPU partition,
#     set SKIPJACK_ACCOUNT and SKIPJACK_PARTITION before running the script.
#
# Reference: https://docs.arch.jhu.edu/en/latest/1_Clusters/Skipjack/vscode.html
# ============================================================================

# Fail fast on errors, unset variables and pipeline failures.
set -Eeuo pipefail
trap 'rc=$?; echo "Error: setup stopped at line $LINENO (exit $rc). Read the message above." >&2; exit "$rc"' ERR

# The base login node that serves as the first SSH hop.
SKIPJACK_HOST="login.arch.jhu.edu"
# The username for the JHU Skipjack account. If the environment variable is already set, reuse it.
SKIPJACK_USERNAME="${SKIPJACK_USERNAME:-}"
# The local SSH directory where key files and SSH config are stored.
SSH_DIR="${HOME}/.ssh"
# The directory used by SSH ControlMaster sockets so the login-node master session can be reused.
CONTROL_DIR="${SSH_DIR}/cm"
# The private key file used for compute-node SSH authentication.
KEY_PATH="${SSH_DIR}/id_skipjack"
# The public key derived from the private key.
PUB_PATH="${KEY_PATH}.pub"
# The local SSH config file.
SSH_CONFIG_PATH="${SSH_DIR}/config"
# Default Slurm resource settings for the generated launcher scripts on the cluster.
SKIPJACK_PARTITION="${SKIPJACK_PARTITION:-a100}"
SKIPJACK_TIME="${SKIPJACK_TIME:-08:00:00}"
SKIPJACK_CPUS="${SKIPJACK_CPUS:-12}"
# Optional Slurm account override; leave empty for the default account from your cluster profile.
SKIPJACK_ACCOUNT="${SKIPJACK_ACCOUNT:-}"
# The fixed GPU host alias used for a dedicated GPU-targeted compute-node connection.
SKIPJACK_GPU_HOST="skipjack-gpu"

# ------------------------------------------------------------- platform ---
OS_NAME="$(uname -s)"
case "${OS_NAME}" in
  Darwin)
    IS_MAC=1
    VSCODE_SETTINGS_PATH="${HOME}/Library/Application Support/Code/User/settings.json"
    ;;
  Linux)
    IS_MAC=0
    VSCODE_SETTINGS_PATH="${XDG_CONFIG_HOME:-${HOME}/.config}/Code/User/settings.json"
    ;;
  *)
    echo "Error: unsupported OS '${OS_NAME}'. Use Linux, macOS, or the PowerShell version on Windows." >&2
    exit 1
    ;;
esac

for tool in ssh ssh-keygen scp; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Error: '${tool}' was not found on PATH." >&2
    exit 1
  fi
done

# ------------------------------------------------------------- username ---
if [[ -z "${SKIPJACK_USERNAME}" ]]; then
  read -rp "Enter your ARCH username (without @${SKIPJACK_HOST}): " SKIPJACK_USERNAME
fi
if [[ -z "${SKIPJACK_USERNAME}" ]]; then
  echo "Error: SKIPJACK_USERNAME is empty." >&2
  exit 1
fi

# These values go into the SSH config and remote shell commands, so only allow
# the characters they can legitimately contain.
check_value() {
  if [[ ! "$2" =~ $3 ]]; then
    echo "Error: $1 '$2' contains unexpected characters." >&2
    exit 1
  fi
}
check_value "SKIPJACK_USERNAME"  "${SKIPJACK_USERNAME}"  '^[A-Za-z0-9._-]+$'
check_value "SKIPJACK_PARTITION" "${SKIPJACK_PARTITION}" '^[A-Za-z0-9_-]+$'
check_value "SKIPJACK_TIME"      "${SKIPJACK_TIME}"      '^[0-9:-]+$'
check_value "SKIPJACK_CPUS"      "${SKIPJACK_CPUS}"      '^[0-9]+$'
if [[ -n "${SKIPJACK_ACCOUNT}" ]]; then
  check_value "SKIPJACK_ACCOUNT" "${SKIPJACK_ACCOUNT}" '^[A-Za-z0-9._-]+$'
fi

# Store the username in the shell profiles so it is available in future terminals.
# Uses a temp file instead of `sed -i`, whose syntax differs between GNU (Linux)
# and BSD (macOS) sed. `cat >` keeps the profile's permissions and symlinks.
save_username() {
  local profile="$1"
  local line="export SKIPJACK_USERNAME=\"${SKIPJACK_USERNAME}\""
  if grep -q '^export SKIPJACK_USERNAME=' "${profile}"; then
    local tmp
    tmp="$(mktemp)"
    awk -v line="${line}" '/^export SKIPJACK_USERNAME=/ { print line; next } { print }' "${profile}" > "${tmp}"
    cat "${tmp}" > "${profile}"
    rm -f "${tmp}"
  else
    printf '\n%s\n' "${line}" >> "${profile}"
  fi
}
# macOS's default shell is zsh, and a new Mac may not have ~/.zshrc yet.
if [[ "${IS_MAC}" == 1 && "${SHELL:-}" == */zsh && ! -e "${HOME}/.zshrc" ]]; then
  touch "${HOME}/.zshrc"
fi
for profile in "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.zshrc"; do
  if [[ -f "${profile}" ]]; then
    save_username "${profile}"
  fi
done

# --------------------------------------------------------------- SSH key ---
mkdir -p "${SSH_DIR}" "${CONTROL_DIR}"
chmod 700 "${SSH_DIR}" "${CONTROL_DIR}"

# Generate the key pair only if the private key is missing. Never overwrite it,
# because the public key must match the exact private key used by VS Code.
if [[ ! -f "${KEY_PATH}" ]]; then
  ssh-keygen -q -t ed25519 -f "${KEY_PATH}" -C "vscode-skipjack" -N ""
fi

# Regenerate the public key from the actual private key if the .pub file is absent.
if [[ ! -f "${PUB_PATH}" ]]; then
  ssh-keygen -y -f "${KEY_PATH}" > "${PUB_PATH}"
fi
PUB_KEY="$(head -n 1 "${PUB_PATH}")"
if [[ ! "${PUB_KEY}" =~ ^ssh-[A-Za-z0-9-]+\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9._@-]+)?$ ]]; then
  echo "Error: ${PUB_PATH} does not look like a single OpenSSH public key." >&2
  exit 1
fi

# ------------------------------------------------------------ SSH config ---
touch "${SSH_CONFIG_PATH}"
chmod 600 "${SSH_CONFIG_PATH}"

# True if a "Host" line for exactly this alias exists. (A plain substring match
# would treat "Host skipjack-compute" as if "Host skipjack" were present.)
has_host() {
  grep -Eq "^[[:space:]]*Host[[:space:]]+(.*[[:space:]])?$1([[:space:]]|\$)" "${SSH_CONFIG_PATH}"
}

# Login-node base block with ControlMaster/ControlPersist, so the password + OTP
# is entered only once and the master session is reused from ~/.ssh/cm.
if ! has_host "skipjack"; then
  cat >> "${SSH_CONFIG_PATH}" <<EOF

# ==== Skipjack: base connection (password + OTP entered here once) ====
Host skipjack
    HostName ${SKIPJACK_HOST}
    User ${SKIPJACK_USERNAME}
    IdentityFile ${KEY_PATH}
    ControlMaster auto
    ControlPersist 8h
    ControlPath ${CONTROL_DIR}/%C
    ServerAliveInterval 60
EOF
fi

# Compute-node entries used by VS Code. Do not select `skipjack` itself in VS Code.
if ! has_host "skipjack-compute"; then
  cat >> "${SSH_CONFIG_PATH}" <<EOF

# ==== Skipjack: generic allocated compute node ====
Host skipjack-compute
    User ${SKIPJACK_USERNAME}
    IdentityFile ${KEY_PATH}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyCommand ssh skipjack "~/vscode-jump.sh"
EOF
fi

if ! has_host "${SKIPJACK_GPU_HOST}"; then
  cat >> "${SSH_CONFIG_PATH}" <<EOF

# ==== Skipjack: GPU-specific allocated compute node ====
Host ${SKIPJACK_GPU_HOST}
    User ${SKIPJACK_USERNAME}
    IdentityFile ${KEY_PATH}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyCommand ssh skipjack "~/vscode-gpu.sh"
EOF
fi

# --------------------------------------------------------------- VS Code ---
# Install the Remote-SSH extension. On macOS the `code` CLI is often not on
# PATH, so also look inside the app bundle.
CODE_CLI=""
if command -v code >/dev/null 2>&1; then
  CODE_CLI="$(command -v code)"
elif [[ "${IS_MAC}" == 1 ]]; then
  for app in "/Applications/Visual Studio Code.app" "${HOME}/Applications/Visual Studio Code.app"; do
    if [[ -x "${app}/Contents/Resources/app/bin/code" ]]; then
      CODE_CLI="${app}/Contents/Resources/app/bin/code"
      break
    fi
  done
fi
if [[ -n "${CODE_CLI}" ]]; then
  "${CODE_CLI}" --install-extension ms-vscode-remote.remote-ssh --force >/dev/null 2>&1 || true
else
  echo "Note: VS Code CLI not found; install the 'Remote - SSH' extension from VS Code yourself."
fi

# Merge "remote.SSH.connectTimeout": 300 into the VS Code user settings, so VS Code
# does not time out while Slurm allocates a node. A settings file that cannot be
# parsed (e.g. it has comments) is left untouched instead of being reset.
mkdir -p "$(dirname "${VSCODE_SETTINGS_PATH}")"
SETTINGS_OK=1
if [[ "${IS_MAC}" == 1 ]]; then
  # JavaScript for Automation ships with every macOS; no python3 or Xcode tools needed.
  JXA_SCRIPT="$(mktemp)"
  cat > "${JXA_SCRIPT}" <<'JS'
ObjC.import('Foundation');
function run(argv) {
  var path = argv[0];
  var settings = {};
  if ($.NSFileManager.defaultManager.fileExistsAtPath(path)) {
    var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    if (text.isNil()) { throw new Error('cannot read ' + path); }
    text = ObjC.unwrap(text);
    if (text.trim() !== '') { settings = JSON.parse(text); }
  }
  settings['remote.SSH.connectTimeout'] = 300;
  var out = $(JSON.stringify(settings, null, 2) + '\n');
  if (!out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
    throw new Error('cannot write ' + path);
  }
  return 'ok';
}
JS
  osascript -l JavaScript "${JXA_SCRIPT}" "${VSCODE_SETTINGS_PATH}" >/dev/null 2>&1 || SETTINGS_OK=0
  rm -f "${JXA_SCRIPT}"
else
  python3 - "${VSCODE_SETTINGS_PATH}" <<'PY' || SETTINGS_OK=0
import json
import os
import sys

settings_path = sys.argv[1]
settings = {}
if os.path.exists(settings_path):
    with open(settings_path, 'r', encoding='utf-8') as fh:
        text = fh.read()
    if text.strip():
        settings = json.loads(text)   # raises on comments -> file left untouched

settings["remote.SSH.connectTimeout"] = 300
with open(settings_path, 'w', encoding='utf-8') as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
PY
fi
if [[ "${SETTINGS_OK}" != 1 ]]; then
  echo "WARNING: Could not update ${VSCODE_SETTINGS_PATH} automatically (it may contain comments)." >&2
  echo '         Add this line to it yourself:  "remote.SSH.connectTimeout": 300' >&2
fi

# ------------------------------------------------ remote setup (one login) ---
# The first `ssh skipjack` asks for your password + OTP and starts the
# ControlMaster session (kept for 8h). Every later step reuses it, so nothing
# asks again. ssh-copy-id is not needed (and is missing on older macOS).
echo
echo "Connecting to ${SKIPJACK_HOST}. Enter your password and OTP when prompted."
ssh -o StrictHostKeyChecking=accept-new skipjack true

# Install the public key in the remote authorized_keys. $HOME is shared between
# login and compute nodes, which authenticate with this key.
ssh skipjack "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '${PUB_KEY}' ~/.ssh/authorized_keys || printf '%s\\n' '${PUB_KEY}' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
echo "Public key installed on Skipjack."

# Generate the launcher scripts used by the ProxyCommand entries with
# vscode_job.sh (on PATH in a login shell, or in /apps/helpers).
JOB_ARGS="-p ${SKIPJACK_PARTITION} -t ${SKIPJACK_TIME} --cpus-per-task=${SKIPJACK_CPUS}${SKIPJACK_ACCOUNT:+ -A ${SKIPJACK_ACCOUNT}}"
if ssh skipjack "bash -lc 'command -v vscode_job.sh >/dev/null 2>&1'"; then
  VSCODE_JOB="vscode_job.sh"
else
  VSCODE_JOB="/apps/helpers/vscode_job.sh"
fi
ssh skipjack "bash -lc '${VSCODE_JOB} --out ~/vscode-jump.sh ${JOB_ARGS}'"
ssh skipjack "bash -lc '${VSCODE_JOB} --out ~/vscode-gpu.sh ${JOB_ARGS} --gres=gpu:1'"
echo "Launchers written on Skipjack: ~/vscode-jump.sh and ~/vscode-gpu.sh"

# Optionally copy local launcher files over the generated ones, so the login node
# runs the exact launchers you are testing. Uses the same master session.
for launcher in vscode-jump.sh vscode-gpu.sh; do
  if [[ -f "./${launcher}" ]]; then
    scp "./${launcher}" "skipjack:${launcher}"
    ssh skipjack "chmod +x ~/${launcher}"
    echo "Copied local ${launcher} to Skipjack."
  fi
done

# ------------------------------------------------------------------ done ---
echo
printf 'Skipjack setup is complete.\n'
printf 'Target GPU partition: %s\n' "${SKIPJACK_PARTITION}"
printf 'Next steps:\n'
printf '  1. The master session is already open for the next 8 hours. After that (or a reboot),\n'
printf '     run in a local terminal: ssh skipjack   (enter password + OTP once, leave it open)\n'
printf '  2. Open VS Code and connect to skipjack-compute or %s\n' "${SKIPJACK_GPU_HOST}"
printf '  3. For other GPU types, set SKIPJACK_PARTITION to a100, h100, h200, b200, or b300, then rerun the script.\n'
if [[ "${SETTINGS_OK}" != 1 ]]; then
  printf '  4. Add "remote.SSH.connectTimeout": 300 to your VS Code settings (see the warning above).\n'
fi
printf '\nThe local SSH config (%s) has the skipjack, skipjack-compute and %s entries.\n' "${SSH_CONFIG_PATH}" "${SKIPJACK_GPU_HOST}"