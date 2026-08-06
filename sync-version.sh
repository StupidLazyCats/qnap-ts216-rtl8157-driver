#!/bin/bash
#
# sync-version.sh - Propagate the Realtek driver version into the committed
# human-facing files, from the version that was actually compiled.
#
# Why this exists:
#   The build never reads these files for a version - build_driver.sh parses
#   RTL8125_VERSION out of the downloaded source and build_qpkg.sh rewrites
#   qpkg.cfg and the web UI from it, so the shipped package is always correct.
#   What drifts is the *committed* copies (package manifest default, web UI,
#   README, developer guide), which is what this fixes in one command.
#
# Usage:
#   ./build.sh driver && ./sync-version.sh   # sync to the version just built
#   ./sync-version.sh 9.019.00               # sync to an explicit version
#   NEW=9.019.00 ./sync-version.sh           # same as above
#
# NOTE: The driver's internal release DATE (shown by `modinfo`, e.g. "2025/10/28")
#       lives inside the Realtek source and is only known after download/build. It is
#       deliberately NOT tracked here - read it from the built module if you need it.
set -e

cd "$(dirname "$0")"

# What the committed files currently claim. qpkg.cfg is the anchor because it is the
# package manifest; the others are kept equal to it.
OLD=$(grep '^QPKG_VER=' qpkg/RTL8125_Driver/qpkg.cfg | cut -d'"' -f2)
if [ -z "${OLD}" ]; then
    echo "ERROR: could not read QPKG_VER from qpkg/RTL8125_Driver/qpkg.cfg"
    exit 1
fi

# Target version: positional arg, then $NEW, then whatever the last driver build
# compiled. There is no configured version to fall back on by design.
BUILT_VERSION_FILE="output/driver/driver_version"
NEW="${1:-${NEW:-}}"
if [ -z "${NEW}" ]; then
    if [ ! -f "${BUILT_VERSION_FILE}" ]; then
        echo "ERROR: no version given and ${BUILT_VERSION_FILE} does not exist."
        echo "The version comes from the Realtek source, so either build the driver"
        echo "first (./build.sh driver) or pass one: $0 9.019.00"
        exit 1
    fi
    NEW=$(cat "${BUILT_VERSION_FILE}")
fi

if [ "${OLD}" = "${NEW}" ]; then
    echo "Re-syncing all references to driver version: ${NEW}"
else
    echo "Bumping driver version: ${OLD} -> ${NEW}"
fi

# Escape dots so OLD can be used safely in a sed regex (e.g. 2.20.1 -> 2\.20\.1)
OLD_RE="${OLD//./\\.}"

# 1) Structured committed files (anchored; also re-written at build time)
sed -i "s/^QPKG_VER=.*/QPKG_VER=\"${NEW}\"/" qpkg/RTL8125_Driver/qpkg.cfg
sed -i "s|\(<strong>Version:</strong>\)[^<]*<|\1 ${NEW}<|" qpkg/RTL8125_Driver/shared/web/index.html

# 2) Free-text references: replace the previous exact version string. Using the full
#    OLD string (e.g. "9.018.00") is safe - it will not collide with the kernel
#    (5.10.60) or QTS (5.2.3) versions. Skipped on a pure re-sync (OLD == NEW).
#    versions.yml is deliberately excluded: a blind substitution there would rewrite
#    driver_source_tag and silently change which source gets fetched.
if [ "${OLD}" != "${NEW}" ]; then
    for f in README.md .claude/CLAUDE.md; do
        [ -f "$f" ] && sed -i "s/${OLD_RE}/${NEW}/g" "$f"
    done
fi

echo ""
echo "Done. Files synced to driver version ${NEW}:"
echo "  - qpkg/.../qpkg.cfg       (QPKG_VER)"
echo "  - qpkg/.../web/index.html (Version label)"
echo "  - README.md, .claude/CLAUDE.md (docs)"
echo ""
echo "Review with: git diff"
