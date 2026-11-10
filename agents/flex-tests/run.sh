#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nti-flex-test.XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$work_dir/modules" \
  -I"$root/agents/flex-tests/Fakes" -framework Foundation \
  "$root/agents/flex-tests/window_activation.m" -o "$work_dir/window_activation"
"$work_dir/window_activation"
