#!/usr/bin/env bash
## Checks a keybox.xml and installs it on an AxionOS phone over adb, the same
## way Settings > TrickyStore > Import keybox stores it.
##
##   keybox.sh <keybox.xml | URL>     check, then install
##   keybox.sh -n <keybox.xml | URL>  check only
##
## The argument is a local file or an http(s) URL (e.g. a repo's raw "key"
## file); either may be the XML itself or its base64. Checks: every private
## key matches the first certificate after it, and no certificate serial is on
## Google's attestation revocation list. Install: settings put secure
## spoof_trickystore_keybox <base64 of the XML>, then Play Store is stopped so
## it asks for attestation again. Never commit a keybox anywhere.
set -euo pipefail

STATUS_URL=https://android.googleapis.com/attestation/status
CHECK_ONLY=0
[ "${1:-}" = -n ] && { CHECK_ONLY=1; shift; }
[ $# -eq 1 ] || { sed -n '2,13s/^## \{0,1\}//p' "$0"; exit 1; }

tmp=$(mktemp -d) && chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

## A URL is fetched to a temp file; the rest reads a file either way
src=$1
case "$src" in
  http://*|https://*)
    curl -fsSL --connect-timeout 15 -o "$tmp/fetched" "$src" && [ -s "$tmp/fetched" ] \
      || { echo "download failed: $src"; exit 1; }
    src=$tmp/fetched ;;
esac
[ -f "$src" ] || { echo "no such file: $src"; exit 1; }

## The stored value is the XML without BOM and surrounding whitespace
xml=$(sed '1s/^\xEF\xBB\xBF//' "$src")
xml=${xml#"${xml%%[![:space:]]*}"}
if [ "${xml:0:1}" != "<" ]; then
  xml=$(printf '%s' "$xml" | base64 -d 2>/dev/null | sed '1s/^\xEF\xBB\xBF//') || { echo "not XML and not base64: $src"; exit 1; }
  xml=${xml#"${xml%%[![:space:]]*}"}
  [ "${xml:0:1}" = "<" ] || { echo "base64 does not decode to XML: $src"; exit 1; }
fi
grep -q '<Keybox' <<< "$xml" || { echo "no <Keybox> in $src"; exit 1; }

## Split the PEM blocks: key<n>.pem, and cert<n>_<m>.pem for the m-th
## certificate after key n (m=1 is the leaf for that key)
sed 's/^[[:space:]]*//; s/<[^>]*>/\n/g' <<< "$xml" | awk -v d="$tmp" '
  /-----BEGIN .*PRIVATE KEY-----/ { k++; c=0; f=d "/key" k ".pem" }
  /-----BEGIN CERTIFICATE-----/   { c++; f=d "/cert" k "_" c ".pem" }
  f && NF { print > f }
  /-----END / { close(f); f="" }'
ls "$tmp"/key*.pem >/dev/null 2>&1 || { echo "no private key found"; exit 1; }

bad=0
for key in "$tmp"/key*.pem; do
  n=${key##*/key}; n=${n%.pem}
  leaf=$tmp/cert${n}_1.pem
  [ -f "$leaf" ] || { echo "key $n: no certificate"; bad=1; continue; }
  if [ "$(openssl pkey -in "$key" -pubout 2>/dev/null)" = "$(openssl x509 -in "$leaf" -noout -pubkey 2>/dev/null)" ]; then
    echo "key $n: matches its certificate"
  else
    echo "key $n: does NOT match its certificate"; bad=1
  fi
done

curl -fsS -H 'Cache-Control: no-cache' "$STATUS_URL" > "$tmp/status.json" \
  || { echo "could not fetch $STATUS_URL"; exit 1; }
for cert in "$tmp"/cert*.pem; do
  ## Google lists serials as lowercase hex without leading zeros
  s=$(openssl x509 -in "$cert" -noout -serial | cut -d= -f2 | tr 'A-F' 'a-f' | sed 's/^0*//')
  subj=$(openssl x509 -in "$cert" -noout -subject -nameopt oneline | cut -d= -f2-)
  st=$(jq -r --arg s "$s" '.entries[$s] // empty | "\(.status) (\(.reason // "no reason"))"' "$tmp/status.json")
  if [ -n "$st" ]; then
    echo "$st: serial $s, $subj"; bad=1
  else
    echo "ok: serial $s, $subj"
  fi
done

[ $bad -eq 0 ] || { echo "keybox not usable, not installed"; exit 2; }
[ $CHECK_ONLY -eq 1 ] && { echo "keybox ok (check only)"; exit 0; }

adb get-state >/dev/null 2>&1 || { echo "no adb device"; exit 1; }
adb shell settings put secure spoof_trickystore_keybox "$(printf '%s' "$xml" | base64 -w0)"
adb shell am force-stop com.android.vending
echo "keybox installed (Play Store stopped; it re-checks on next open)"
