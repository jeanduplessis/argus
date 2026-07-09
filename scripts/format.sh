#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -n "${SWIFT_FORMAT_BIN:-}" ]]; then
  swift_format_bin="$SWIFT_FORMAT_BIN"
elif command -v swift-format >/dev/null 2>&1; then
  swift_format_bin="$(command -v swift-format)"
elif swift_format_path="$(xcrun --find swift-format 2>/dev/null)"; then
  swift_format_bin="$swift_format_path"
else
  echo "error: swift-format not found. Use Swift 6 or install it with: brew install swift-format" >&2
  exit 1
fi

if [[ ! -x "$swift_format_bin" ]]; then
  echo "error: swift-format is not executable: $swift_format_bin" >&2
  exit 1
fi

cd "$project_root"
"$swift_format_bin" format \
  --configuration "$project_root/.swift-format" \
  --recursive \
  --parallel \
  --in-place \
  Argus ArgusCLI Tests Package.swift
