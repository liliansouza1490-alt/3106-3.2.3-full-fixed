#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PLIST="$ROOT/ThreeOneOSSix/Info.plist"
PROJECT="$ROOT/ThreeOneOSSix.xcodeproj/project.pbxproj"

# A stale AppReleaseDisplayVersion (3.1.4) used to make the update checker
# report a newer version forever. Keep the single source of truth.
if /usr/libexec/PlistBuddy -c "Print :AppReleaseDisplayVersion" "$PLIST" >/dev/null 2>&1; then
  echo "FAIL: Info.plist still contains AppReleaseDisplayVersion" >&2
  exit 1
fi

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
PROJECT_VERSION=$(grep -m1 "MARKETING_VERSION = " "$PROJECT" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/')
if [[ "$PLIST_VERSION" != "$PROJECT_VERSION" ]]; then
  echo "FAIL: Info.plist version $PLIST_VERSION != project $PROJECT_VERSION" >&2
  exit 1
fi

PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
PROJECT_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$PROJECT" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/')
if [[ "$PLIST_BUILD" != "$PROJECT_BUILD" ]]; then
  echo "FAIL: Info.plist build $PLIST_BUILD != project $PROJECT_BUILD" >&2
  exit 1
fi

# Localization keys must be identical across the three language bundles;
# a missing key renders the raw key string in the UI.
"$ROOT/Tests/check_strings_alignment.sh"

swiftc -O \
  "$ROOT/ThreeOneOSSix/helpers/SupportPolicy.swift" \
  "$ROOT/ThreeOneOSSix/helpers/LaunchServicesStore.swift" \
  "$ROOT/ThreeOneOSSix/helpers/ContainerBrowserLogic.swift" \
  "$ROOT/ThreeOneOSSix/helpers/FileBrowserMetadata.swift" \
  "$ROOT/ThreeOneOSSix/helpers/CleanerCatalog.swift" \
  "$ROOT/ThreeOneOSSix/helpers/CleanerSafetyPolicy.swift" \
  "$ROOT/ThreeOneOSSix/helpers/CleanerHistory.swift" \
  "$ROOT/ThreeOneOSSix/helpers/ActivityHistory.swift" \
  "$ROOT/ThreeOneOSSix/helpers/AltStoreSourceAdapter.swift" \
  "$ROOT/ThreeOneOSSix/helpers/AppVersionComparison.swift" \
  "$ROOT/ThreeOneOSSix/helpers/PackageRepositoryModels.swift" \
  "$ROOT/ThreeOneOSSix/helpers/PatchProjectModels.swift" \
  "$ROOT/ThreeOneOSSix/helpers/BackupCenter.swift" \
  "$ROOT/ThreeOneOSSix/helpers/Pathleak.swift" \
  "$ROOT/ThreeOneOSSix/helpers/WallpaperLabModels.swift" \
  "$ROOT/Tests/main.swift" \
  -o "$TMP/policy-tests"

"$TMP/policy-tests"