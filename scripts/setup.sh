#!/bin/bash
# penpot-local setup: installs Penpot to run natively on macOS, fully
# offline, with no account, login screen, or cloud. See README.md.
#
#   PENPOT_VERSION=2.18.3 PENPOT_ROOT=~/Library/PenpotLocal scripts/setup.sh
#
# Re-runnable: skips downloads it already has, never regenerates the
# secret, and refuses to overwrite an existing account without asking.
set -eu

PENPOT_VERSION="${PENPOT_VERSION:-2.18.3}"
ROOT="${PENPOT_ROOT:-$HOME/Library/PenpotLocal}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. Ports ---------------------------------------------------------------
# Registered local ports (see ~/.agents/ports.md): 9001 web, 6060 backend,
# 6061 exporter, 6390 cache. Refuse to continue if any is taken by
# something that is not ours.
for port in 9001 6060 6061 6390; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    say "port $port is already listening; stop that service first (never kill another project's server)."
    lsof -nP -iTCP:"$port" -sTCP:LISTEN | head -n 3
    die "port conflict on $port"
  fi
done

# --- 1. Prerequisites --------------------------------------------------------
MISSING=0
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "missing: $1 ($2)"
    MISSING=1
  fi
}
need java "Homebrew openjdk (27): HOMEBREW_NO_AUTO_UPDATE=1 brew install openjdk"
need node "Homebrew node"
need psql "Homebrew postgresql@15 (then: brew services start postgresql@15)"
need valkey-server "Homebrew valkey"
need nginx "Homebrew nginx"
need git "Xcode CLT or Homebrew git"
need curl "macOS ships curl"
need python3 "macOS ships python3 (or python.org)"
need openssl "macOS ships openssl"
if [ ! -d "/Applications/Google Chrome.app" ]; then
  say "missing: Google Chrome (/Applications, used by the exporter)"
  MISSING=1
fi
[ "$MISSING" = 0 ] || die "install the prerequisites above, then re-run."
command -v crane >/dev/null 2>&1 || {
  say "fetching crane (static binary, no Homebrew)..."
  case "$(uname -m)" in
    arm64)  CRANE_ARCH=arm64 ;;
    x86_64) CRANE_ARCH=x86_64 ;;
    *) die "unsupported arch $(uname -m)" ;;
  esac
  mkdir -p "$ROOT/dl" "$ROOT/bin"
  curl -sSL -o "$ROOT/dl/crane.tgz" \
    "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Darwin_${CRANE_ARCH}.tar.gz"
  tar -xzf "$ROOT/dl/crane.tgz" -C "$ROOT/dl/" crane
  install -m755 "$ROOT/dl/crane" "$ROOT/bin/crane"
}
export PATH="$ROOT/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- 2. Fetch + extract official images ---------------------------------------
mkdir -p "$ROOT/dl" "$ROOT/app" "$ROOT/conf" "$ROOT/data/assets" "$ROOT/logs" "$ROOT/run/nginx"
for part in backend frontend exporter; do
  if [ ! -f "$ROOT/dl/$part.tgz" ]; then
    say "pulling penpotapp/$part:$PENPOT_VERSION ..."
    crane export "penpotapp/$part:$PENPOT_VERSION" "$ROOT/dl/$part.tgz"
  fi
  rm -rf "$ROOT/dl/unpack-$part" && mkdir -p "$ROOT/dl/unpack-$part"
  tar -xzf "$ROOT/dl/$part.tgz" -C "$ROOT/dl/unpack-$part"
  rm -rf "$ROOT/app/$part" && mkdir -p "$ROOT/app/$part"
  cp -a "$ROOT/dl/unpack-$part/." "$ROOT/app/$part/"
done
[ -f "$ROOT/app/backend/penpot.jar" ] && [ -f "$ROOT/app/backend/run.sh" ] \
  || die "backend image layout changed; inspect $ROOT/dl/unpack-backend"
[ -f "$ROOT/app/frontend/index.html" ] && [ -f "$ROOT/app/frontend/js/main.js" ] \
  || die "frontend image layout changed; inspect $ROOT/dl/unpack-frontend"
[ -f "$ROOT/app/exporter/app.js" ] \
  || die "exporter image layout changed; inspect $ROOT/dl/unpack-exporter"

# --- 3. Local-only patches ----------------------------------------------------
# Exporter: use the installed Chrome, listen on localhost only.
python3 - "$ROOT/app/exporter/app.js" <<'EOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
src, n1 = re.subn(r'channel\s*:\s*"[^"]*"', 'channel:"chrome"', src, count=1)
src, n2 = re.subn(r'(\.listen\([^,]+,\s*)"[^"]*"(\))', r'\1"127.0.0.1"\2', src, count=1)
assert n1 == 1 and n2 == 1, "exporter app.js patterns not found; patch manually"
open(path, "w").write(src)
print("exporter patched")
EOF

# Frontend: stock files, plus the cursor overlay (no rebuild needed).
cp "$REPO/patches/figma-cursors.js" "$ROOT/app/frontend/js/figma-cursors.js"
if ! grep -q "figma-cursors.js" "$ROOT/app/frontend/js/../index.html"; then
  python3 - "$ROOT/app/frontend/index.html" <<'EOF'
import sys
path = sys.argv[1]
src = open(path).read()
tag = '<script src="./js/figma-cursors.js?version=1"></script>'
anchor = '<script src="./js/polyfills.js'
assert anchor in src, "index.html layout changed; insert the tag manually"
src = src.replace(anchor, tag + "\n    " + anchor, 1)
open(path, "w").write(src)
print("overlay wired")
EOF
fi
rm -f "$ROOT/app/frontend/js/"*.map "$ROOT/app/frontend/js/worker/"*.map
find "$ROOT/app/frontend/images/features" -type f ! -name '2.*' -delete 2>/dev/null || true

# --- 4. Config ------------------------------------------------------------------
sed "s#__PENPOT_ROOT__#$ROOT#g" "$REPO/conf/nginx.conf" > "$ROOT/conf/nginx.conf"
cp "$REPO/conf/mime.types" "$REPO/conf/nginx-security-headers.conf" \
   "$REPO/conf/starting.html" "$REPO/conf/valkey.conf" "$ROOT/conf/"
if [ ! -f "$ROOT/conf/secret" ]; then
  openssl rand -hex 32 > "$ROOT/conf/secret"
  chmod 600 "$ROOT/conf/secret"
fi
if [ ! -f "$ROOT/conf/penpot.env" ]; then
  printf 'Database password for the local penpot Postgres role [penpot]: '
  read -r DBPW
  DBPW="${DBPW:-penpot}"
  sed -e "s#__PENPOT_ROOT__#$ROOT#g" -e "s#__DB_PASSWORD__#$DBPW#g" \
    "$REPO/conf/penpot.env" > "$ROOT/conf/penpot.env"
fi
# shellcheck disable=SC1090
set -a; . "$ROOT/conf/penpot.env"; set +a
printf '// Frontend configuration (Penpot Local)\nvar penpotFlags = "%s";\nvar penpotPublicURI = "%s";\n' \
  "$PENPOT_FLAGS" "$PENPOT_PUBLIC_URI" > "$ROOT/app/frontend/js/config.js"

# --- 5. Database ---------------------------------------------------------------
if ! psql -U "$(whoami)" -d postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='penpot'" 2>/dev/null | grep -q 1; then
  say "creating Postgres role and database (as superuser $(whoami) over the local socket)..."
  # shellcheck disable=SC1090
  . "$ROOT/conf/penpot.env"
  psql -U "$(whoami)" -d postgres -c "CREATE ROLE penpot WITH LOGIN PASSWORD '$PENPOT_DATABASE_PASSWORD'" \
    || die "could not create role; create it manually and re-run"
fi
psql -U "$(whoami)" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='penpot'" 2>/dev/null | grep -q 1 \
  || psql -U "$(whoami)" -d postgres -c "CREATE DATABASE penpot OWNER penpot" \
  || die "could not create database"
say "database ready."

# --- 6. Account (one local profile, created once) -------------------------------
if [ ! -f "$ROOT/conf/local-account" ]; then
  printf 'Local account email [you@penpot.local]: '
  read -r ACC_EMAIL
  ACC_EMAIL="${ACC_EMAIL:-you@penpot.local}"
  printf 'Display name [Local]: '
  read -r ACC_NAME
  ACC_NAME="${ACC_NAME:-Local}"
  printf 'Password (input hidden): '
  read -rs ACC_PASS
  echo
  [ -n "$ACC_PASS" ] || die "password cannot be empty"
  printf 'email=%s\npassword=%s\n' "$ACC_EMAIL" "$ACC_PASS" > "$ROOT/conf/local-account"
  chmod 600 "$ROOT/conf/local-account"
  ACC_FULLNAME="$ACC_NAME" ACC_NEW=1
else
  ACC_EMAIL="$(head -n 1 "$ROOT/conf/local-account" | cut -d= -f2-)"
  ACC_NEW=0
fi

# --- 7. Backend up, profile + token ---------------------------------------------
"$ROOT/bin/penpot-local" start
ENDPOINT="http://127.0.0.1:6060/api/rpc/command/login-with-password"
if [ "${ACC_NEW:-0}" = 1 ]; then
  say "creating profile $ACC_EMAIL ..."
  ACC_EMAIL="$ACC_EMAIL" ACC_PASS="$ACC_PASS" ACC_FULLNAME="${ACC_FULLNAME:-Local}" python3 - <<'EOF'
import json, os, socket, sys
fullname, email, password = (os.environ[k] for k in ("ACC_FULLNAME", "ACC_EMAIL", "ACC_PASS"))
s = socket.create_connection(("127.0.0.1", 6063), timeout=15)
f = s.makefile(mode="rw")
json.dump({"cmd": "create-profile",
           "params": {"fullname": fullname, "email": email, "password": password,
                      "viewed-tutorial?": True, "viewed-walkthrough?": True}}, f)
f.write("\n")
f.flush()
while True:
    r = json.loads(f.readline())
    if r.get("tag") == "ret":
        if r.get("err"):
            sys.exit("profile creation failed: %s (if it exists, delete conf/local-account and re-run)" % r["err"])
        print("profile created")
        break
EOF
fi
say "minting auto-login token ..."
ENDPOINT="http://127.0.0.1:${PENPOT_HTTP_SERVER_PORT:-6060}/api/rpc/command/login-with-password"
TOKEN="$(ACC_EMAIL="$ACC_EMAIL" PENPOT_ROOT="$ROOT" LOGIN_ENDPOINT="$ENDPOINT" python3 - <<'EOF'
import json, os, subprocess, sys
email = os.environ["ACC_EMAIL"]
pwfile = os.environ["PENPOT_ROOT"] + "/conf/local-account"
password = [l.split("=", 1)[1] for l in open(pwfile) if l.startswith("password=")][0].strip()
payload = json.dumps(["^ ", "~:email", email, "~:password", password])
p = subprocess.run(["curl", "-s", "-D-", "-m", "25", "-X", "POST", os.environ["LOGIN_ENDPOINT"],
                    "-H", "Content-Type: application/transit+json", "--data", payload],
                   capture_output=True, text=True)
for line in p.stdout.splitlines():
    if line.lower().startswith("set-cookie:") and "auth-token=" in line:
        print(line.split("auth-token=", 1)[1].split(";", 1)[0].strip())
        break
else:
    sys.exit("login did not return a token; check conf/local-account and backend logs")
EOF
)"
[ -n "$TOKEN" ] || die "empty token"
printf '%s' "$TOKEN" > "$ROOT/conf/session-token"
chmod 600 "$ROOT/conf/session-token"
sed "s#__SESSION_TOKEN__#$TOKEN#g" "$REPO/conf/nginx-auth.conf.example" > "$ROOT/conf/nginx-auth.conf"
chmod 600 "$ROOT/conf/nginx-auth.conf"
"$ROOT/bin/penpot-local" restart >/dev/null && say "backend restarted with auto-login."

# --- 8. Launch at login ---------------------------------------------------------
sed -e "s#__HOME__#$HOME#g" -e "s#__PENPOT_ROOT__#$ROOT#g" \
  "$REPO/launchd/local.penpot.server.plist" > "$HOME/Library/LaunchAgents/local.penpot.server.plist"
if launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.penpot.server.plist" 2>/dev/null; then
  say "background helper installed (starts the backend while Penpot is open)."
else
  say "background helper already installed, or bootstrap it manually:"
  say "  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.penpot.server.plist"
fi

cat <<EOF

Done. Open Penpot Desktop and choose the Local (offline) instance at
$PENPOT_PUBLIC_URI — it opens straight into your workspace, no login.

Manual control: $ROOT/bin/penpot-local start|stop|restart|status|logs
EOF
