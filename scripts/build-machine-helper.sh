#!/usr/bin/env bash
set -euo pipefail

# Package the native terminal bridge and tmux into the app, never a user-global install.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?destination resource directory required}"
PACKAGE="$REPO_ROOT/Packages/macOS/CmuxMachineSessions"
TMUX_BIN="${CMUX_MACHINE_TMUX:-/opt/homebrew/bin/tmux}"
[[ -x "$TMUX_BIN" ]] || { echo 'error: tmux is required on the build machine to package the standalone app' >&2; exit 1; }
swift build --package-path "$PACKAGE" --configuration release --product cmux-machine
BUILD_DIR="$(swift build --package-path "$PACKAGE" --configuration release --show-bin-path)"
mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/licenses"
cp "$BUILD_DIR/cmux-machine" "$DEST/bin/cmux-machine"
cp -L "$TMUX_BIN" "$DEST/bin/tmux"
chmod u+w "$DEST/bin/tmux"

sources=("$TMUX_BIN")
targets=("$DEST/bin/tmux")
index=0
while [[ "$index" -lt "${#sources[@]}" ]]; do
    source_binary="${sources[$index]}"
    target_binary="${targets[$index]}"
    while IFS= read -r dependency; do
        case "$dependency" in
            /opt/homebrew/*|/usr/local/*)
                filename="$(basename "$dependency")"
                if [[ ! -f "$DEST/lib/$filename" ]]; then
                    cp -L "$dependency" "$DEST/lib/$filename"
                    chmod u+w "$DEST/lib/$filename"
                    install_name_tool -id "@executable_path/../lib/$filename" "$DEST/lib/$filename"
                    sources+=("$dependency")
                    targets+=("$DEST/lib/$filename")
                fi
                install_name_tool -change "$dependency" "@executable_path/../lib/$filename" "$target_binary"
                ;;
        esac
    done < <(otool -L "$source_binary" | awk 'NR > 1 {print $1}')
    index=$((index + 1))
done
for formula in tmux utf8proc ncurses libevent jemalloc; do
    prefix="$(brew --prefix "$formula")"
    for license in COPYING LICENSE LICENSE.md; do
        if [[ -f "$prefix/$license" ]]; then cp "$prefix/$license" "$DEST/licenses/$formula-$license"; fi
    done
done
for binary in "$DEST"/lib/*.dylib "$DEST/bin/tmux" "$DEST/bin/cmux-machine"; do
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$binary"
done
"$DEST/bin/tmux" -V
