#!/bin/sh

set -eu

repository_path="${1:-.}"

if ! git -C "${repository_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "0.0.0" "0.0.0" "unknown" "1" "false"
    exit 0
fi

commit="$(git -C "${repository_path}" rev-parse --short=7 HEAD)"
build_number="$(git -C "${repository_path}" rev-list --count HEAD)"
if [ "${build_number}" -lt 1 ]; then
    build_number=1
fi

if [ -n "$(git -C "${repository_path}" status --porcelain)" ]; then
    dirty=true
else
    dirty=false
fi

nearest_tag="$(git -C "${repository_path}" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
if printf '%s\n' "${nearest_tag}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        base_version="${nearest_tag#v}"
        description="$(git -C "${repository_path}" describe --tags --match 'v[0-9]*' --long --abbrev=7)"
        exact_description="${nearest_tag}-0-g${commit}"
        if [ "${description}" = "${exact_description}" ] && [ "${dirty}" = false ]; then
            display_version="${base_version}"
        else
            display_version="${description#v}"
            if [ "${dirty}" = true ]; then
                display_version="${display_version}-dirty"
            fi
        fi
else
    base_version="0.0.0"
    display_version="0.0.0-g${commit}"
    if [ "${dirty}" = true ]; then
        display_version="${display_version}-dirty"
    fi
fi

printf '%s\n' \
    "${base_version}" \
    "${display_version}" \
    "${commit}" \
    "${build_number}" \
    "${dirty}"
