#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project="$root/NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode.xcodeproj"
name=NotTheInstagramFrameworkCode
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/not-the-instagram.XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# Use the dedicated scheme, which has no post-action, to avoid recursion.
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$work_dir" \
    DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" xcodebuild -project "$project" -scheme FrameworkDeviceBuild -configuration Release -derivedDataPath "$work_dir/derived" \
    -sdk iphoneos CONFIGURATION_BUILD_DIR="$work_dir/products" \
    OBJROOT="$work_dir/intermediates" SYMROOT="$work_dir/build" \
    CLANG_MODULE_CACHE_PATH="$work_dir/module-cache" \
    CODE_SIGNING_ALLOWED=NO build

mkdir -p "$root/latest-framework"
# Keep the previous framework until the new build has succeeded.
ditto "$work_dir/products/$name.framework" "$work_dir/$name.framework"
rm -rf "$root/latest-framework/$name.framework"
mv "$work_dir/$name.framework" "$root/latest-framework/$name.framework"
echo "Framework ready: $root/latest-framework/$name.framework"
