#!/bin/bash
# DNS-side check of the email authentication that magic-link sign-in depends on.
#
# Sign-in is an email or nothing: if Gmail starts junking mail from stride.colorarchive.me,
# nobody can log in and nothing on our side errors. Resend sends as
# hello@stride.colorarchive.me (FROM_EMAIL), signs with DKIM selector `resend`, and uses
# send.stride.colorarchive.me as the envelope sender. Two return-path setups exist:
#   - Resend's current one (Stride's own team since 2026-10-15): send.<domain> and
#     rsend.<domain> are CNAMEs to send.forge.rmta.net / rsend.forge.rmta.net, which publish the
#     SPF and the feedback MX themselves (so send.<domain> holds no MX or TXT of its own);
#   - the older Amazon SES one: an MX to feedback-smtp.<region>.amazonses.com and a TXT
#     "v=spf1 include:amazonses.com ~all" on send.<domain>.
# Either passes; which one is in place is printed. DMARC passes
# when SPF or DKIM passes *aligned* with the From domain; both are relaxed-aligned here
# (same organisational domain, colorarchive.me).
#
# This reads public DNS only. It cannot prove a message passes — for that, open a received
# magic-link email and read its Authentication-Results header. Nor can it see Resend: on
# 2026-10-12 everything here passed while the Resend account behind RESEND_API_KEY had no
# such domain and refused every send. server/DEPLOY.md, "The Resend side", has that check.
# Run it after any DNS change at Namecheap and before a release that touches sign-in.
#
# Exit 0: everything required is present (WARN lines are advice). Exit 1: a FAIL.
set -uo pipefail

FROM_DOMAIN="${1:-stride.colorarchive.me}"
ORG_DOMAIN="${FROM_DOMAIN#*.}"            # stride.colorarchive.me -> colorarchive.me
BOUNCE_DOMAIN="send.$FROM_DOMAIN"
DKIM_NAME="resend._domainkey.$FROM_DOMAIN"
RESOLVER="${RESOLVER:-1.1.1.1}"

fails=0
pass() { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
# All TXT strings of a name joined (long records arrive split into 255-byte chunks).
txt() { dig +short TXT "$1" @"$RESOLVER" | sed -e 's/" "//g' -e 's/^"//' -e 's/"$//'; }

command -v dig >/dev/null || { echo "dig not found"; exit 1; }

# SPF and the feedback MX — checked on the envelope sender (Return-Path), which is what
# receivers evaluate. dig follows a CNAME, so with Resend's current setup the TXT and MX below
# are the CNAME target's.
cname="$(dig +short CNAME "$BOUNCE_DOMAIN" @"$RESOLVER")"
if [[ -n "$cname" ]]; then
  if [[ "$cname" == *".rmta.net." ]]; then
    pass "Return-path: $BOUNCE_DOMAIN is a CNAME to $cname (Resend-managed SPF and feedback MX)"
    rcname="$(dig +short CNAME "r$BOUNCE_DOMAIN" @"$RESOLVER")"
    if [[ "$rcname" == *".rmta.net." ]]; then
      pass "Return-path: r$BOUNCE_DOMAIN is a CNAME to $rcname"
    else
      fail "Return-path: r$BOUNCE_DOMAIN should be a CNAME to rsend.forge.rmta.net (got: ${rcname:-none}) — Resend will not verify the domain"
    fi
  else
    fail "Return-path: $BOUNCE_DOMAIN is a CNAME to $cname, which is not Resend's (*.rmta.net)"
  fi
fi
spf="$(txt "$BOUNCE_DOMAIN" | grep -i '^v=spf1' || true)"
if [[ -z "$spf" ]]; then
  fail "SPF: no v=spf1 record on $BOUNCE_DOMAIN (Resend's envelope domain)"
elif [[ -n "$cname" || "$spf" == *"include:amazonses.com"* ]]; then
  pass "SPF: $BOUNCE_DOMAIN → $spf"
else
  fail "SPF: $BOUNCE_DOMAIN does not include amazonses.com: $spf"
fi

mx="$(dig +short MX "$BOUNCE_DOMAIN" @"$RESOLVER" | grep ' ' || true)"   # "<prio> <host>" lines only, not the CNAME line
if [[ "$mx" == *"amazonses.com"* || ( -n "$cname" && "$mx" == *".rmta.net."* ) ]]; then
  pass "MX:  $BOUNCE_DOMAIN → $mx (bounce/complaint feedback reaches Resend)"
else
  fail "MX:  $BOUNCE_DOMAIN has no Resend feedback MX (got: ${mx:-none}) — Resend will not verify the domain"
fi

# DKIM — the aligned signature that carries DMARC on its own.
dkim="$(txt "$DKIM_NAME")"
if [[ "$dkim" == *"p="* && "$dkim" != *"p=;"* ]]; then
  pass "DKIM: $DKIM_NAME publishes a key (${#dkim} chars)"
else
  fail "DKIM: no public key at $DKIM_NAME"
fi

# DMARC — the subdomain's own record if it has one, else the organisational domain's.
dmarc="$(txt "_dmarc.$FROM_DOMAIN" | grep -i '^v=DMARC1' || true)"
dmarc_at="_dmarc.$FROM_DOMAIN"
if [[ -z "$dmarc" ]]; then
  dmarc="$(txt "_dmarc.$ORG_DOMAIN" | grep -i '^v=DMARC1' || true)"
  dmarc_at="_dmarc.$ORG_DOMAIN (inherited; no _dmarc.$FROM_DOMAIN)"
fi
if [[ -z "$dmarc" ]]; then
  fail "DMARC: no record at _dmarc.$FROM_DOMAIN or _dmarc.$ORG_DOMAIN (Gmail/Yahoo require one for bulk senders)"
else
  # The subdomain inherits sp= if the org record sets it, else p=.
  policy="$(echo "$dmarc" | tr ';' '\n' | sed 's/^ *//' | grep -i '^p=' | head -1 | cut -d= -f2)"
  sp="$(echo "$dmarc" | tr ';' '\n' | sed 's/^ *//' | grep -i '^sp=' | head -1 | cut -d= -f2)"
  [[ "$dmarc_at" == *inherited* && -n "$sp" ]] && policy="$sp"
  case "$policy" in
    reject|quarantine) pass "DMARC: $dmarc_at → policy $policy" ;;
    none) warn "DMARC: $dmarc_at → policy none: present (satisfies Gmail/Yahoo) but anyone may send as $FROM_DOMAIN unchallenged" ;;
    *) fail "DMARC: $dmarc_at has no usable p= ($dmarc)" ;;
  esac
  [[ "$dmarc" == *"rua="* ]] || warn "DMARC: no rua= — nobody receives aggregate reports, so a failing or spoofed stream is invisible"
fi

# The organisational domain itself. It sends no mail (no MX, no SPF), which is fine, but
# then it should say so, or its name is free to spoof in From lines.
root_spf="$(txt "$ORG_DOMAIN" | grep -i '^v=spf1' || true)"
if [[ -z "$root_spf" ]]; then
  warn "SPF: $ORG_DOMAIN has no SPF record (it sends no mail; 'v=spf1 -all' would say so)"
else
  pass "SPF: $ORG_DOMAIN → $root_spf"
fi

echo
if (( fails > 0 )); then echo "$fails FAIL(s)"; exit 1; fi
echo "Required records present."
