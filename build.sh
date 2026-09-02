#!/bin/bash
set -euo pipefail

APP_NAME="Folder"
APP_VERSION="$(<VERSION)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-development}"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
PLUGINS="${CONTENTS}/PlugIns"
QUICKLOOK_APPEX="${PLUGINS}/FolderQuickLookPreview.appex"
QUICKLOOK_CONTENTS="${QUICKLOOK_APPEX}/Contents"
QUICKLOOK_MACOS="${QUICKLOOK_CONTENTS}/MacOS"
QUICKLOOK_EXECUTABLE="${QUICKLOOK_MACOS}/FolderQuickLookPreview"

if [[ "${BUILD_CONFIGURATION}" == "release" ]]; then
  required=(BUNDLE_IDENTIFIER DEVELOPMENT_TEAM CODE_SIGN_IDENTITY)
  for variable in "${required[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
      echo "Release configuration is missing ${variable}." >&2
      exit 1
    fi
  done
else
  BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.intellilab.folder.development}"
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
fi

echo "Building ${APP_NAME} ${APP_VERSION} (${BUILD_CONFIGURATION})"
swift build -c release -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}" "${QUICKLOOK_MACOS}"
ditto ".build/release/Folder" "${MACOS}/${APP_NAME}"
ditto "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"

# QLPreviewPanel deliberately doesn't accept arbitrary custom AppKit content.
# Apple's supported mechanism is a Quick Look Preview Extension whose native
# NSViewController conforms to QLPreviewingController.
EXTENSION_ARCH="$(uname -m)"
env \
  CLANG_MODULE_CACHE_PATH="${PWD}/.build/quicklook-module-cache" \
  SWIFT_MODULECACHE_PATH="${PWD}/.build/quicklook-module-cache" \
  swiftc \
    -module-name FolderQuickLookPreviewExtension \
    -parse-as-library \
    -emit-executable \
    -O \
    -warnings-as-errors \
    -strict-concurrency=complete \
    -target "${EXTENSION_ARCH}-apple-macosx13.0" \
    "QuickLookExtension/FolderQuickLookPreviewController.swift" \
    -o "${QUICKLOOK_EXECUTABLE}" \
    -framework AppKit \
    -framework Quartz \
    -Xlinker -e \
    -Xlinker _NSExtensionMain

QUICKLOOK_PLIST="${QUICKLOOK_CONTENTS}/Info.plist"
ditto "QuickLookExtension/Info.plist.template" "${QUICKLOOK_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_IDENTIFIER}.quicklookpreview" "${QUICKLOOK_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${QUICKLOOK_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_VERSION}" "${QUICKLOOK_PLIST}"
chmod +x "${QUICKLOOK_EXECUTABLE}"

PLIST="${CONTENTS}/Info.plist"
ditto Resources/Info.plist.template "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_IDENTIFIER}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName ${BUNDLE_IDENTIFIER}" "${PLIST}"

chmod +x "${MACOS}/${APP_NAME}"
SIGN_OPTIONS=(--options runtime)
if [[ "${BUILD_CONFIGURATION}" == "release" ]]; then SIGN_OPTIONS+=(--timestamp); fi

codesign --force --sign "${CODE_SIGN_IDENTITY}" "${SIGN_OPTIONS[@]}" \
  --entitlements "QuickLookExtension/FolderQuickLookPreview.entitlements" \
  "${QUICKLOOK_APPEX}"
codesign --verify --strict --verbose=2 "${QUICKLOOK_APPEX}"

ENTITLEMENTS_FILE="Folder.entitlements"
if [[ "${BUILD_CONFIGURATION}" != "release" ]]; then
  ENTITLEMENTS_FILE="Folder.development.entitlements"
fi
codesign --force --sign "${CODE_SIGN_IDENTITY}" "${SIGN_OPTIONS[@]}" \
  --entitlements "${ENTITLEMENTS_FILE}" "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

if [[ "${BUILD_CONFIGURATION}" == "release" ]]; then
  actual_bundle_id="$(codesign -dv --verbose=4 "${APP_BUNDLE}" 2>&1 | sed -n 's/^Identifier=//p')"
  actual_team_id="$(codesign -dv --verbose=4 "${APP_BUNDLE}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [[ "${actual_bundle_id}" != "${BUNDLE_IDENTIFIER}" ]]; then
    echo "Release bundle identifier does not match ${BUNDLE_IDENTIFIER}." >&2
    exit 1
  fi
  if [[ "${actual_team_id}" != "${DEVELOPMENT_TEAM}" ]]; then
    echo "Release signing team does not match ${DEVELOPMENT_TEAM}." >&2
    exit 1
  fi
fi

echo "Created ${APP_BUNDLE}"
