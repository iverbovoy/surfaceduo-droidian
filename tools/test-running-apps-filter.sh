#!/bin/bash
# Test the actual GLib predicate shipped in the Phosh patch, without a device.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PATCH="$HERE/../adaptation/shell/phosh-patches/0014-running-apps-group-followers-with-their-open-leader.patch"
(cd "$WORK" && git apply --include=src/running-apps-filter.h "$PATCH")
cc -Wall -Wextra -Werror "$HERE/test-running-apps-filter.c" -I"$WORK/src" \
    $(pkg-config --cflags --libs glib-2.0) -o "$WORK/test-filter"
"$WORK/test-filter"
