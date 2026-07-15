#!/bin/sh
set -eu

REPOSITORY="https://github.com/datavil/refman"
INSTALL_DIRECTORY="${REFMAN_INSTALL_DIRECTORY:-/Applications}"
APP_PATH="$INSTALL_DIRECTORY/Refman.app"

fail() {
    echo "error: $*" >&2
    exit 1
}

render_download_progress() {
    progress_label="$1"
    progress_color=true
    [ -n "${NO_COLOR:-}" ] && progress_color=false

    awk \
        -v 'RS=\r' \
        -v "label=$progress_label" \
        -v "color=$progress_color" '
        function draw(percent, complete, bar, remainder, i) {
            complete = int(percent * 24 / 100)
            bar = ""
            remainder = ""
            for (i = 0; i < complete; i++) bar = bar "━"
            for (i = complete; i < 24; i++) remainder = remainder "─"
            printf "\r\033[2K  %s  %s%s%s%s%s  %3d%%", \
                label, accent, bar, dim, remainder, reset, percent
            fflush()
        }

        BEGIN {
            if (color == "true") {
                accent = sprintf("%c[36m", 27)
                dim = sprintf("%c[2m", 27)
                reset = sprintf("%c[0m", 27)
            }
            draw(0)
        }

        match($0, /[0-9][0-9]*\.[0-9]%/) {
            percent = int(substr($0, RSTART, RLENGTH - 1) + 0)
            if (percent != last_percent) {
                draw(percent)
                last_percent = percent
            }
        }

        index($0, "curl:") > 0 { errors = errors $0 "\n" }

        END {
            printf "\n"
            if (errors != "") printf "%s", errors
        }
    ' >&2
}

download_archive() {
    download_url="$1"
    download_destination="$2"
    download_label="$3"

    if [ ! -t 2 ] || [ "${TERM:-dumb}" = "dumb" ]; then
        echo "$download_label..."
        curl -fLsS "$download_url" -o "$download_destination"
        return
    fi

    progress_status_file="$temporary_directory/curl-status"
    {
        download_status=0
        curl -fL --progress-bar "$download_url" -o "$download_destination" \
            2>&1 || download_status=$?
        printf '%s\n' "$download_status" > "$progress_status_file"
    } | render_download_progress "$download_label"

    download_status="$(cat "$progress_status_file")"
    rm -f "$progress_status_file"
    return "$download_status"
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

download_archive "$archive_url" "$archive" "Downloading Refman $tag"
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
