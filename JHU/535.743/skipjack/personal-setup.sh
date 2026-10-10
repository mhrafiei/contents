#!/usr/bin/env bash
# ============================================================================
# Skipjack GPU VS Code Setup
# ============================================================================
# How to use this script:
#
#   1. Ensure you already have a working JHU Skipjack account, password, and OTP.
#   2. Run this script on your local machine (not on a Skipjack shell):
#          ./setup.sh
#      or:
#          SKIPJACK_USERNAME=your_jhu_username ./setup.sh
#   3. The script will:
#         - create or reuse ~/.ssh/id_skipjack
#         - install the public key onto your Skipjack login account
#         - write the correct ~/.ssh/config entries for skipjack and skipjack-compute
#         - create GPU-focused launcher scripts used by VS Code
#         - configure the VS Code SSH timeout to avoid Slurm allocation timeouts
#   4. After the script finishes, open a local terminal and run:
#          ssh skipjack
#      Enter your password and OTP once. Leave that session open.
#   5. In VS Code, connect to the host named:
#          skipjack-compute
#      or the GPU-specific host:
#          skipjack-gpu
#   6. The default GPU partition is a100, but you can target other Skipjack GPU
#      partitions by setting SKIPJACK_PARTITION before running the script, such as:
#          SKIPJACK_PARTITION=h100 ./setup.sh
#          SKIPJACK_PARTITION=h200 ./setup.sh
#          SKIPJACK_PARTITION=b200 ./setup.sh
#          SKIPJACK_PARTITION=b300 ./setup.sh
#
# What this script is for:
#   This script sets up the SSH and VS Code configuration needed to connect to a
#   compute node on the Skipjack cluster, specifically for GPU workloads. It is
#   designed to match the workflow described by the official ARCH docs for VS Code
#   on Skipjack and to reduce setup friction when using GPU nodes from the
#   hardware page.
#
# Important notes:
#   - Do not run this from inside a Skipjack login shell unless you specifically
#     want to modify remote configuration.
#   - The `skipjack` host is the login host; the `skipjack-compute` and
#     `skipjack-gpu` entries are the actual compute-node targets used by VS Code.
#   - The base master session (`ssh skipjack`) authenticates the login-node hop
#     only; compute-node authentication still uses ~/.ssh/id_skipjack.
#   - If you plan to use a different Slurm account or different GPU partition,
#     set SKIPJACK_ACCOUNT and SKIPJACK_PARTITION before running the script.
#
# Reference: https://docs.arch.jhu.edu/en/latest/1_Clusters/Skipjack/vscode.html
# This page documents the official Skipjack VS Code workflow and the SSH setup
# required to run VS Code on a compute node.
# The script below follows those recommendations and automates as much as possible
# for a Linux/macOS local setup.
# ============================================================================

# Use bash because this script relies on bash-specific features and shell syntax
# that are stable and portable for this setup.
# The `set -Eeuo pipefail` options make the script safer by failing fast on
# errors, stopping on unset variables, and surfacing pipeline failures.
set -Eeuo pipefail

# The base login node that serves as the first SSH hop.

# The base login node that serves as the first SSH hop.
SKIPJACK_HOST="login.arch.jhu.edu"
# The username for the JHU Skipjack account. If the environment variable is already set, reuse it.
# Otherwise the script will ask the user interactively for the login username.
SKIPJACK_USERNAME="${SKIPJACK_USERNAME:-}"
# The local SSH directory where key files and SSH config are stored.
SSH_DIR="${HOME}/.ssh"
# The directory used by SSH ControlMaster sockets so the login-node master session can be reused.
CONTROL_DIR="${SSH_DIR}/cm"
# The private key file used for compute-node SSH authentication.
KEY_PATH="${SSH_DIR}/id_skipjack"
# The public key derived from the private key.
PUB_PATH="${KEY_PATH}.pub"
# The local SSH config file where the login-node and compute-node host entries are written.
SSH_CONFIG_PATH="${SSH_DIR}/config"
# Default Slurm resource settings for the generated launcher script on the cluster.
# The Skipjack hardware page shows multiple GPU node classes such as A100, H100, H200, B200, and B300.
# We default to an A100 GPU session because this is a common research-friendly GPU profile and matches the hardware page's GPU offerings.
SKIPJACK_PARTITION="${SKIPJACK_PARTITION:-a100}"
SKIPJACK_TIME="${SKIPJACK_TIME:-08:00:00}"
SKIPJACK_CPUS="${SKIPJACK_CPUS:-12}"
# Optional Slurm account override; leave empty if you want the default account from your cluster profile.
SKIPJACK_ACCOUNT="${SKIPJACK_ACCOUNT:-}"
# The local VS Code user settings path that we update with the recommended SSH timeout.
VSCODE_SETTINGS_PATH="${HOME}/.config/Code/User/settings.json"
# The fixed GPU host alias used for a dedicated GPU-targeted compute-node connection.
SKIPJACK_GPU_HOST="skipjack-gpu"

# If the username was not provided by the environment, ask the user for it.
# This keeps the script easy to reuse without editing the file for each person.
if [[ -z "${SKIPJACK_USERNAME}" ]]; then
  read -rp "Enter your ARCH username (without @${SKIPJACK_HOST}): " SKIPJACK_USERNAME
fi

# If the username is still empty, stop immediately because every subsequent SSH command depends on it.
if [[ -z "${SKIPJACK_USERNAME}" ]]; then
  echo "Error: SKIPJACK_USERNAME is empty." >&2
  exit 1
fi

# Store the username in both common shell profiles so it is available in future terminal sessions.
# This is the same variable the guide recommends as a convenience for repeated use.
for profile in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [[ -f "${profile}" ]]; then
    if grep -Fq "export SKIPJACK_USERNAME=" "${profile}"; then
      sed -i "s|^export SKIPJACK_USERNAME=.*|export SKIPJACK_USERNAME=\"${SKIPJACK_USERNAME}\"|" "${profile}"
    else
      echo "export SKIPJACK_USERNAME=\"${SKIPJACK_USERNAME}\"" >> "${profile}"
    fi
  fi
done

# Create the SSH directory if it does not exist yet.
mkdir -p "${SSH_DIR}"
# Create the control socket directory for SSH ControlMaster connections.
# The docs say this directory must exist before opening the master session.
mkdir -p "${CONTROL_DIR}"
# Restrict the local SSH directory permissions so only this user can access private keys.
chmod 700 "${SSH_DIR}"
# Restrict the ControlMaster socket directory to the current user for the same reason.
chmod 700 "${CONTROL_DIR}"

# Generate the SSH key pair only if the private key is missing.
# Do not overwrite an existing key because the public key must match the exact private key used by VS Code.
if [[ ! -f "${KEY_PATH}" ]]; then
  ssh-keygen -q -t ed25519 -f "${KEY_PATH}" -C "vscode-skipjack" -N ""
fi

# Regenerate the public key from the actual private key if the public key file is absent or stale.
# The docs explicitly warn not to trust an older .pub file that may no longer match the private key.
if [[ ! -f "${PUB_PATH}" ]]; then
  ssh-keygen -y -f "${KEY_PATH}" > "${PUB_PATH}"
fi

# Ensure the config file exists before appending host blocks.
touch "${SSH_CONFIG_PATH}"
# Make the SSH config file readable and private enough for SSH credential management.
chmod 600 "${SSH_CONFIG_PATH}"

# Add the login-node base SSH host block recommended by the guide.
# This is the block that uses `ControlMaster` and `ControlPersist` so the password + OTP is entered only once.
# It also keeps the SSH control sockets in `~/.ssh/cm` so the master session can be reused.
if ! grep -Fq "Host skipjack" "${SSH_CONFIG_PATH}" 2>/dev/null; then
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

# Add the compute-node host entries used by VS Code.
# We keep both the generic `skipjack-compute` host and a fixed GPU-targeted alias so the user can connect to a GPU node of interest.
# The docs warn not to select the `skipjack` host directly in VS Code — the compute host is the actual remote target.
if ! grep -Fq "Host skipjack-compute" "${SSH_CONFIG_PATH}" 2>/dev/null; then
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

if ! grep -Fq "Host ${SKIPJACK_GPU_HOST}" "${SSH_CONFIG_PATH}" 2>/dev/null; then
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

# Install the official Remote-SSH VS Code extension if the `code` CLI is available.
# This matches the Step 1 recommendation from the guide.
if command -v code >/dev/null 2>&1; then
  code --install-extension ms-vscode-remote.remote-ssh --force >/dev/null 2>&1 || true
fi

# Use Python to merge the recommended VS Code timeout setting into the user settings JSON.
# The guide explicitly says to set `remote.SSH.connectTimeout` to `300` to avoid timing out while Slurm allocates a compute node.
mkdir -p "$(dirname "${VSCODE_SETTINGS_PATH}")"
python3 - "${VSCODE_SETTINGS_PATH}" <<'PY'
import json
import os
import sys

settings_path = sys.argv[1]
settings = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path, 'r', encoding='utf-8') as fh:
            settings = json.load(fh)
    except json.JSONDecodeError:
        settings = {}

settings["remote.SSH.connectTimeout"] = 300
with open(settings_path, 'w', encoding='utf-8') as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
PY

# Copy the public key to the remote JHU login host using `ssh-copy-id`.
# The docs recommend `-f` to force the correct key to be installed even when the login service does not match the key test reliably.
ssh-copy-id -f -i "${PUB_PATH}" "${SKIPJACK_USERNAME}@${SKIPJACK_HOST}" || true

# Ensure the public key is also in the remote `authorized_keys` file for the compute-node authentication path.
# The docs explain that `$HOME` is shared between login and compute nodes, so the key must exist on the login host as well.
PUB_KEY="$(cat "${PUB_PATH}")"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SKIPJACK_USERNAME}@${SKIPJACK_HOST}" \
  "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$PUB_KEY' ~/.ssh/authorized_keys || printf '%s\\n' '$PUB_KEY' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"

# Generate the remote launcher scripts used by the `ProxyCommand` entries.
# The docs say `vscode_job.sh` is installed in `/apps/helpers` and writes `~/vscode-jump.sh` with the actual Slurm allocation logic.
# We create one generic launcher for `skipjack-compute` and one dedicated GPU launcher for the fixed GPU alias `skipjack-gpu`.
if ssh -o BatchMode=yes "${SKIPJACK_USERNAME}@${SKIPJACK_HOST}" "bash -lc 'command -v vscode_job.sh >/dev/null 2>&1'"; then
  ssh -o BatchMode=yes "${SKIPJACK_USERNAME}@${SKIPJACK_HOST}" \
    "bash -lc 'vscode_job.sh --out ~/vscode-jump.sh -p ${SKIPJACK_PARTITION} -t ${SKIPJACK_TIME} --cpus-per-task=${SKIPJACK_CPUS} ${SKIPJACK_ACCOUNT:+-A ${SKIPJACK_ACCOUNT}}'"
  ssh -o BatchMode=yes "${SKIPJACK_USERNAME}@${SKIPJACK_HOST}" \
    "bash -lc 'vscode_job.sh --out ~/vscode-gpu.sh -p ${SKIPJACK_PARTITION} -t ${SKIPJACK_TIME} --cpus-per-task=${SKIPJACK_CPUS} --gres=gpu:1 ${SKIPJACK_ACCOUNT:+-A ${SKIPJACK_ACCOUNT}}'"
else
  ssh -o BatchMode=yes "${SKIPJACK_USERNAME}@${SKIPJACK_HOST}" \
    "bash -lc '/apps/helpers/vscode_job.sh --out ~/vscode-jump.sh -p ${SKIPJACK_PARTITION} -t ${SKIPJACK_TIME} --cpus-per-task=${SKIPJACK_CPUS} ${SKIPJACK_ACCOUNT:+-A ${SKIPJACK_ACCOUNT}}'"
  ssh -o BatchMode=yes "${SKIPJACK_USERNAME}@${SKIPJACK_HOST}" \
    "bash -lc '/apps/helpers/vscode_job.sh --out ~/vscode-gpu.sh -p ${SKIPJACK_PARTITION} -t ${SKIPJACK_TIME} --cpus-per-task=${SKIPJACK_CPUS} --gres=gpu:1 ${SKIPJACK_ACCOUNT:+-A ${SKIPJACK_ACCOUNT}}'"
fi

# Force-copy the local launcher files into the remote home directory so the login-node
# ProxyCommand can execute them reliably from `~/vscode-jump.sh` and `~/vscode-gpu.sh`.
# This is especially helpful when the remote helper script has been regenerated locally
# or when you want to ensure the copy matches the exact local launcher you are testing.
if [[ -f "./vscode-jump.sh" ]]; then
  scp -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_PATH}" "./vscode-jump.sh" "${SKIPJACK_USERNAME}@skipjack:~/vscode-jump.sh"
fi

if [[ -f "./vscode-gpu.sh" ]]; then
  scp -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_PATH}" "./vscode-gpu.sh" "${SKIPJACK_USERNAME}@skipjack:~/vscode-gpu.sh"
fi

# Print a brief completion message and the exact next commands the user should run.
# The guide says the master SSH session must be opened once before using VS Code.
# That is the login-node session that reuses the existing password + OTP authentication.
echo
printf 'Skipjack setup is complete.\n'
printf 'Target GPU partition: %s\n' "${SKIPJACK_PARTITION}"
printf 'Next steps:\n'
printf '  1. Open a local master session: ssh skipjack\n'
printf '  2. Enter your password and OTP once. Leave that session open.\n'
printf '  3. Open VS Code and connect to skipjack-compute or %s\n' "${SKIPJACK_GPU_HOST}"
printf '  4. For other GPU types from the hardware page, set SKIPJACK_PARTITION to a100, h100, h200, b200, or b300, then rerun the script.\n'
printf '\nThe local SSH config was updated with both the login-node and compute-node entries required by the guide.\n'

# The script intentionally does not attempt to open the VS Code UI or SSH client itself.
# The guide recommends opening the master session first and then connecting via VS Code so the login-node password and OTP are entered once, not repeatedly.


