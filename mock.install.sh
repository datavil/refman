#!/bin/sh
set -eu

REPOSITORY="https://github.com/datavil/refman"
SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALLER="$SCRIPT_DIRECTORY/docs/install.sh"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"

eval "$(sed -n '/^render_download_progress()/,/^}/p' "$INSTALLER")"
eval "$(sed -n '/^download_archive()/,/^}/p' "$INSTALLER")"

echo "Finding the latest Refman release..."
release_url="$(curl -LsSf -o /dev/null -w '%{url_effective}' "$REPOSITORY/releases/latest")"

case "$release_url" in
    "$REPOSITORY/releases/tag/"*) tag="${release_url##*/}" ;;
    *) fail "GitHub did not return a latest release" ;;
esac

[ -n "$tag" ] || fail "the latest release has no tag"
archive_url="$REPOSITORY/releases/download/$tag/Refman-$tag.zip"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/refman-download-test.XXXXXX")"
trap 'rm -rf "$temporary_directory"' 0
trap 'exit 1' 1 2 3 15

download_archive "$archive_url" /dev/null "Downloading Refman $tag"
echo "Download complete; data was discarded."
