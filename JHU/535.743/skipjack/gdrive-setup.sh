#!/bin/bash

# Exit script if any command fails
set -e

echo "Adding the google-drive-ocamlfuse PPA..."
sudo add-apt-repository -y ppa:alessandro-strada/ppa

echo "Updating package lists..."
sudo apt update

echo "Installing google-drive-ocamlfuse..."
sudo apt install -y google-drive-ocamlfuse

echo "Creating the mount directory at ~/GoogleDrive..."
mkdir -p ~/GoogleDrive

echo "================================================="
echo "Installation complete!"
echo ""
echo "Since you are on a remote terminal (headless), you must authenticate manually:"
echo "1. Run this command to generate an auth link: google-drive-ocamlfuse -headless"
echo "2. Copy the provided URL and open it in a web browser on your local machine."
echo "3. Log into your Google account, allow access, and copy the verification code."
echo "4. Paste the code back into your remote terminal."
echo ""
echo "Once authenticated, mount your drive by running: google-drive-ocamlfuse ~/GoogleDrive"
echo "================================================="