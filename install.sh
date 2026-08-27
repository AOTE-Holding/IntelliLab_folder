#!/bin/bash
set -euo pipefail

SOURCE_APP="${1:-Folder.app}"
INSTALL_APP="/Applications/Folder.app"
STAGING_APP="/Applications/.Folder.installing.$$.app"
BACKUP_APP="/Applications/.Folder.backup.$$.app"

if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "App bundle not found: ${SOURCE_APP}" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "${SOURCE_APP}"

cleanup() {
  if [[ -d "${STAGING_APP}" ]]; then rm -rf "${STAGING_APP}"; fi
}
trap cleanup EXIT

ditto "${SOURCE_APP}" "${STAGING_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

if [[ -d "${INSTALL_APP}" ]]; then
  mv "${INSTALL_APP}" "${BACKUP_APP}"
fi

if mv "${STAGING_APP}" "${INSTALL_APP}"; then
  if [[ -d "${BACKUP_APP}" ]]; then rm -rf "${BACKUP_APP}"; fi
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "${LSREGISTER}" ]]; then
    if ! "${LSREGISTER}" -f "${INSTALL_APP}"; then
      echo "Warning: LaunchServices registration will be retried when Folder opens." >&2
    fi
  fi
  QUICKLOOK_APPEX="${INSTALL_APP}/Contents/PlugIns/FolderQuickLookPreview.appex"
  if [[ -d "${QUICKLOOK_APPEX}" ]]; then
    if ! pluginkit -a "${QUICKLOOK_APPEX}"; then
      echo "Warning: Quick Look extension registration will be retried when Folder opens." >&2
    fi
  fi
  trap - EXIT
  echo "Installed ${INSTALL_APP}"
else
  if [[ -d "${BACKUP_APP}" ]]; then mv "${BACKUP_APP}" "${INSTALL_APP}"; fi
  echo "Installation failed; the previous app was restored." >&2
  exit 1
fi
