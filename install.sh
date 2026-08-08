#!/usr/bin/env bash
# Install a symlink rather than copying the executable so a checked-out update
# becomes active atomically without creating a second, drifting program copy.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

mkdir -p "$BIN_DIR"
ln -sf "$ROOT/bin/ettun" "$BIN_DIR/ettun"

printf 'installed ettun to %s\n' "$BIN_DIR"
