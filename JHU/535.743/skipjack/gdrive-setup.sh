#!/bin/bash
set -e

echo "Creating local bin directory..."
mkdir -p ~/.local/bin

echo "Downloading rclone..."
cd /tmp
wget -qO rclone.zip https://downloads.rclone.org/rclone-current-linux-amd64.zip

echo "Extracting rclone binary..."
unzip -q -j rclone.zip "*/rclone" -d ~/.local/bin/

echo "Making rclone executable..."
chmod +x ~/.local/bin/rclone

echo "Cleaning up..."
rm rclone.zip

echo "Adding ~/.local/bin to PATH in .bashrc..."
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
export PATH="$HOME/.local/bin:$PATH"

echo "Installation complete! Rclone is installed in ~/.local/bin/"