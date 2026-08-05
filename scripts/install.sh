#!/bin/bash
set -euo pipefail

APP_NAME="VideoToGIF"
APP_EXECUTABLE="VideoToGIF"
APP_DEST="${APP_DEST:-/Applications/${APP_NAME}.app}"
REPO="${VIDEO_TO_GIF_REPO:-LeeJunyeolKor/video-to-gif}"
DOWNLOAD_BASE_URL="${VIDEO_TO_GIF_DOWNLOAD_BASE_URL:-https://github.com/${REPO}/releases/latest/download}"
WORK_DIR=""

cleanup() {
    if [ -n "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

ZIP_NAME="${APP_NAME}.zip"
ZIP_URL="${DOWNLOAD_BASE_URL}/${ZIP_NAME}"
CHECKSUM_NAME="${ZIP_NAME}.sha256"
CHECKSUM_URL="${DOWNLOAD_BASE_URL}/${CHECKSUM_NAME}"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/VideoToGIF-install.XXXXXX")
ZIP_PATH="${WORK_DIR}/${ZIP_NAME}"
echo "Downloading the latest ${APP_NAME} release..."
if ! curl -fsSL "$ZIP_URL" -o "$ZIP_PATH"; then
    echo "Error: Could not download ${ZIP_NAME} from the latest GitHub Release."
    echo "Download the app manually from:"
    echo "  https://github.com/${REPO}/releases/latest"
    exit 1
fi

CHECKSUM_PATH="${ZIP_PATH}.sha256"
if ! CHECKSUM_STATUS=$(curl -sSL "$CHECKSUM_URL" -o "$CHECKSUM_PATH" -w '%{http_code}'); then
    echo "Error: Could not reach the GitHub Release checksum."
    exit 1
fi

case "$CHECKSUM_STATUS" in
    200)
        echo "Verifying checksum..."
        EXPECTED=$(awk 'NF { print $1; exit }' "$CHECKSUM_PATH")
        ACTUAL=$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')
        if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
            echo "Error: checksum mismatch for ${ZIP_NAME}."
            echo "  expected: ${EXPECTED:-<missing>}"
            echo "  actual:   ${ACTUAL}"
            echo "Aborting; your existing installation was left untouched."
            exit 1
        fi
        echo "Checksum OK."
        ;;
    404)
        rm -f "$CHECKSUM_PATH"
        echo "Note: latest release publishes no checksum; skipping verification."
        ;;
    *)
        echo "Error: Could not download the release checksum (HTTP ${CHECKSUM_STATUS})."
        exit 1
        ;;
esac

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

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${NEW_APP}/Contents/Info.plist" 2>/dev/null) || true
VERSION="${VERSION:-unknown}"

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
