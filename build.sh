#!/bin/bash
set -euo pipefail

APP_NAME="Folder"
APP_VERSION="$(<VERSION)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-development}"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
FRAMEWORKS="${CONTENTS}/Frameworks"
PLUGINS="${CONTENTS}/PlugIns"
QUICKLOOK_APPEX="${PLUGINS}/FolderQuickLookPreview.appex"
QUICKLOOK_CONTENTS="${QUICKLOOK_APPEX}/Contents"
QUICKLOOK_MACOS="${QUICKLOOK_CONTENTS}/MacOS"
QUICKLOOK_EXECUTABLE="${QUICKLOOK_MACOS}/FolderQuickLookPreview"

# Der Ort, an dem die App nach Updates fragt. Zeigt immer auf den Appcast des
# jeweils neuesten Releases — die Adresse aendert sich also nie, der Inhalt schon.
SPARKLE_FEED_DEFAULT="https://github.com/AOTE-Holding/IntelliLab_folder/releases/latest/download/appcast.xml"
# Der oeffentliche Teil des Sparkle-Schluessels. Oeffentlich im Wortsinn: er
# gehoert in die App, damit sie eine Aktualisierung pruefen kann. Der private
# Teil liegt im Schluesselbund und als GitHub-Secret.
SPARKLE_PUBLIC_ED_KEY_DEFAULT="1jiUa2lW2NeJLsT2PX5UnwQCnxahE0q8Bdjck+mhUE4="

if [[ "${BUILD_CONFIGURATION}" == "release" ]]; then
  # Eine Apple-Signatur ist wuenschenswert, aber keine Bedingung fuer einen
  # Release. Ohne sie warnt macOS beim ersten Oeffnen — die App kann sich
  # trotzdem selbst aktualisieren, denn dafuer buergt der Sparkle-Schluessel,
  # nicht Apple. Frueher verlangte dieser Zweig fuenf Angaben und brach ohne
  # sie ab; das Ergebnis war, dass jeder Build eine Entwicklungsversion blieb
  # und die App Updates von sich aus abschaltete.
  BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.intellilab.folder}"
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
  SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$SPARKLE_FEED_DEFAULT}"
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$SPARKLE_PUBLIC_ED_KEY_DEFAULT}"

  if [[ "${CODE_SIGN_IDENTITY}" == "-" ]]; then
    echo "Note: building without an Apple Developer ID. Updates work, macOS will warn on first open."
  fi
else
  BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.intellilab.folder.development}"
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
  SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://invalid.example/appcast.xml}"
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-DEVELOPMENT_BUILD_NO_KEY}"
fi

echo "Building ${APP_NAME} ${APP_VERSION} (${BUILD_CONFIGURATION})"
swift build -c release -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}" "${FRAMEWORKS}" "${QUICKLOOK_MACOS}"
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

SPARKLE_FRAMEWORK="$(find .build -path '*/Sparkle.framework' -type d -print -quit)"
if [[ -z "${SPARKLE_FRAMEWORK}" ]]; then
  echo "Sparkle.framework was not produced by SwiftPM." >&2
  exit 1
fi
ditto "${SPARKLE_FRAMEWORK}" "${FRAMEWORKS}/Sparkle.framework"
folder_otool_output="$(otool -l "${MACOS}/${APP_NAME}")"
if ! grep -Fq '@executable_path/../Frameworks' <<< "${folder_otool_output}"; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "${MACOS}/${APP_NAME}"
fi

PLIST="${CONTENTS}/Info.plist"
ditto Resources/Info.plist.template "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_IDENTIFIER}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL ${SPARKLE_FEED_URL}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_ED_KEY}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName ${BUNDLE_IDENTIFIER}" "${PLIST}"

chmod +x "${MACOS}/${APP_NAME}"
SIGN_OPTIONS=(--options runtime)
if [[ "${BUILD_CONFIGURATION}" == "release" ]]; then SIGN_OPTIONS+=(--timestamp); fi

# Sparkle's nested services must be signed inside-out. `--deep` verification
# alone does not catch a Team-ID mismatch at dyld load time.
SPARKLE_VERSION="${FRAMEWORKS}/Sparkle.framework/Versions/B"
codesign --force --sign "${CODE_SIGN_IDENTITY}" "${SIGN_OPTIONS[@]}" \
  "${SPARKLE_VERSION}/XPCServices/Installer.xpc"
codesign --force --sign "${CODE_SIGN_IDENTITY}" "${SIGN_OPTIONS[@]}" \
  --preserve-metadata=entitlements \
  "${SPARKLE_VERSION}/XPCServices/Downloader.xpc"
codesign --force --sign "${CODE_SIGN_IDENTITY}" "${SIGN_OPTIONS[@]}" \
  "${SPARKLE_VERSION}/Autoupdate"
codesign --force --sign "${CODE_SIGN_IDENTITY}" "${SIGN_OPTIONS[@]}" \
  "${SPARKLE_VERSION}/Updater.app"
codesign --force --sign "${CODE_SIGN_IDENTITY}" "${SIGN_OPTIONS[@]}" \
  "${FRAMEWORKS}/Sparkle.framework"
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
  [[ "${actual_bundle_id}" == "${BUNDLE_IDENTIFIER}" ]]
  [[ "${actual_team_id}" == "${DEVELOPMENT_TEAM}" ]]
fi

echo "Created ${APP_BUNDLE}"
