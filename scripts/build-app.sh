#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./scripts/build-app.sh [--arch arm64|x86_64|universal2] [--output-dir DIRECTORY]

Build a local, ad-hoc-signed Agent Trail.app and a ZIP with SHA-256 checksum.
The default architecture is this machine's architecture (or ARCH).
The default output directory is this repository's dist/ folder.
AGENTTRAIL_BUILD_DIR optionally selects a separate Swift build cache.

This script does not install, launch, quit, or restart any application.
USAGE
}

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="$task_root/dist"
target_arch="${ARCH:-$(uname -m)}"
build_root="${AGENTTRAIL_BUILD_DIR:-$task_root/.build}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch|--output-dir)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                printf 'Missing value for %s\n' "$1" >&2
                exit 2
            fi
            if [[ "$1" == --arch ]]; then
                target_arch="$2"
            else
                output_root="$2"
            fi
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$target_arch" in
    arm64|x86_64|universal2) ;;
    *) printf 'Unsupported architecture: %s\n' "$target_arch" >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Agent Trail requires macOS to build.\n' >&2
    exit 1
fi

mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"
app_path="$output_root/Agent Trail.app"
archive_name="Agent-Trail-macOS-$target_arch.zip"

# Build the executable before touching an existing bundle. Rebuilding never
# interacts with Claude or with a running Agent Trail process.
cd "$task_root"
build_binary() {
    local arch="$1"
    local triple="$arch-apple-macosx14.0"
    swift build --scratch-path "$build_root" -c release --triple "$triple" \
        --disable-index-store -debug-info-format none --product AgentTrail
}
binary_path() {
    local arch="$1"
    swift build --scratch-path "$build_root" -c release \
        --triple "$arch-apple-macosx14.0" --show-bin-path
}

if [[ "$target_arch" == universal2 ]]; then
    build_binary arm64
    build_binary x86_64
else
    build_binary "$target_arch"
fi

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/agenttrail-package.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
staged_app="$staging_root/Agent Trail.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
if [[ "$target_arch" == universal2 ]]; then
    /usr/bin/lipo -create "$(binary_path arm64)/AgentTrail" \
        "$(binary_path x86_64)/AgentTrail" -output "$staged_app/Contents/MacOS/AgentTrail"
    /usr/bin/lipo "$staged_app/Contents/MacOS/AgentTrail" -verify_arch arm64 x86_64
else
    cp "$(binary_path "$target_arch")/AgentTrail" "$staged_app/Contents/MacOS/AgentTrail"
    /usr/bin/lipo "$staged_app/Contents/MacOS/AgentTrail" -verify_arch "$target_arch"
fi

# Strip source-level debugging information from distributed executables.
/usr/bin/strip -S "$staged_app/Contents/MacOS/AgentTrail"
cp "$task_root/scripts/Info.plist" "$staged_app/Contents/Info.plist"
cp "$task_root/scripts/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
cp "$task_root/LICENSE" "$staged_app/Contents/Resources/LICENSE.txt"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"

# Copy only the assembled bundle; profile records and caches are never packaged.
/usr/bin/ditto "$staged_app" "$app_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$output_root/$archive_name"
(
    cd "$output_root"
    LC_ALL=C /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
printf 'Built: %s\nArchive: %s\n' "$app_path" "$output_root/$archive_name"
