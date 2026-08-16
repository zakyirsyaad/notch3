#!/usr/bin/env bash
# ==============================================================================
# Notch Agent macOS Standalone Application Packager (.app)
# Bundles the Swift companion shell with embedded Node.js agent runtime daemon
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NotchAgent.app"
BUILD_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🔨 [1/5] Building TypeScript packages and Agent Runtime..."
cd "${ROOT_DIR}"
pnpm --filter "./packages/*" run build

echo "🍏 [2/5] Compiling Swift Native Companion in Release mode..."
cd "${ROOT_DIR}/apps/macos"
swift build -c release

SWIFT_BIN="${ROOT_DIR}/apps/macos/.build/release/NotchAgent"
if [[ ! -f "${SWIFT_BIN}" ]]; then
  # Fallback for alternative binary target name
  SWIFT_BIN="${ROOT_DIR}/apps/macos/.build/release/NotchAgentCore"
fi

echo "📦 [3/5] Constructing macOS App Bundle structure (${APP_BUNDLE})..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}/agent-runtime"

# Copy Swift executable
if [[ -f "${SWIFT_BIN}" ]]; then
  cp "${SWIFT_BIN}" "${MACOS_DIR}/NotchAgent"
  chmod +x "${MACOS_DIR}/NotchAgent"
else
  # Create executable launcher script if built as test package
  cat << 'EOF' > "${MACOS_DIR}/NotchAgent"
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="${SCRIPT_DIR}/../Resources"
echo "[NotchAgent] Launching Native Shell with embedded runtime daemon..."
exec swift run --package-path "$(cd "${SCRIPT_DIR}/../../../../apps/macos" && pwd)"
EOF
  chmod +x "${MACOS_DIR}/NotchAgent"
fi

echo "📦 [4/5] Bundling Node.js Agent Runtime daemon..."
mkdir -p "${RESOURCES_DIR}/agent-runtime/packages/agent-runtime/dist"
mkdir -p "${RESOURCES_DIR}/agent-runtime/packages/shared-types/dist"

cp -R "${ROOT_DIR}/packages/agent-runtime/dist/"* "${RESOURCES_DIR}/agent-runtime/packages/agent-runtime/dist/"
cp -R "${ROOT_DIR}/packages/shared-types/dist/"* "${RESOURCES_DIR}/agent-runtime/packages/shared-types/dist/"
cp "${ROOT_DIR}/packages/agent-runtime/package.json" "${RESOURCES_DIR}/agent-runtime/packages/agent-runtime/"
cp "${ROOT_DIR}/packages/shared-types/package.json" "${RESOURCES_DIR}/agent-runtime/packages/shared-types/"
cp "${ROOT_DIR}/package.json" "${RESOURCES_DIR}/agent-runtime/"
cp "${ROOT_DIR}/pnpm-workspace.yaml" "${RESOURCES_DIR}/agent-runtime/"

echo "📄 [5/5] Generating Info.plist and PkgInfo..."
cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NotchAgent</string>
    <key>CFBundleIdentifier</key>
    <string>com.notch.agent</string>
    <key>CFBundleName</key>
    <string>Notch Agent</string>
    <key>CFBundleDisplayName</key>
    <string>Notch Agent</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Notch Agent. All rights reserved.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "APPL????" > "${CONTENTS_DIR}/PkgInfo"

echo "✨ NotchAgent.app successfully bundled at: ${APP_BUNDLE}"
