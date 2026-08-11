#!/usr/bin/env bash
# Install a symlink rather than copying the executable so a checked-out update
# becomes active atomically without creating a second, drifting program copy.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

source="$ROOT/bin/ettun"
target="$BIN_DIR/ettun"
if [[ ! -f "$source" || ! -x "$source" ]]; then
  printf 'ettun: command source is not executable: %s\n' "$source" >&2
  exit 1
fi
if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
  printf 'ettun: refusing to replace non-symlink path: %s\n' "$target" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
ln -sfn "$source" "$target"

printf 'installed ettun to %s\n' "$BIN_DIR"
