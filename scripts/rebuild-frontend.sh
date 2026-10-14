#!/bin/bash
# Rebuilds Penpot's frontend from source with the Figma pen patch and
# deploys it into a penpot-local install. See README.md ("Updating
# Penpot", "Figma-style vector editing").
#
#   scripts/rebuild-frontend.sh <penpot-checkout> <tag> <penpot-root>
#
# Example:
#   git clone --depth 1 --branch 2.18.3 https://github.com/penpot/penpot.git /tmp/pp
#   scripts/rebuild-frontend.sh /tmp/pp 2.18.3-figma ~/Library/PenpotLocal
#
# CRITICAL: <tag> is compiled into the JS and MUST exactly equal the
# penpotVersionTag global plus every ?version= query in index.html, or
# the app force-reloads in a loop and shows a blank screen. This script
# sets all of them from the single <tag> argument.
set -eu

CHECKOUT="${1:?usage: rebuild-frontend.sh <penpot-checkout> <tag> <penpot-root>}"
TAG="${2:?usage: rebuild-frontend.sh <penpot-checkout> <tag> <penpot-root>}"
ROOT="${3:?usage: rebuild-frontend.sh <penpot-checkout> <tag> <penpot-root>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# No Homebrew here on purpose: installing formulae auto-updates everything
# else, which has broken unrelated apps before. The Clojure CLI goes into
# a scratch prefix; pnpm and caches go into an isolated HOME.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pp-build.XXXXXX")"
ISO_HOME="$WORK/iso-home"
CLJ_PREFIX="$WORK/clojure"
export HOME="$ISO_HOME"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}"
export PATH="$ISO_HOME/.pnpm-global/bin:$CLJ_PREFIX/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
trap 'rm -rf "$WORK"; rm -rf ~/.m2 ~/.gitlibs ~/.clojure' EXIT

[ -f "$REPO/patches/figma-pen-modifiers.patch" ] || die "patch missing"
git -C "$CHECKOUT" apply --check "$REPO/patches/figma-pen-modifiers.patch" \
  || die "patch does not apply; rebase it onto this Penpot version first"
git -C "$CHECKOUT" apply "$REPO/patches/figma-pen-modifiers.patch"

python3 "$REPO/scripts/gen-shared-js.py" "$CHECKOUT" \
  || die "shared.js regeneration failed"

mkdir -p "$CLJ_PREFIX" "$ISO_HOME"
curl -sSL -o "$WORK/ct.tgz" \
  https://github.com/clojure/brew-install/releases/download/1.12.6.1673/clojure-tools-1.12.6.1673.tar.gz
echo "fe9194858e75d5af13c2e2aff92d710674d5bc5105f2b42f90a7d94d82ec023c  $WORK/ct.tgz" | shasum -a 256 -c
mkdir -p "$WORK/ct" && tar xzf "$WORK/ct.tgz" -C "$WORK/ct"
L="$CLJ_PREFIX/lib/clojure" && mkdir -p "$CLJ_PREFIX/bin" "$L/libexec"
for f in deps.edn example-deps.edn tools.edn; do install -m644 "$WORK/ct/clojure-tools/$f" "$L/$f"; done
install -m644 "$WORK/ct/clojure-tools/exec.jar" "$L/libexec/exec.jar"
install -m644 "$WORK/ct/clojure-tools/clojure-tools-1.12.6.1673.jar" "$L/libexec/clojure-tools-1.12.6.1673.jar"
sed -e "s@PREFIX@$L@g" "$WORK/ct/clojure-tools/clojure" > "$CLJ_PREFIX/bin/clojure"
sed -e "s@BINDIR@$CLJ_PREFIX/bin@g" "$WORK/ct/clojure-tools/clj" > "$CLJ_PREFIX/bin/clj"
chmod 755 "$CLJ_PREFIX/bin/clojure" "$CLJ_PREFIX/bin/clj"
rm -rf "$WORK/ct" "$WORK/ct.tgz"

mkdir -p "$ISO_HOME/.pnpm-global"
npm install -g pnpm@12.5.1 --prefix "$ISO_HOME/.pnpm-global" --allow-scripts=pnpm >/dev/null
STUB="$ISO_HOME/Library/pnpm/.tools/pnpm/12.5.1/node_modules/pnpm/pnpm"
(cd "$CHECKOUT/frontend" && pnpm --version >/dev/null 2>&1 || true)
[ -f "$STUB" ] && cp -fL "$ISO_HOME/.pnpm-global/bin/pnpm" "$STUB" || true

(cd "$CHECKOUT/frontend" && pnpm install) || die "pnpm install failed"
(cd "$CHECKOUT/frontend" && VERSION="2.18.3" VERSION_TAG="$TAG" \
  clojure -M:dev:shadow-cljs release main worker) || die "shadow-cljs failed"
(cd "$CHECKOUT/frontend" && node ./scripts/build-libs.js) || die "libs build failed"
[ -s "$CHECKOUT/frontend/resources/public/js/libs.js" ] || die "libs.js empty, retry"

BUILD_JS="$CHECKOUT/frontend/resources/public/js"
for f in libs.js main-auth.js main-dashboard.js main-settings.js main-viewer.js \
         main-workspace.js main.js rasterizer.js render.js shared.js util-highlight.js; do
  cp -a "$BUILD_JS/$f" "$ROOT/app/frontend/js/$f"
done
cp -a "$BUILD_JS/worker/main.js" "$ROOT/app/frontend/js/worker/main.js"
cp -a "$BUILD_JS/worker/manifest.json" "$ROOT/app/frontend/js/worker/manifest.json"
python3 - "$ROOT/app/frontend/index.html" "$TAG" <<'EOF'
import sys
path, tag = sys.argv[1], sys.argv[2]
src = open(path).read()
src = src.replace('penpotVersionTag = "2.18.3-1791289595"', 'penpotVersionTag = "%s"' % tag)
import re
src, n = re.subn(r'\?version=2\.18\.3-[0-9A-Za-z-]+', '?version=%s' % tag, src)
assert n > 0, "no version queries found"
open(path, "w").write(src)
print("index.html retagged to", tag)
EOF
# shellcheck disable=SC1090
set -a; . "$ROOT/conf/penpot.env"; set +a
printf '// Frontend configuration (Penpot Local)\nvar penpotFlags = "%s";\nvar penpotPublicURI = "%s";\n' \
  "$PENPOT_FLAGS" "$PENPOT_PUBLIC_URI" > "$ROOT/app/frontend/js/config.js"
say "deployed $TAG. Reload Penpot Desktop to pick it up."
