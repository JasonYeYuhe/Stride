#!/bin/bash
# Put a new Resend API key (and the sender) on production, without the key ever appearing on a
# command line, in shell history, in a chat or in a file on this Mac. Run it YOURSELF, in a
# terminal (an agent must not handle the key):
#
#   scripts/ops/set_resend_key.sh                                   # sender: Stride <hello@stride.colorarchive.me>
#   scripts/ops/set_resend_key.sh "Stride <stride@colorarchive.org>"
#
# It asks for the key with hidden input, checks it looks like a Resend key (re_…), and sends it
# to the host on ssh's stdin. On the host, as root, it:
#   1. copies /root/stride-server/.env to .env.bak-<timestamp> (same mode);
#   2. sets RESEND_API_KEY and FROM_EMAIL (replacing the lines, or appending them);
#   3. `pm2 restart stride-server --update-env` (the process only reads .env at start);
#   4. sends one magic-link mail through email.js to delivered@resend.dev, Resend's test sink,
#      which delivers nothing and creates no account row (server/DEPLOY.md "The Resend side");
#   5. if that send fails: restores the backup, restarts again, and exits 1.
# The send in 4 only succeeds when the sender's domain is verified in the Resend account the key
# belongs to, so run it after Resend shows the domain as Verified.
#
# Prints the outcome and the backup's name, never the key. Uses the same ssh options as
# server/DEPLOY.md (IdentityAgent=none: the 1Password agent otherwise hangs a non-interactive
# connection).
set -euo pipefail

FROM="${1:-Stride <hello@stride.colorarchive.me>}"
HOST="${STRIDE_HOST:-azureuser@172.207.80.109}"
SSH_KEY="${STRIDE_SSH_KEY:-$HOME/.ssh/id_ed25519}"

[[ "$FROM" =~ ^[^\<\>]*\<[^@\<\>[:space:]]+@[^@\<\>[:space:]]+\>$ ]] \
    || { echo "✗ The sender must look like: Name <user@domain> (got '$FROM')"; exit 2; }
[[ -t 0 ]] || { echo "✗ Run this in a terminal: it reads the key from the keyboard."; exit 2; }

read -rs -p "Resend API key for $FROM (input hidden): " KEY
echo
[[ "$KEY" =~ ^re_[A-Za-z0-9_]{10,}$ ]] || { unset KEY; echo "✗ That does not look like a Resend API key (re_…)."; exit 2; }

# The host-side program, shipped base64-encoded so no quoting survives two shells. It holds no
# secret: the key arrives on its stdin.
read -r -d '' REMOTE <<'PY' || true
import os, re, shutil, subprocess, sys, time
key = sys.stdin.readline().strip()
frm = sys.stdin.readline().strip()
if not re.fullmatch(r"re_[A-Za-z0-9_]{10,}", key):
    sys.exit("refused: not a Resend key")
d = os.environ.get("STRIDE_SERVER_DIR", "/root/stride-server")   # override only for the local test
p = os.path.join(d, ".env")
bak = p + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(p, bak)

def setv(s, name, val):
    line = name + "=" + val
    if re.search(r"(?m)^" + name + "=", s):
        return re.sub(r"(?m)^" + name + "=.*$", lambda m: line, s)
    return s.rstrip("\n") + "\n" + line + "\n"

s = open(p).read()
s = setv(setv(s, "RESEND_API_KEY", key), "FROM_EMAIL", frm)
mode = os.stat(p).st_mode
with open(p, "w") as f:
    f.write(s)
os.chmod(p, mode)

def restart():
    subprocess.run(["pm2", "restart", "stride-server", "--update-env"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

restart()
probe = ('require("dotenv").config();'
         'require("./email").sendMagicLinkEmail("delivered@resend.dev",'
         '{loginUrl:"https://stride-api.colorarchive.me/",expiresInMinutes:15})'
         '.then(()=>console.log("sent"),e=>{console.log("NOT sent: "+e.message);process.exitCode=1})')
r = subprocess.run(["node", "-e", probe], cwd=d, capture_output=True, text=True)
last = ((r.stdout or "") + (r.stderr or "")).strip().splitlines()[-1:] or ["(no output)"]
if r.returncode == 0 and last[0] == "sent":
    print("✓ RESEND_API_KEY and FROM_EMAIL set, restarted; test mail to delivered@resend.dev sent.")
    print("  Backup: " + bak)
else:
    shutil.copy2(bak, p)
    restart()
    print("✗ The test send failed: " + last[0][:300])
    print("  .env restored from " + bak + " and restarted; nothing changed.")
    sys.exit(1)
PY
B64="$(printf '%s' "$REMOTE" | base64 | tr -d '\n')"

set +e
printf '%s\n%s\n' "$KEY" "$FROM" | ssh -o IdentityAgent=none -o ConnectTimeout=15 -i "$SSH_KEY" "$HOST" \
    "sudo python3 -c \"\$(echo $B64 | base64 -d)\""
rc=$?
set -e
unset KEY
exit $rc
