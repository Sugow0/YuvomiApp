#!/bin/zsh
# Archives Yuvomi and uploads it to TestFlight with the Apple account signed in to Xcode.
# Usage: scripts/testflight.sh [ios|macos]   (default: ios)
set -euo pipefail
cd "${0:A:h}/.."

platform=${1:-ios}
case $platform in
  ios)   destination="generic/platform=iOS" ;;
  macos) destination="generic/platform=macOS" ;;
  *)     echo "usage: $0 [ios|macos]" >&2; exit 64 ;;
esac

# Each upload needs a new build number; a timestamp always grows.
build=$(date +%Y%m%d%H%M)
archive="build/Yuvomi-$platform.xcarchive"

xcodegen generate
xcodebuild -project Yuvomi.xcodeproj -scheme Yuvomi -configuration Release \
  -destination "$destination" -archivePath "$archive" \
  CURRENT_PROJECT_VERSION="$build" -allowProvisioningUpdates archive | grep -E "error:|warning: .*signing|ARCHIVE" || true
[[ -d $archive ]] || { echo "Archive failed" >&2; exit 1; }

xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "build/export-$platform" -allowProvisioningUpdates
echo "Uploaded $platform build $build — it shows in TestFlight after Apple's processing (5–15 min)."
