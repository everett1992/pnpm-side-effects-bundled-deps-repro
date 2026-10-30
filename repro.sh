#!/usr/bin/env bash
# Reproduces: a package restored from pnpm's side-effects cache loses its bundled dependencies.
#
# Usage: ./repro.sh [pnpm-version] [extra pnpm-workspace.yaml line]
#   ./repro.sh 11.28.9
#   ./repro.sh 11.28.9 'sideEffectsCache: false'
#   ALLOW_BUILD=false ./repro.sh 11.28.9
#
# Starts a throwaway pnpr registry on 127.0.0.1, publishes ./bundler to it,
# then installs ./app twice on a fresh store and checks require('demo-bundler').
# Exits 1 if the second install is broken.
set -euo pipefail

PNPM_VERSION="${1:-11.28.9}"
EXTRA="${2:-}"
PNPR_VERSION="0.1.0-alpha.17"
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/.work"
PORT="${PORT:-7677}"
REGISTRY="http://127.0.0.1:$PORT/npm/"

rm -rf "$WORK"
mkdir -p "$WORK"

echo "== tools"
npm install --silent --no-save --prefix "$WORK/tools" "pnpm@$PNPM_VERSION" "@pnpm/pnpr@$PNPR_VERSION" >/dev/null
PNPM="$WORK/tools/node_modules/.bin/pnpm"
PNPR="$WORK/tools/node_modules/.bin/pnpr"
echo "pnpm $("$PNPM" --version), $("$PNPR" --version), node $(node --version), $(uname -sm)"

echo "== start pnpr on $REGISTRY"
"$PNPR" -c "$ROOT/pnpr.yaml" --listen "127.0.0.1:$PORT" --storage "$WORK/pnpr-storage" > "$WORK/pnpr.log" 2>&1 &
PNPR_PID=$!
trap 'kill $PNPR_PID 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  curl -sf "http://127.0.0.1:$PORT/-/ping" >/dev/null && break
  sleep 0.2
done

echo "== publish demo-bundler (bundles is-number, postinstall: echo built)"
cp -r "$ROOT/bundler" "$WORK/bundler"
(
  cd "$WORK/bundler"
  npm install --silent --registry "$REGISTRY" >/dev/null
  npm pack --dry-run 2>&1 | grep -E 'node_modules/is-number/package.json|bundled deps' || true
  npm publish --silent --registry "$REGISTRY" "--//127.0.0.1:$PORT/npm/:_authToken=unused" >/dev/null
)

echo "== install the app twice on one fresh store"
cp -r "$ROOT/app" "$WORK/app"
cd "$WORK/app"
echo "registry=$REGISTRY" > .npmrc
if [ "${ALLOW_BUILD:-true}" = false ]; then
  sed -i.bak 's/demo-bundler: true/demo-bundler: false/' pnpm-workspace.yaml && rm pnpm-workspace.yaml.bak
fi
{
  echo "storeDir: $WORK/store"
  echo "cacheDir: $WORK/cache"
  if [ -n "$EXTRA" ]; then echo "$EXTRA"; fi
} >> pnpm-workspace.yaml
echo "pnpm-workspace.yaml:"; sed 's/^/  /' pnpm-workspace.yaml

check() {
  local bundled="no"
  [ -f node_modules/demo-bundler/node_modules/is-number/package.json ] && bundled="yes"
  if out=$(node -e 'console.log("require ok, isNumber(5) =", require("demo-bundler")(5))' 2>&1); then
    echo "$1: bundled is-number present: $bundled; $out"
    return 0
  fi
  echo "$1: bundled is-number present: $bundled; $(grep -m1 -oE "Cannot find module '[^']+'" <<<"$out")"
  return 1
}

"$PNPM" install > "$WORK/install-1.log" 2>&1
check "install 1 (cold store)"

rm -rf node_modules
"$PNPM" install > "$WORK/install-2.log" 2>&1
if check "install 2 (warm store)"; then
  echo "RESULT: not reproduced"
else
  echo "RESULT: reproduced (logs in $WORK)"
  exit 1
fi
