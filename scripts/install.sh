#!/bin/bash
set -euo pipefail

APP_NAME="VideoToGIF"
APP_EXECUTABLE="VideoToGIF"
APP_DEST="${APP_DEST:-/Applications/${APP_NAME}.app}"
REPO="${VIDEO_TO_GIF_REPO:-LeeJunyeolKor/video-to-gif}"
RELEASE_API_URL="${VIDEO_TO_GIF_RELEASE_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"
WORK_DIR=""

cleanup() {
    if [ -n "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

asset_url() {
    asset_name="$1"
    printf '%s\n' "$RELEASE_JSON" \
        | grep -o "\"browser_download_url\": *\"[^\"]*${asset_name}\"" \
        | head -n 1 \
        | sed 's/.*"browser_download_url": *"//;s/"$//'
}

echo "Fetching the latest VideoToGIF release..."
RELEASE_JSON=$(curl -fsSL "$RELEASE_API_URL") || true
if [ -z "$RELEASE_JSON" ]; then
    echo "Error: Could not reach the GitHub releases API."
    echo "Download the app manually from:"
    echo "  https://github.com/${REPO}/releases/latest"
    exit 1
fi

VERSION=$(printf '%s\n' "$RELEASE_JSON" \
    | grep -m 1 '"tag_name"' \
    | sed 's/.*"tag_name": *"//;s/".*//') || true
if [ -z "$VERSION" ]; then
    echo "Error: Failed to parse the latest release information."
    exit 1
fi

ZIP_NAME="${APP_NAME}.zip"
ZIP_URL=$(asset_url "$ZIP_NAME") || true
if [ -z "$ZIP_URL" ]; then
    echo "Error: Release ${VERSION} has no asset named ${ZIP_NAME}."
    exit 1
fi

echo "Latest version: ${VERSION}"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/VideoToGIF-install.XXXXXX")
ZIP_PATH="${WORK_DIR}/${ZIP_NAME}"
echo "Downloading ${ZIP_NAME}..."
curl -fsSL "$ZIP_URL" -o "$ZIP_PATH"

CHECKSUM_NAME="${ZIP_NAME}.sha256"
CHECKSUM_URL=$(asset_url "$CHECKSUM_NAME") || true
if [ -n "$CHECKSUM_URL" ]; then
    echo "Verifying checksum..."
    curl -fsSL "$CHECKSUM_URL" -o "${ZIP_PATH}.sha256"
    EXPECTED=$(awk 'NF { print $1; exit }' "${ZIP_PATH}.sha256")
    ACTUAL=$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')
    if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "Error: checksum mismatch for ${ZIP_NAME}."
        echo "  expected: ${EXPECTED:-<missing>}"
        echo "  actual:   ${ACTUAL}"
        echo "Aborting; your existing installation was left untouched."
        exit 1
    fi
    echo "Checksum OK."
else
    echo "Note: release ${VERSION} publishes no checksum; skipping verification."
fi

echo "Extracting and validating the app..."
EXTRACT_DIR="${WORK_DIR}/extract"
mkdir -p "$EXTRACT_DIR"
ditto -xk "$ZIP_PATH" "$EXTRACT_DIR"
NEW_APP="${EXTRACT_DIR}/${APP_NAME}.app"
if [ ! -d "$NEW_APP" ]; then
    NEW_APP=$(find "$EXTRACT_DIR" -type d -name "${APP_NAME}.app" -print -quit)
fi
if [ -z "$NEW_APP" ] || [ ! -x "${NEW_APP}/Contents/MacOS/${APP_EXECUTABLE}" ]; then
    echo "Error: downloaded archive does not contain a usable ${APP_NAME}.app."
    echo "Aborting; your existing installation was left untouched."
    exit 1
fi

# A curl download normally has no quarantine attribute. Clear it anyway so
# manually supplied/reused archives behave consistently.
xattr -cr "$NEW_APP"

if pgrep -x "$APP_EXECUTABLE" > /dev/null 2>&1; then
    echo "Quitting the running ${APP_NAME}..."
    pkill -x "$APP_EXECUTABLE" || true
    sleep 1
fi

mkdir -p "$(dirname "$APP_DEST")"
if [ -d "$APP_DEST" ]; then
    echo "Replacing the existing ${APP_NAME} installation..."
    rm -rf "$APP_DEST"
fi
mv "$NEW_APP" "$APP_DEST"

if [ "${VIDEO_TO_GIF_SKIP_OPEN:-0}" != "1" ]; then
    echo "Launching ${APP_NAME}..."
    open "$APP_DEST"
fi

echo "Done! ${APP_NAME} ${VERSION} installed at ${APP_DEST}."
