#!/usr/bin/env bash
# Exercise the actual Docker frontend stage without a product checkout.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
IMAGE="platform-frontend-test-$$"
cleanup() {
    docker image rm "$IMAGE" > /dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/src/custom_addons" "$TMP/src/third_party_addons/_vendor/probe/odoo-addons/probe" \
    "$TMP/src/third_party_addons/_vendor/unselected" "$TMP/src/third_party_addons/_selected"
printf 'unchanged\n' > "$TMP/src/custom_addons/plain.txt"
docker build --target addon_frontends -t "$IMAGE" -f "$HERE/Dockerfile" "$TMP" > "$TMP/build.log" 2>&1 \
    || { cat "$TMP/build.log"; exit 1; }
docker run --rm "$IMAGE" sh -c 'test "$(cat src/custom_addons/plain.txt)" = unchanged'
echo 'PASS: products without frontend hooks retain their addon files'

cat > "$TMP/src/third_party_addons/_vendor/probe/odoo-addons/probe/build-frontend.sh" <<'HOOK'
set -eu
mkdir -p static/web node_modules
node -e 'require("node:fs").writeFileSync("static/web/index.html", "built")'
HOOK
printf 'exit 1\n' > "$TMP/src/third_party_addons/_vendor/unselected/build-frontend.sh"
ln -s ../_vendor/probe/odoo-addons/probe "$TMP/src/third_party_addons/_selected/probe"
docker build --target addon_frontends -t "$IMAGE" -f "$HERE/Dockerfile" "$TMP" > "$TMP/build.log" 2>&1 \
    || { cat "$TMP/build.log"; exit 1; }
docker run --rm "$IMAGE" sh -c '
    test "$(cat src/third_party_addons/_selected/probe/static/web/index.html)" = built
    test -L src/third_party_addons/_selected/probe
    test -z "$(find src -name node_modules -print -quit)"
'
echo 'PASS: nested selected hook builds, unselected hook does not run, dependencies are removed'

printf 'exit 1\n' > "$TMP/src/third_party_addons/_vendor/probe/odoo-addons/probe/build-frontend.sh"
if docker build --target addon_frontends -t "$IMAGE" -f "$HERE/Dockerfile" "$TMP" > "$TMP/build.log" 2>&1; then
    echo 'FAIL: a broken frontend hook must fail image creation' >&2
    exit 1
fi
echo 'PASS: frontend build failure stops image creation'
