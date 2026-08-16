#!/usr/bin/env bash
# ==============================================================================
# Notch Agent macOS Disk Image (.dmg) Installer Packager
# Creates a distributable DMG with a drag-and-drop shortcut to /Applications
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_NAME="NotchAgent.app"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}"
DMG_NAME="NotchAgent-Installer.dmg"
DMG_OUTPUT="${BUILD_DIR}/${DMG_NAME}"
STAGING_DIR="${BUILD_DIR}/dmg-staging"
VOLUME_NAME="Notch Agent"

echo "💿 [1/4] Checking and building NotchAgent.app bundle..."
if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "Bundle not found. Running build-macos-app.sh first..."
  bash "${ROOT_DIR}/scripts/build-macos-app.sh"
fi

echo "📁 [2/4] Setting up DMG staging directory..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# Copy the .app bundle
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"

# Create symbolic link to /Applications for drag-and-drop installation
ln -s /Applications "${STAGING_DIR}/Applications"

echo "⚙️  [3/4] Creating compressed disk image with hdiutil..."
rm -f "${DMG_OUTPUT}"

hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_OUTPUT}"

echo "🧹 [4/4] Cleaning up temporary staging files..."
rm -rf "${STAGING_DIR}"

DMG_SIZE=$(du -h "${DMG_OUTPUT}" | awk '{print $1}')
echo "=============================================================================="
echo "🎉 SUCCESS: macOS Installer Disk Image (.dmg) successfully generated!"
echo "📍 Location: ${DMG_OUTPUT}"
echo "📊 File Size: ${DMG_SIZE}"
echo "💡 Users can double-click this DMG and drag Notch Agent to /Applications"
echo "=============================================================================="
