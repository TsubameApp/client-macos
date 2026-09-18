#!/bin/sh

set -eu

script_directory="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
metadata="$(${script_directory}/git-version.sh "${SRCROOT}")"
base_version="$(printf '%s\n' "${metadata}" | sed -n '1p')"
display_version="$(printf '%s\n' "${metadata}" | sed -n '2p')"
commit="$(printf '%s\n' "${metadata}" | sed -n '3p')"
build_number="$(printf '%s\n' "${metadata}" | sed -n '4p')"
dirty="$(printf '%s\n' "${metadata}" | sed -n '5p')"
info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [ ! -f "${info_plist}" ]; then
    echo "error: processed Info.plist not found at ${info_plist}" >&2
    exit 1
fi

set_string() {
    key="$1"
    value="$2"
    if plutil -extract "${key}" raw "${info_plist}" >/dev/null 2>&1; then
        plutil -replace "${key}" -string "${value}" "${info_plist}"
    else
        plutil -insert "${key}" -string "${value}" "${info_plist}"
    fi
}

set_boolean() {
    key="$1"
    value="$2"
    if plutil -extract "${key}" raw "${info_plist}" >/dev/null 2>&1; then
        plutil -replace "${key}" -bool "${value}" "${info_plist}"
    else
        plutil -insert "${key}" -bool "${value}" "${info_plist}"
    fi
}

set_string CFBundleShortVersionString "${base_version}"
set_string CFBundleVersion "${build_number}"
set_string TsubameDisplayVersion "${display_version}"
set_string TsubameGitCommit "${commit}"
set_boolean TsubameGitDirty "${dirty}"

echo "Embedded Tsubame version ${display_version} (${build_number})"
