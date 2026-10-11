#!/bin/bash
set -e

# 1. INSTALL RCLONE LOCALLY (No sudo required)
echo "=== Step 1: Installing Rclone ==="
mkdir -p ~/.local/bin
cd /tmp
wget -qO rclone.zip https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip -q -j rclone.zip "*/rclone" -d ~/.local/bin/
chmod +x ~/.local/bin/rclone
rm rclone.zip

export PATH="$HOME/.local/bin:$PATH"
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi

# 2. AUTOMATE CONFIGURATION
CONFIG_DIR="$HOME/.config/rclone"
CONFIG_FILE="$CONFIG_DIR/rclone.conf"
mkdir -p "$CONFIG_DIR"

echo ""
echo "=== Step 2: Authentication ==="
echo "Because this server has no web browser, you must authorize Google Drive from your LOCAL computer."
echo ""
echo "DO THIS ON YOUR LOCAL COMPUTER (Windows/Mac/Linux):"
echo "  1. Download rclone locally (https://rclone.org/downloads/)"
echo "  2. Open your local terminal/command prompt and run:"
echo "     rclone authorize \"drive\""
echo "  3. Log into Google in the browser window that opens."
echo "  4. Copy the entire token code it outputs (it starts with { and ends with })."
echo ""

# Prompt user to paste the token
read -p "Paste the complete token here and press Enter: " RCLONE_TOKEN

# Write the config file programmatically
echo "Writing configuration to $CONFIG_FILE..."
cat <<EOF > "$CONFIG_FILE"
[gdrive]
type = drive
scope = drive
token = $RCLONE_TOKEN
team_drive =
EOF

# 3. MOUNT THE DRIVE
echo ""
echo "=== Step 3: Mounting Google Drive ==="
MOUNT_DIR="$HOME/GoogleDrive"
mkdir -p "$MOUNT_DIR"

echo "Attempting to mount Google Drive to $MOUNT_DIR..."
# The --daemon flag runs it in the background so it doesn't block your terminal
rclone mount gdrive: "$MOUNT_DIR" --daemon

echo ""
echo "================================================="
echo "Success! Your script has finished."
echo "Check your files by running: ls $MOUNT_DIR"
echo "================================================="