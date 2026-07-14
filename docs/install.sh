#!/bin/sh
set -eu

REPOSITORY="https://github.com/datavil/refman"
INSTALL_DIRECTORY="${REFMAN_INSTALL_DIRECTORY:-/Applications}"
APP_PATH="$INSTALL_DIRECTORY/Refman.app"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
[ "$(uname -s)" = "Darwin" ] || fail "Refman requires macOS"
[ -d "$INSTALL_DIRECTORY" ] || fail "install directory does not exist: $INSTALL_DIRECTORY"

echo "Finding the latest Refman release..."
release_url="$(curl -LsSf -o /dev/null -w '%{url_effective}' "$REPOSITORY/releases/latest")"

case "$release_url" in
    "$REPOSITORY/releases/tag/"*) tag="${release_url##*/}" ;;
    *) fail "GitHub did not return a latest release" ;;
esac

[ -n "$tag" ] || fail "the latest release has no tag"
archive_url="$REPOSITORY/releases/download/$tag/Refman-$tag.zip"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/refman-install.XXXXXX")"
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

archive="$temporary_directory/Refman.zip"
unpacked="$temporary_directory/unpacked"
mkdir "$unpacked"

echo "Downloading Refman $tag..."
curl -fL --progress-bar "$archive_url" -o "$archive"
/usr/bin/ditto -x -k "$archive" "$unpacked"

new_app="$unpacked/Refman.app"
[ -x "$new_app/Contents/MacOS/Refman" ] || fail "the release does not contain Refman.app"
/usr/bin/codesign --verify --deep --strict "$new_app" 2>/dev/null \
    || fail "the downloaded app has an invalid code signature"

needs_sudo=false
if [ "$(id -u)" -ne 0 ]; then
    if [ ! -w "$INSTALL_DIRECTORY" ] || { [ -e "$APP_PATH" ] && [ ! -w "$APP_PATH" ]; }; then
        needs_sudo=true
        echo "Administrator access is needed to install in $INSTALL_DIRECTORY."
        /usr/bin/sudo -v
    fi
fi

run_installer() {
    if [ "$needs_sudo" = true ]; then
        /usr/bin/sudo "$@"
    else
        "$@"
    fi
}

echo "Installing Refman in $INSTALL_DIRECTORY..."
run_installer /bin/rm -rf "$APP_PATH"
run_installer /usr/bin/ditto "$new_app" "$APP_PATH"

# The release is ad-hoc signed until Developer ID enrollment is available.
# Clear Gatekeeper's quarantine recursively on every fresh installation. The
# in-app updater performs the same step whenever it replaces this bundle.
run_installer /usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "Refman $tag is installed."
if [ "${REFMAN_SKIP_OPEN:-0}" != "1" ]; then
    /usr/bin/open "$APP_PATH"
fi
