#!/bin/sh
# specter_keybox_fetch.sh
#
# Direct-fetch version of Specter's keybox catalog/fetch/decode pipeline,
# mirroring the implementation at
#   https://github.com/dpejoh/specter/tree/main/src
#     - lib/constants.sh    (URLs, FALLBACK_KEYBOXES, substitution alphabets)
#     - lib/network.sh      (download, check_network)
#     - lib/keybox.sh       (decode_keybox_blob, _parse_serial,
#                            decode_keybox_serial, hex_to_dec, keybox_catalog,
#                            check_google_revocation, keybox_prefer_active)
#     - features/keybox.sh  (catalog scrape -> filter revoked -> prefer active
#                            -> provider version-sort / auto random-select
#                            -> _try_keybox_url structural validation -> install)
#
# This fetches from the REAL endpoints (rawbin.dpejoh.com catalog/keybox blobs,
# android.googleapis.com revocation list). There is no local mock server.
# Device-only steps (keystore-manager detection, ksm_install_keybox,
# CONFIG_DIR val files) are replaced by local equivalents: the validated,
# decoded keybox.xml is written to a local output file instead.
#
# NEW: backend attestation analysis (keybox_info). After a keybox is fetched
# (or via --info on an existing file) the script performs the full Google
# hardware attestation analysis locally, with no external checker service:
#   - private key <-> leaf certificate public key match
#   - root-of-chain identification (Google hardware / software attestation CA)
#   - structure (number of certs, TEE/StrongBox leaves)
#   - format detection (RKP "Droid CA" chains vs legacy hardware attestation)
#   - provisioning info from the leaf extensions:
#       1.3.6.1.4.1.11129.2.1.30  (CBOR: certs_issued, verified_boot,
#                                  vbmeta_digest, boot_state, fingerprint)
#       1.3.6.1.4.1.11129.2.1.17  (standard KeyDescription DER, fallback:
#                                  attestation security level + RootOfTrust)
#   - per-certificate serial/subject/issuer/signature/validity/revocation
#     (every serial is checked against Google's live revocation list)
#   - final verdict, the highest Play-Integrity-style tier the keybox earns:
#       basic  : chain parsed and key material is consistent
#       device : basic + chain verifies hop-by-hop to a Google attestation
#                root + leaf is TEE/StrongBox + leaf currently valid + leaf
#                not revoked (revocation unknown still allows device)
#       strong : device + every cert currently valid + every cert known not
#                revoked + Google hardware attestation root + private key
#                matches the leaf
#
# Wire format (from lib/constants.sh + lib/keybox.sh):
#   on the wire : base64(keybox.xml) re-encoded with SHUFFLED_ALPHABET
#   decode      : tr SHUFFLED_ALPHABET -> STD_ALPHABET, then base64 -d
#
# Usage:
#   sh specter_keybox_fetch.sh [provider] [output-file]
#     provider     : "auto" (default, a random unrevoked catalog keybox) or a
#                    catalog "source" name (e.g. TAKR, mhmrdd, Yuri); "tricky"
#                    (or kowx) = the TAKR source, i.e. the Tricky Addon /
#                    keybox.kowx712.cc repository Specter mirrors (no CAPTCHA
#                    needed); "yuri" and "integrity" fetch those repos directly;
#                    or an http(s) URL to a keybox (raw XML or its base64).
#     output-file  : where the decoded keybox.xml is saved (default ./keybox.xml)
#   sh specter_keybox_fetch.sh list
#     print the whole catalog (every source/version, valid or revoked) and exit.
#   sh specter_keybox_fetch.sh --info [keybox.xml]
#     analyze an existing keybox.xml: print the attestation report and the
#     VERDICT: BASIC|DEVICE|STRONG line to the terminal (no report file is
#     created).
#   sh specter_keybox_fetch.sh -r|--read [dest-folder]
#     no fetch, no analysis: just cp the locally saved keybox.xml and
#     tg_message.txt (see "Local copy store" below) into dest-folder
#     (default: $OUT when set, else ./).
#
# Telegram status message (tg_message.txt):
#   every verification run also (over)writes a one-line Telegram message file:
#     *Status:* 🟢🟢🟢   STRONG
#     *Status:* 🟢🟢🔴   DEVICE
#     *Status:* 🟢🔴🔴   BASIC, failed fetch, or analysis error
#     🔴🔴🔴: revoked   keybox serial is on Google's revocation list
#   "Status:" is bold Telegram Markdown (send the file with
#   parse_mode=Markdown/MarkdownV2). The file is written into the folder of
#   the keybox given on the command line (the input folder), or
#   ./tg_message.txt when no folder is passed.
#   Env overrides:
#     TG_MSG_FILE   absolute/relative path for the message file
#     TG_FORMAT     markdown (default) | html (<b>Status:</b>) | plain
#
# Local copy store:
#   after every run the script mirrors the resulting keybox.xml and
#   tg_message.txt into $HOME/out (hardcoded). -r/--read hands out these
#   copies, so the last known state can be retrieved without network or
#   openssl.
#
# Output contract (for backends):
#   stdout after "RESULT:" carries the attestation report; the last line is
#   always "VERDICT: BASIC", "VERDICT: DEVICE" or "VERDICT: STRONG". The
#   report is printed to the terminal only -- no <output-file>.info is
#   created. The Telegram status line is written as tg_message.txt in the
#   keybox's folder, and copies of keybox.xml + tg_message.txt go into
#   $HOME/out.
#
# Requires: curl or wget, base64, tr, sed, grep, awk, od, openssl.
# Run on a regular Linux/macOS shell -- NOT on a rooted device.

# Telegram status configuration
TG_FORMAT="${TG_FORMAT:-markdown}"

# Hardcoded local copy store for -r/--read (a copy of keybox.xml and
# tg_message.txt is mirrored here after every run).
LOCAL_OUT_DIR="${HOME}/out"

# harness: the repo targets Android mksh/ash, which support ${var:0:n} slicing
# and 16# hex arithmetic used by _parse_serial. dash treats both as fatal
# errors, so re-exec under bash when the current shell is not bash.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "NOTE: bash not found; the serial-decode branch will be skipped." >&2
fi

set -e

PROVIDER="${1:-auto}"
OUTPUT_FILE="${2:-./keybox.xml}"

# fix: if the output argument is a directory (or ends in '/'), save inside it
# under the default name. Otherwise 'cp' drops the decoded file into the
# directory under its random keybox_decode.<pid> temp name -- the script then
# reports success while the keybox is invisible at the requested path, and
# 'wc -c < dir' in the RESULT line fails ("0 ?" bytes).
case "$OUTPUT_FILE" in
  */) OUTPUT_FILE="${OUTPUT_FILE}keybox.xml" ;;
esac
if [ -d "$OUTPUT_FILE" ]; then
  OUTPUT_FILE="${OUTPUT_FILE%/}/keybox.xml"
fi

WORKDIR=$(mktemp -d)
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Repo code, copied/adapted. "harness:" comments mark every deviation.
# ---------------------------------------------------------------------------

# harness: log helpers standing in for lib/log.sh. They write to STDERR:
# keybox_catalog() and check_google_revocation() capture download's stdout,
# and the repo's log functions never write to stdout for the same reason.
log_d() { echo "  [D $1] $2" >&2; }
log_i() { echo "  [I $1] $2" >&2; }
log_w() { echo "  [W $1] $2" >&2; }
log_e() { echo "  [E $1] $2" >&2; }
die()   { log_e "KEYBOX" "$1"; exit 1; }

# -- from lib/constants.sh (verbatim values) --
KEYBOX_URL="https://rawbin.dpejoh.com/key"
CATALOG_URL="https://rawbin.dpejoh.com/catalog"
GOOGLE_REVOCATION_URL="https://android.googleapis.com/attestation/status?encrypted=0"
# single-file providers outside the Specter catalog
YURI_URL="https://raw.githubusercontent.com/Yurii0307/yurikey/main/key"
INTEGRITY_URL="https://github.com/MeowDump/Integrity-Box/releases/download/archive/Megatron"
FALLBACK_KEYBOXES="Yuri/8"

STD_ALPHABET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
SHUFFLED_ALPHABET="1dgWnocayqxU3r6vA5lCIPYfHmkV08b4tz+KMsp2NQ9LRXihODwSj7BEFJ/ZuGTe"

decode_substitution() {
  tr "$SHUFFLED_ALPHABET" "$STD_ALPHABET" < "$1" > "$2"
}

# harness: SPECTER_DIR pointed at a scratch dir; only used for the
# catalog/revocation caches (repo default: /data/adb/specter).
SPECTER_DIR="$WORKDIR/specter"

# -- from lib/network.sh (adapted) --
# harness: dropped the /data/adb/*/bin PATH prefix and busybox-first probe
# (no busybox on desktop); kept the 3-attempt retry, the Specter/1.0 UA,
# the 10s timeouts, the -s size check and the stdout-when-no-output mode.
# A plain-wget fallback was added for desktop portability, and curl gets an
# -m 20 overall cap so a stalled transfer (e.g. filtered host) cannot hang
# the pipeline forever -- the repo only caps the connect phase.
download() {
    _dl_url="$1" _dl_output="$2"
    _dl_tmp="" _dl_code=1 _dl_try=0 _dl_ua="Specter/1.0"

    log_d "NET" "Downloading $_dl_url"

    if [ -z "$_dl_output" ]; then
        _dl_tmp=$(mktemp 2>/dev/null || echo "$WORKDIR/.specter_dl_$$")
        _dl_output="$_dl_tmp"
    fi

    for _dl_try in 1 2 3; do
        if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
            curl --connect-timeout 10 -m 20 -Ls -o "$_dl_output" -A "$_dl_ua" "$_dl_url" 2>/dev/null && [ -s "$_dl_output" ] && { _dl_code=0; break; }
        fi
        if command -v wget >/dev/null 2>&1; then
            wget -T 10 -qO "$_dl_output" -U "$_dl_ua" "$_dl_url" 2>/dev/null && [ -s "$_dl_output" ] && { _dl_code=0; break; }
        fi
        sleep 1
    done

    if [ "$_dl_code" -eq 0 ]; then
        log_d "NET" "Downloaded $(wc -c < "$_dl_output" 2>/dev/null || echo '?') bytes"
    else
        log_w "NET" "Download failed after 3 attempts: $_dl_url"
    fi

    if [ -n "$_dl_tmp" ]; then
        [ "$_dl_code" -eq 0 ] && cat "$_dl_tmp" 2>/dev/null
        rm -f "$_dl_tmp"
    fi

    _dl_rc=$_dl_code
    unset _dl_url _dl_output _dl_tmp _dl_code _dl_try _dl_ua
    return $_dl_rc
}

# harness: the repo pings 1.1.1.1 / generate_204; here we probe the real
# catalog endpoint, which doubles as a "server is up" check.
check_network() {
    curl --connect-timeout 5 -fsSL "$CATALOG_URL" 2>/dev/null | grep -q '"entries"' && return 0
    wget -T 5 -qO- "$CATALOG_URL" 2>/dev/null | grep -q '"entries"' && return 0
    return 1
}

ensure_dir() { mkdir -p "$1" 2>/dev/null; }

# -- from lib/keybox.sh (verbatim) --
decode_keybox_blob() {
  _dkb_in="$1" _dkb_out="$2"
  _dkb_tmp="$WORKDIR/_dkb_$$.tmp"
  decode_substitution "$_dkb_in" "$_dkb_tmp" 2>/dev/null || { rm -f "$_dkb_tmp"; return 1; }
  base64 -d < "$_dkb_tmp" > "$_dkb_out" 2>/dev/null || { rm -f "$_dkb_tmp"; return 1; }
  rm -f "$_dkb_tmp"
  unset _dkb_in _dkb_out _dkb_tmp
}

# shellcheck disable=SC3057,SC3052
_parse_serial() {
  _h="$1"
  case "${_h:0:1}" in "") return 1 ;; esac 2>/dev/null || { log_w "KEYBOX" "Shell lacks string slicing, skipping serial decode"; return 1; }
  case "$_h" in 30*) _h="${_h#30}" ;; *) return 1 ;; esac
  _l_hex="${_h:0:2}" _l_dec=$((16#$_l_hex))
  [ $_l_dec -ge 128 ] && _h="${_h:2 + ($_l_dec - 128) * 2}" || _h="${_h:2}"

  case "$_h" in 30*) _h="${_h#30}" ;; *) return 1 ;; esac
  _l_hex="${_h:0:2}" _l_dec=$((16#$_l_hex))
  [ $_l_dec -ge 128 ] && _h="${_h:2 + ($_l_dec - 128) * 2}" || _h="${_h:2}"

  case "$_h" in
    a0*)
      _ctx_len_hex="${_h:2:2}"
      _ctx_len=$((16#$_ctx_len_hex))
      _h="${_h:4 + _ctx_len * 2}"
      ;;
  esac

  case "$_h" in 02*) _h="${_h#02}" ;; *) return 1 ;; esac
  _l_hex="${_h:0:2}" _l_dec=$((16#$_l_hex))
  if [ $_l_dec -ge 128 ]; then
    _n=$((_l_dec - 128))
    _sl=$((16#${_h:2:_n * 2}))
    _serial_hex="${_h:2 + _n * 2:$_sl * 2}"
  else
    _serial_hex="${_h:2:$_l_dec * 2}"
  fi

  _serial=$(echo "$_serial_hex" | sed 's/^0*//')
  [ -z "$_serial" ] && _serial="0"
  return 0
}

decode_keybox_serial() {
  _b64=$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p; /-----END CERTIFICATE-----/q' "$1" | grep -v 'CERTIFICATE' | sed 's/^[[:space:]]*//' | tr -d '\n')
  [ -z "$_b64" ] && return 1
  _hex=$(echo "$_b64" | base64 -d 2>/dev/null | od -v -tx1 | awk 'BEGIN{ORS=""} {for(i=2;i<=NF;i++) printf "%s", $i}')
  [ -z "$_hex" ] && return 1
  _parse_serial "$_hex" || return 1
  echo "$_serial"
}

# Shared catalog fetch. keybox.sh and keybox_info.sh run back to back in the
# action pipeline; a short cache keeps them from downloading it twice.
keybox_catalog() {
  _kc_cache="$SPECTER_DIR/cache/keybox_catalog.json"
  _kc_ttl="${KEYBOX_CATALOG_TTL:-300}"
  if [ -s "$_kc_cache" ]; then
    _kc_age=$(( $(date +%s) - $(stat -c %Y "$_kc_cache" 2>/dev/null || stat -f %m "$_kc_cache" 2>/dev/null || echo 0) ))
    if [ "$_kc_age" -ge 0 ] && [ "$_kc_age" -lt "$_kc_ttl" ]; then
      cat "$_kc_cache"
      unset _kc_cache _kc_ttl _kc_age
      return 0
    fi
  fi
  _kc_json=$(download "$CATALOG_URL" 2>/dev/null) || _kc_json=""
  if [ -n "$_kc_json" ]; then
    ensure_dir "$SPECTER_DIR/cache"
    printf '%s' "$_kc_json" > "$_kc_cache" 2>/dev/null || true
    printf '%s' "$_kc_json"
    unset _kc_cache _kc_ttl _kc_age _kc_json
    return 0
  fi
  unset _kc_cache _kc_ttl _kc_age _kc_json
  return 1
}

# harness: split out of check_google_revocation so the attestation report can
# reuse one cached copy of Google's revocation list for every certificate.
# Echoes the path of the (fresh or stale) status JSON, or fails when nothing
# is available offline.
google_revocation_file() {
  _grf_cache="$SPECTER_DIR/cache/google_revocation.json"
  _grf_ttl="${GOOGLE_REVOCATION_TTL:-3600}"
  _grf_ok=0
  if [ -s "$_grf_cache" ]; then
    _grf_age=$(( $(date +%s) - $(stat -c %Y "$_grf_cache" 2>/dev/null || stat -f %m "$_grf_cache" 2>/dev/null || echo 0) ))
    if [ "$_grf_age" -ge 0 ] && [ "$_grf_age" -lt "$_grf_ttl" ]; then
      _grf_ok=1
    fi
  fi
  if [ "$_grf_ok" -eq 0 ]; then
    _grf_resp=$(download "$GOOGLE_REVOCATION_URL" 2>/dev/null) || _grf_resp=""
    if [ -n "$_grf_resp" ] && printf '%s' "$_grf_resp" | grep -q '"entries"'; then
      ensure_dir "$SPECTER_DIR/cache"
      cat > "$_grf_cache" <<EOF
$_grf_resp
EOF
      _grf_ok=1
    fi
  fi
  if [ "$_grf_ok" -eq 1 ] || [ -s "$_grf_cache" ]; then
    printf '%s' "$_grf_cache"
    unset _grf_cache _grf_ttl _grf_ok _grf_age _grf_resp
    return 0
  fi
  unset _grf_cache _grf_ttl _grf_ok _grf_age _grf_resp
  return 1
}

# Google's attestation list (?encrypted=0) keys each revoked serial as a
# lowercase hex string with leading zeros dropped. Return 0 if $1 (a hex
# serial) is present in the list file $2.
serial_revoked() {
  _sr_s=$(printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0*//')
  [ -n "$_sr_s" ] || return 1
  grep -Fq "\"$_sr_s\"" "$2"
}

check_google_revocation() {
  _gr_serial=$1
  _gr_file=""
  if ! _gr_file=$(google_revocation_file); then
    _gr_file=""
  fi
  _gr_rc=1
  if [ -n "$_gr_file" ] && grep -q '"entries"' "$_gr_file"; then
    serial_revoked "$_gr_serial" "$_gr_file" && _gr_rc=0
  fi
  # note: _gr_rc must survive the unset -- the repo's original unsets every
  # helper EXCEPT the return code, otherwise return sees an empty variable
  # and always reports 0 ("revoked").
  unset _gr_serial _gr_file
  return $_gr_rc
}

# Prefer active (non-softbanned) candidates. stdin: one JSON object per line
# with source/version. $1 = full catalog JSON. stdout: preferred pool.
keybox_prefer_active() {
  _kpa_hist="$1"
  KEYBOX_CATALOG="$_kpa_hist" awk '
    function field(obj, key,   r) {
      if (!match(obj, "\"" key "\":\"[^\"]*\"")) return ""
      r = substr(obj, RSTART, RLENGTH)
      sub("^\"" key "\":\"", "", r)
      sub("\"$", "", r)
      return r
    }
    BEGIN {
      hist = ENVIRON["KEYBOX_CATALOG"]
      if (match(hist, /"entries":\[[^]]*\]/)) {
        hist = substr(hist, RSTART, RLENGTH)
      } else {
        hist = ""
      }
      while (match(hist, /\{[^{}]*\}/)) {
        obj = substr(hist, RSTART, RLENGTH)
        hist = substr(hist, RSTART + RLENGTH)
        src = field(obj, "source")
        ver = field(obj, "version")
        if (src != "" && ver != "") {
          soft[src SUBSEP ver] = (obj ~ /"softbanned":true/) ? 1 : 0
        }
      }
    }
    {
      src = field($0, "source")
      ver = field($0, "version")
      if (((src SUBSEP ver) in soft) && soft[src, ver]) {
        softout = softout $0 "\n"
      } else {
        activeout = activeout $0 "\n"
      }
    }
    END {
      if (activeout != "") printf "%s", activeout
      else printf "%s", softout
    }
  '
  unset _kpa_hist
}

# ---------------------------------------------------------------------------
# Backend attestation analysis (keybox_info)
#
# Reproduces, locally and offline except for Google's revocation list, the
# hardware attestation report:
#
#   Google Hardware Attestation · valid until 2026-11-04
#   ─────────────
#   ✅ Private key ↔️ leaf cert
#   ✅ Root: Google Hardware
#   ✅ Structure: 4 certs · 1 TEE
#   🔷 Format: RKP (Remote Key Provisioning) · expires in 3 days 22 hours
#   ├ Provisioning info:
#   │    ├─ certs_issued=64
#   │    ├─ verified_boot=APPROVED
#   │    ├─ vbmeta_digest=...
#   │    ├─ boot_state=APPROVED
#   │    └─ fingerprint=...
#   ✅ Revocation: not revoked
#   🔐 Cert #1 · TEE
#   ...
#   VERDICT: STRONG
#
# Extension 1.3.6.1.4.1.11129.2.1.30 carries a small CBOR map
#   { 1: certs_issued, 5: { 1: verified_boot, 2: vbmeta_digest,
#                           3: boot_state,   4: fingerprint } }
# which is the primary provisioning source; the standard KeyDescription
# extension (…2.1.17, DER) is parsed as a fallback.
# ---------------------------------------------------------------------------

ATTEST_OID_KEYDESC="1.3.6.1.4.1.11129.2.1.17"
ATTEST_OID_GOOGLE="1.3.6.1.4.1.11129.2.1.30"

have_openssl() { command -v openssl >/dev/null 2>&1; }

# openssl options used for hop-by-hop chain verification; probed once because
# older openssl builds lack -no_check_time (we test signatures separately from
# the validity windows, which get their own ✅/❌ per certificate).
KI_VERIFY_OPTS=""
if have_openssl; then
  _kiv_h=$(openssl verify -help 2>&1 || true)
  case "$_kiv_h" in *-no_check_time*) KI_VERIFY_OPTS="-no_check_time" ;; esac
  case "$_kiv_h" in *-partial_chain*) KI_VERIFY_OPTS="$KI_VERIFY_OPTS -partial_chain" ;; esac
  unset _kiv_h
fi

# "Nov  4 10:54:52 2026 GMT" -> epoch seconds (GNU date, then BSD date).
epoch_of_date() {
  _eod_d=$(printf '%s' "$1" | sed 's/  */ /g; s/^ //; s/ $//')
  _eod_e=""
  _eod_e=$(date -d "$_eod_d" +%s 2>/dev/null) || _eod_e=""
  if [ -z "$_eod_e" ]; then
    _eod_e=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$_eod_d" +%s 2>/dev/null) || _eod_e=""
  fi
  if [ -z "$_eod_e" ]; then
    _eod_e=$(date -j -f "%b %e %H:%M:%S %Y %Z" "$_eod_d" +%s 2>/dev/null) || _eod_e=""
  fi
  printf '%s' "${_eod_e:-}"
  unset _eod_d _eod_e
}

iso_of_epoch() {
  _ioe_e="$1"
  _ioe_s=""
  if [ -n "$_ioe_e" ]; then
    _ioe_s=$(date -u -d "@$_ioe_e" +%F 2>/dev/null) || _ioe_s=""
    if [ -z "$_ioe_s" ]; then
      _ioe_s=$(date -u -r "$_ioe_e" +%F 2>/dev/null) || _ioe_s=""
    fi
  fi
  printf '%s' "$_ioe_s"
  unset _ioe_e _ioe_s
}

# 357942 -> "3 days 22 hours" (also used for the expired variant).
fmt_countdown() {
  _fc_s=$1
  _fc_d=$((_fc_s / 86400))
  _fc_h=$(( (_fc_s % 86400) / 3600 ))
  _fc_m=$(( (_fc_s % 3600) / 60 ))
  if [ "$_fc_d" -gt 0 ]; then
    _fc_r="${_fc_d} day$([ "$_fc_d" -eq 1 ] || printf s) ${_fc_h} hour$([ "$_fc_h" -eq 1 ] || printf s)"
  elif [ "$_fc_h" -gt 0 ]; then
    _fc_r="${_fc_h} hour$([ "$_fc_h" -eq 1 ] || printf s) ${_fc_m} minute$([ "$_fc_m" -eq 1 ] || printf s)"
  else
    _fc_r="${_fc_m} minute$([ "$_fc_m" -eq 1 ] || printf s)"
  fi
  printf '%s' "$_fc_r"
  unset _fc_s _fc_d _fc_h _fc_m _fc_r
}

# Split every <Key ...>...</Key> element into its own file (key-1.xml, ...);
# echoes the number of key elements found. Handles both the flat layout
# (<Certificate> directly under <Key>) and the <CertificateChain> wrapper,
# because extraction below simply collects every PEM block inside the element.
split_key_elements() {
  _ske_file="$1" _ske_dir="$2"
  mkdir -p "$_ske_dir" 2>/dev/null || true
  awk -v dir="$_ske_dir" '
    { line = $0; sub(/\r$/, "", line) }
    !open && line ~ /<Key[ \t>]/ { open = 1; n++; fn = dir "/key-" n ".xml" }
    open { print line > fn }
    open && line ~ /<\/Key>/ { close(fn); open = 0 }
    END { print n + 0 }
  ' "$_ske_file"
  unset _ske_file _ske_dir
}

# Collect every PEM CERTIFICATE block inside a <Key> element (or a whole
# keybox file) as cert-1.pem, cert-2.pem, ... in file order. Every line is
# dedented: openssl 3.x refuses PEM whose base64 body carries leading
# whitespace, and keybox.xml stores the certificates indented.
extract_certs_from_key() {
  _ecf_file="$1" _ecf_dir="$2"
  mkdir -p "$_ecf_dir" 2>/dev/null || true
  awk -v dir="$_ecf_dir" '
    { line = $0; sub(/\r$/, "", line); sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line ~ /^-----BEGIN CERTIFICATE-----/ { n++; fn = dir "/cert-" n ".pem"; open = 1 }
    open { print line > fn }
    line ~ /^-----END CERTIFICATE-----/ { if (open) close(fn); open = 0 }
    END { print n + 0 }
  ' "$_ecf_file"
  unset _ecf_file _ecf_dir
}

# First private key block (RSA/EC/encrypted/PKCS8) -> $2; echoes 1 if found.
extract_privkey_from_key() {
  _epk_file="$1" _epk_out="$2"
  awk -v out="$_epk_out" '
    { line = $0; sub(/\r$/, "", line); sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    !done && line ~ /^-----BEGIN [A-Z ]*PRIVATE KEY-----/ { open = 1 }
    open && !done { print line > out; wrote = 1 }
    open && line ~ /^-----END [A-Z ]*PRIVATE KEY-----/ { open = 0; done = 1 }
    END { if (wrote) close(out); print done + 0 }
  ' "$_epk_file"
  unset _epk_file _epk_out
}

# Hex bytes of an extension value (extnValue content) for OID $2, extracted
# from `openssl asn1parse` (which prints raw HEX DUMPs for unknown OCTET
# STRING extensions -- `x509 -text` renders them as ASCII art instead).
cert_ext_hex() {
  _ceh_cert="$1" _ceh_oid="$2"
  openssl asn1parse -in "$_ceh_cert" -inform PEM 2>/dev/null | awk -v oid="$_ceh_oid" '
    hit == 0 {
      if (index($0, "OBJECT") > 0 && index($0, ":" oid) > 0) { hit = 1; scanned = 0 }
      next
    }
    {
      scanned++
      if (match($0, /\[HEX DUMP\]:/)) { print substr($0, RSTART + RLENGTH); exit }
      if (scanned >= 4) exit
    }
  ' | tr -d ' \t\n\r' | tr 'A-F' 'a-f'
  unset _ceh_cert _ceh_oid
}

# Minimal CBOR walker (uint / byte string / text string / array / map / tag).
# Input: hex on stdin. Output: "path=value" lines where text values carry an
# "s:" prefix and byte strings an "x:" prefix. Used for the Google
# provisioning extension (…2.1.30): {1: certs_issued, 5: {1: verified_boot,
# 2: vbmeta_digest, 3: boot_state, 4: fingerprint}}.
parse_cbor_map() {
  awk '
    function h2i(c) { return index("0123456789abcdef", c) - 1 }
    function hb(i) { return substr(H, i * 2 + 1, 2) }
    function h2b(i,   s) { s = hb(i); return h2i(substr(s, 1, 1)) * 16 + h2i(substr(s, 2, 1)) }
    function rdlen(a, ai,   v, i) {
      if (ai < 24) { LEN = ai; return a }
      if (ai == 24) { LEN = h2b(a); return a + 1 }
      if (ai == 25) { LEN = h2b(a) * 256 + h2b(a + 1); return a + 2 }
      if (ai == 26) {
        LEN = 0
        for (i = 0; i < 4; i++) LEN = LEN * 256 + h2b(a + i)
        return a + 4
      }
      LEN = -1
      return a
    }
    function txt(a, l,   s, i, c) {
      s = ""
      for (i = 0; i < l; i++) {
        c = h2b(a + i)
        if (c < 32 || c > 126) return ""
        s = s sprintf("%c", c)
      }
      return s
    }
    function parse_item(a, path,   b, mt, ai, p, q, i, kb, kmt, kai, kq, key, np, s) {
      if (a < 0 || a >= N) { NXT = N; return }
      b = h2b(a); mt = int(b / 32); ai = b % 32
      p = rdlen(a + 1, ai)
      if (LEN < 0) { NXT = N; return }
      if (mt == 0) { printf "%s=%d\n", path, LEN; NXT = p; return }
      if (mt == 1) { printf "%s=-%d\n", path, LEN + 1; NXT = p; return }
      if (mt == 2) { printf "%s=x:%s\n", path, substr(H, p * 2 + 1, LEN * 2); NXT = p + LEN; return }
      if (mt == 3) {
        s = txt(p, LEN)
        if (s != "") printf "%s=s:%s\n", path, s
        else printf "%s=x:%s\n", path, substr(H, p * 2 + 1, LEN * 2)
        NXT = p + LEN
        return
      }
      if (mt == 4) {
        q = p
        for (i = 0; i < LEN && q < N; i++) { parse_item(q, path); q = NXT }
        return
      }
      if (mt == 5) {
        q = p
        for (i = 0; i < LEN && q < N; i++) {
          if (q >= N) break
          kb = h2b(q); kmt = int(kb / 32); kai = kb % 32
          if (kmt == 0) {
            kq = rdlen(q + 1, kai)
            if (LEN < 0) { NXT = N; return }
            key = sprintf("%d", LEN)
          } else if (kmt == 3) {
            kq = rdlen(q + 1, kai)
            if (LEN < 0) { NXT = N; return }
            key = txt(kq, LEN)
          } else { NXT = N; return }
          np = (path == "" ? key : path "." key)
          parse_item(kq, np)
          q = NXT
        }
        return
      }
      if (mt == 6) { parse_item(p, path); return }
      NXT = N
    }
    { H = H tolower($0) }
    END {
      gsub(/[^0-9a-f]/, "", H)
      N = int(length(H) / 2)
      if (N > 0) parse_item(0, "")
    }
  '
}

# Minimal DER walker for the standard key attestation KeyDescription
# (…2.1.17). Input: hex of the extension value on stdin. Output:
#   ATT_VER / ATT_SEC / KM_VER / KM_SEC   (top-level fields)
#   ROT_KEY / ROT_LOCKED / ROT_STATE / ROT_HASH  (RootOfTrust, TEE list)
#   <PRE>TAG<num>=<value>                 (authorization list entries)
# Context tags are parsed incl. high tag numbers (710+); repeated tags print
# as [a,b,c]; RootOfTrust is only read from the TEE list.
parse_keydescription() {
  awk '
    function h2i(c) { return index("0123456789abcdef", c) - 1 }
    function hb(i) { return substr(H, i * 2 + 1, 2) }
    function h2b(i,   s) { s = hb(i); return h2i(substr(s, 1, 1)) * 16 + h2i(substr(s, 2, 1)) }
    function gettlv(p,   b, q, c, i, l0, nb) {
      TLV_err = 1
      if (p < 0 || p * 2 + 2 > length(H)) return
      b = h2b(p)
      TLV_cls = int(b / 64); b = b - TLV_cls * 64
      TLV_cons = int(b / 32); b = b - TLV_cons * 32
      TLV_num = b
      q = p + 1
      if (b == 31) {
        TLV_num = 0
        do {
          if (q * 2 + 2 > length(H)) return
          c = h2b(q); TLV_num = TLV_num * 128 + (c % 128); q++
        } while (c >= 128)
      }
      if (q * 2 + 2 > length(H)) return
      l0 = h2b(q); q++
      if (l0 < 128) {
        TLV_len = l0
      } else {
        nb = l0 - 128
        if (nb < 1 || q * 2 + nb * 2 > length(H)) return
        TLV_len = 0
        for (i = 0; i < nb; i++) TLV_len = TLV_len * 256 + h2b(q + i)
        q = q + nb
      }
      if (q * 2 + TLV_len * 2 > length(H)) return
      TLV_val = q; TLV_next = q + TLV_len
      TLV_err = 0
    }
    function tlvint(a, l,   v, i) {
      v = 0
      for (i = 0; i < l; i++) {
        v = v * 256 + h2b(a + i)
        if (v > 1e15) return -1
      }
      return v
    }
    function tlvhex(a, l) { return substr(H, a * 2 + 1, l * 2) }
    function tlvtxt(a, l,   s, i, c) {
      s = ""
      for (i = 0; i < l; i++) {
        c = h2b(a + i)
        if (c < 32 || c > 126) return ""
        s = s sprintf("%c", c)
      }
      return s
    }
    function parse_rot(a0, a1,   p, idx) {
      p = a0
      if (p >= a1) return
      gettlv(p)
      if (TLV_err) return
      if (TLV_cls == 0 && TLV_cons == 1 && TLV_num == 16) { a0 = TLV_val; a1 = TLV_val + TLV_len }
      idx = 0; p = a0
      while (p < a1) {
        gettlv(p)
        if (TLV_err) return
        idx++
        if (idx == 1) printf "ROT_KEY=%s\n", tlvhex(TLV_val, TLV_len)
        else if (idx == 2) printf "ROT_LOCKED=%d\n", (h2b(TLV_val) != 0)
        else if (idx == 3) printf "ROT_STATE=%d\n", tlvint(TLV_val, TLV_len)
        else if (idx == 4) printf "ROT_HASH=%s\n", tlvhex(TLV_val, TLV_len)
        p = TLV_next
      }
    }
    function emit_tag(pre, num, a, l,   v, s) {
      if (l == 0) { printf "%sTAG%d=true\n", pre, num; return }
      if (l == 1 && (num == 7 || num == 503 || num == 506 || num == 507 || num == 508 || num == 509 || num == 600 || num == 720)) {
        printf "%sTAG%d=%s\n", pre, num, (h2i(hb(a)) != 0 ? "true" : "false")
        return
      }
      s = tlvtxt(a, l)
      if (s != "" && l >= 3) { printf "%sTAG%d=s:%s\n", pre, num, s; return }
      if (l <= 6) {
        v = tlvint(a, l)
        if (v >= 0) { printf "%sTAG%d=%d\n", pre, num, v; return }
      }
      printf "%sTAG%d=x:%s\n", pre, num, tlvhex(a, l)
    }
    function parse_list(pre, num, a0, a1,   p, v, vals) {
      p = a0; vals = ""
      while (p < a1) {
        gettlv(p)
        if (TLV_err) return
        if (!TLV_cons) {
          v = tlvint(TLV_val, TLV_len)
          if (v >= 0) vals = (vals == "" ? "" : vals ",") v
        }
        p = TLV_next
      }
      printf "%sTAG%d=[%s]\n", pre, num, vals
    }
    function parse_auth(a0, a1, pre,   p, nx) {
      p = a0
      while (p < a1) {
        gettlv(p)
        if (TLV_err) return
        nx = TLV_next
        if (TLV_cls == 2) {
          if (TLV_cons) {
            if (TLV_num == 704) {
              if (pre == "TEE") parse_rot(TLV_val, TLV_val + TLV_len)
            } else {
              parse_list(pre, TLV_num, TLV_val, TLV_val + TLV_len)
            }
          } else {
            emit_tag(pre, TLV_num, TLV_val, TLV_len)
          }
        }
        p = nx
      }
    }
    { H = H tolower($0) }
    END {
      gsub(/[^0-9a-f]/, "", H)
      if (length(H) < 8) exit
      if (h2b(0) == 4) { gettlv(0); if (!TLV_err) H = tlvhex(TLV_val, TLV_len) }
      gettlv(0)
      if (TLV_err || TLV_cls != 0 || TLV_num != 16 || TLV_cons != 1) { print "PARSEERR=1"; exit }
      top_end = TLV_val + TLV_len
      p = TLV_val; idx = 0
      while (p < top_end) {
        gettlv(p)
        if (TLV_err) break
        nx = TLV_next; idx++
        if (idx == 1) printf "ATT_VER=%d\n", tlvint(TLV_val, TLV_len)
        else if (idx == 2) printf "ATT_SEC=%d\n", tlvint(TLV_val, TLV_len)
        else if (idx == 3) printf "KM_VER=%d\n", tlvint(TLV_val, TLV_len)
        else if (idx == 4) printf "KM_SEC=%d\n", tlvint(TLV_val, TLV_len)
        else if (idx == 7) parse_auth(TLV_val, TLV_val + TLV_len, "SW")
        else if (idx == 8) parse_auth(TLV_val, TLV_val + TLV_len, "TEE")
        p = nx
      }
    }
  '
}

cert_serial_hex() {
  openssl x509 -in "$1" -noout -serial 2>/dev/null | sed 's/^serial=//' | tr -d ' \n\r' | tr 'A-F' 'a-f'
}

# One RDN per line ("O=TEE", "CN=Droid CA3") in DER order, via -nameopt compat.
cert_dn_items() {
  openssl x509 -in "$2" -noout "-$1" -nameopt compat 2>/dev/null \
    | sed 's/^subject=//;s/^issuer=//' \
    | awk -F/ '{ for (i = 1; i <= NF; i++) { s = $i; gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); if (s != "") print s } }'
}

cert_notbefore() { openssl x509 -in "$1" -noout -startdate 2>/dev/null | sed 's/^notBefore=//;s/  */ /g;s/^ //'; }
cert_notafter()  { openssl x509 -in "$1" -noout -enddate 2>/dev/null   | sed 's/^notAfter=//;s/  */ /g;s/^ //'; }

cert_sig_label() {
  _csl_a=$(openssl x509 -in "$1" -noout -text 2>/dev/null | grep -m1 "Signature Algorithm" | grep -oiE 'sha[0-9]+|ed25519|ed448|md5' | head -1)
  if [ -n "$_csl_a" ]; then
    printf '%s' "$_csl_a" | tr '[:lower:]' '[:upper:]'
  else
    printf '%s' "unknown"
  fi
  unset _csl_a
}

# TEE / StrongBox / Software label for a certificate: first from the subject
# (vendors encode it as O=TEE, title=TEE, O=StrongBox, ...), then from the
# standard attestation extension security level (0 Software/1 TEE/2 StrongBox).
cert_label() {
  _cl_cert="$1"
  _cl_lab=""
  _cl_v=$(cert_dn_items subject "$_cl_cert" \
    | awk -F= '{ v = ""; for (i = 2; i <= NF; i++) v = v (i > 2 ? "=" : "") $i; print tolower(v) }' \
    | grep -xE 'tee|strongbox|strong_box|software' | head -1)
  case "${_cl_v:-}" in
    tee) _cl_lab="TEE" ;;
    strongbox|strong_box) _cl_lab="StrongBox" ;;
    software) _cl_lab="Software" ;;
  esac
  if [ -z "$_cl_lab" ]; then
    _cl_att=$(cert_ext_hex "$_cl_cert" "$ATTEST_OID_KEYDESC" | parse_keydescription)
    _cl_sec=$(printf '%s\n' "$_cl_att" | sed -n 's/^ATT_SEC=//p' | head -1)
    case "${_cl_sec:-}" in
      2) _cl_lab="StrongBox" ;;
      1) _cl_lab="TEE" ;;
      0) _cl_lab="Software" ;;
    esac
  fi
  printf '%s' "${_cl_lab:--}"
  unset _cl_cert _cl_lab _cl_v _cl_att _cl_sec
}

# 0: private key matches the leaf public key; 1: mismatch; 2: no private key.
key_matches_cert() {
  _kmc_key="$1" _kmc_cert="$2"
  [ -s "$_kmc_key" ] || return 2
  _kmc_a=$(openssl pkey -in "$_kmc_key" -pubout 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
  _kmc_b=$(openssl x509 -in "$_kmc_cert" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
  if [ -n "$_kmc_a" ] && [ -n "$_kmc_b" ] && [ "$_kmc_a" = "$_kmc_b" ]; then
    unset _kmc_key _kmc_cert _kmc_a _kmc_b
    return 0
  fi
  unset _kmc_key _kmc_cert _kmc_a _kmc_b
  return 1
}

# ---------------------------------------------------------------------------
# Telegram status message (tg_message.txt)
#
# Every verification run (over)writes a one-line Telegram message next to the
# analyzed keybox -- i.e. inside the input folder passed on the command line,
# or ./tg_message.txt when no folder was passed:
#
#   *Status:* 🟢🟢🟢   STRONG
#   *Status:* 🟢🟢🔴   DEVICE
#   *Status:* 🟢🔴🔴   BASIC, failed fetch, or analysis error
#   🔴🔴🔴: revoked   keybox serial is on Google's revocation list
#
# "Status:" is bold Telegram Markdown; send the file content with
# parse_mode=Markdown or MarkdownV2. TG_FORMAT=html emits <b>Status:</b>
# instead, TG_FORMAT=plain emits unformatted text.
# ---------------------------------------------------------------------------

# Default tg_message.txt location for a keybox path: the keybox's folder
# ("the input folder from the cmd"), or ./tg_message.txt when the path has
# no directory component. TG_MSG_FILE overrides both.
tg_message_path() {
  if [ -n "${TG_MSG_FILE:-}" ]; then
    printf '%s' "$TG_MSG_FILE"
    return 0
  fi
  _tmp_dir=$(dirname "$1" 2>/dev/null || printf '.')
  case "$_tmp_dir" in
    ""|".") printf '%s' "./tg_message.txt" ;;
    *)      printf '%s/tg_message.txt' "$_tmp_dir" ;;
  esac
  unset _tmp_dir
}

# Write the status line. $1 = target file, $2 = state:
#   STRONG | DEVICE | BASIC | REVOKED | "" (failed fetch / analysis error).
# Cumulative meter -- one green dot per tier reached:
#   STRONG   -> *Status:* 🟢🟢🟢
#   DEVICE   -> *Status:* 🟢🟢🔴
#   BASIC/"" -> *Status:* 🟢🔴🔴
#   REVOKED  -> 🔴🔴🔴: revoked
tg_write_status() {
  _tg_file="$1" _tg_state="${2:-}"
  [ -n "$_tg_file" ] || return 0

  case "$_tg_state" in
    STRONG)  _tg_meter="🟢🟢🟢" _tg_prefix=1 ;;
    DEVICE)  _tg_meter="🟢🟢🔴" _tg_prefix=1 ;;
    REVOKED) _tg_meter="🔴🔴🔴: revoked" _tg_prefix=0 ;;
    *)       _tg_meter="🟢🔴🔴" _tg_prefix=1 ;;
  esac

  mkdir -p "$(dirname "$_tg_file")" 2>/dev/null || true
  if [ "$_tg_prefix" -eq 1 ]; then
    case "$TG_FORMAT" in
      html)  printf '<b>Status:</b> %s\n' "$_tg_meter" > "$_tg_file" || log_w "TG" "could not write $_tg_file" ;;
      plain) printf 'Status: %s\n' "$_tg_meter" > "$_tg_file" || log_w "TG" "could not write $_tg_file" ;;
      *)     printf '*Status:* %s\n' "$_tg_meter" > "$_tg_file" || log_w "TG" "could not write $_tg_file" ;;
    esac
  else
    printf '%s\n' "$_tg_meter" > "$_tg_file" || log_w "TG" "could not write $_tg_file"
  fi
  [ -f "$_tg_file" ] && log_i "TG" "Telegram status written to $_tg_file: $_tg_meter (${_tg_state:-no verdict})"
  unset _tg_file _tg_state _tg_meter _tg_prefix
  return 0
}

# ---------------------------------------------------------------------------
# Local copy store ($HOME/out, hardcoded)
#
# After every run the resulting keybox.xml and tg_message.txt are mirrored
# here, so `-r|--read` can copy the last known state anywhere without
# touching the network or openssl. On failed runs only the status file is
# refreshed -- the last good keybox copy is kept.
# ---------------------------------------------------------------------------

local_backup() {  # $1 = keybox path (empty = keep old copy), $2 = tg path
  _lb_kb="$1" _lb_tg="$2"
  mkdir -p "$LOCAL_OUT_DIR" 2>/dev/null || true
  if [ -n "$_lb_kb" ] && [ -f "$_lb_kb" ]; then
    cp "$_lb_kb" "$LOCAL_OUT_DIR/keybox.xml" 2>/dev/null \
      || log_w "BACKUP" "could not copy keybox to $LOCAL_OUT_DIR"
  fi
  if [ -n "$_lb_tg" ] && [ -f "$_lb_tg" ]; then
    cp "$_lb_tg" "$LOCAL_OUT_DIR/tg_message.txt" 2>/dev/null \
      || log_w "BACKUP" "could not copy tg message to $LOCAL_OUT_DIR"
  fi
  unset _lb_kb _lb_tg
  return 0
}

# The report itself; prints to stdout. Fatal errors (unreadable file, no
# certificates) return non-zero; a produced report always returns 0.
# $2 (optional): path of the tg_message.txt to write with the verdict.
keybox_info() {
  _ki_file="${1:-./keybox.xml}"
  _ki_tg="${2:-}"

  if ! have_openssl; then
    echo "⚠ openssl not available — attestation analysis skipped"
    echo "VERDICT: BASIC"
    tg_write_status "$_ki_tg" ""   # no analysis ran -> BASIC-style meter
    return 0
  fi
  if [ ! -f "$_ki_file" ]; then
    log_e "INFO" "keybox file not found: $_ki_file"
    return 1
  fi

  log_i "INFO" "Analyzing attestation chain in $_ki_file"

  _ki_work="$WORKDIR/attest"
  rm -rf "$_ki_work" 2>/dev/null || true
  mkdir -p "$_ki_work" || return 1
  _ki_rep="$_ki_work/report.txt"
  : > "$_ki_rep"

  # -- 1. split <Key> elements, keep the chain with the best attestation ----
  _ki_nkeys=$(split_key_elements "$_ki_file" "$_ki_work/keys")
  if [ "${_ki_nkeys:-0}" -lt 1 ]; then
    _ki_nkeys=1
    mkdir -p "$_ki_work/keys"
    cp "$_ki_file" "$_ki_work/keys/key-1.xml"
  fi

  _ki_pick=1
  _ki_pick_score=-1
  _ki_pick_alg=""
  _ki_k=1
  while [ "$_ki_k" -le "$_ki_nkeys" ]; do
    _ki_kf="$_ki_work/keys/key-$_ki_k.xml"
    _ki_nc=$(extract_certs_from_key "$_ki_kf" "$_ki_work/k$_ki_k")
    _ki_score=0
    if [ "${_ki_nc:-0}" -ge 1 ]; then
      _ki_lab=$(cert_label "$_ki_work/k$_ki_k/cert-1.pem")
      case "$_ki_lab" in
        TEE|StrongBox) _ki_score=2 ;;
        Software) _ki_score=1 ;;
      esac
    fi
    if [ "$_ki_score" -gt "$_ki_pick_score" ]; then
      _ki_pick_score=$_ki_score
      _ki_pick=$_ki_k
      _ki_pick_alg=$(sed -n 's/.*<Key algorithm="\([a-z]*\)".*/\1/p' "$_ki_kf" 2>/dev/null | head -1)
    fi
    _ki_k=$((_ki_k + 1))
  done
  unset _ki_k _ki_kf _ki_nc _ki_score _ki_lab

  _ki_dir="$_ki_work/k$_ki_pick"
  _ki_ncerts=$(extract_certs_from_key "$_ki_work/keys/key-$_ki_pick.xml" "$_ki_dir")
  if [ "${_ki_ncerts:-0}" -lt 1 ]; then
    log_e "INFO" "no certificates found in keybox"
    return 1
  fi
  log_d "INFO" "analyzing key #$_ki_pick (${_ki_pick_alg:-unknown}), $_ki_ncerts certificates"

  _ki_has_key=$(extract_privkey_from_key "$_ki_work/keys/key-$_ki_pick.xml" "$_ki_dir/key.pem")
  _ki_leaf="$_ki_dir/cert-1.pem"
  _ki_root="$_ki_dir/cert-$_ki_ncerts.pem"
  _ki_now=$(date +%s)

  if key_matches_cert "$_ki_dir/key.pem" "$_ki_leaf"; then
    _ki_pkrc=0
  else
    _ki_pkrc=$?
  fi

  # -- 2. labels, root identity, RKP detection ------------------------------
  _ki_leaf_lab=$(cert_label "$_ki_leaf")

  _ki_tee=0
  _ki_i=1
  while [ "$_ki_i" -le "$_ki_ncerts" ]; do
    _ki_lab_i=$(cert_label "$_ki_dir/cert-$_ki_i.pem")
    case "$_ki_lab_i" in
      TEE|StrongBox) _ki_tee=$((_ki_tee + 1)) ;;
    esac
    _ki_i=$((_ki_i + 1))
  done
  unset _ki_i _ki_lab_i

  _ki_root_dn=$(cert_dn_items subject "$_ki_root" | tr 'A-Z' 'a-z' | tr '\n' ' ')
  _ki_root_hw=0
  _ki_root_sw=0
  case "$_ki_root_dn" in
    *google*)
      case "$_ki_root_dn" in
        *"key attestation"*|*"hardware attestation"*|*"attestation root"*) _ki_root_hw=1 ;;
        *"internet authority"*|*"gts"*) _ki_root_sw=1 ;;
      esac
      ;;
  esac

  _ki_rkp=0
  _ki_i=1
  while [ "$_ki_i" -le "$_ki_ncerts" ]; do
    _ki_dn_lc=$( { cert_dn_items subject "$_ki_dir/cert-$_ki_i.pem"; cert_dn_items issuer "$_ki_dir/cert-$_ki_i.pem"; } | tr 'A-Z' 'a-z')
    case "$_ki_dn_lc" in *"droid ca"*) _ki_rkp=1 ;; esac
    _ki_i=$((_ki_i + 1))
  done
  unset _ki_i _ki_dn_lc

  # -- 3. per-certificate validity windows + Google revocation --------------
  _ki_rev_file=""
  if ! _ki_rev_file=$(google_revocation_file); then
    _ki_rev_file=""
  fi
  _ki_rev_known=1
  if [ -z "$_ki_rev_file" ]; then
    _ki_rev_known=0
    log_w "INFO" "Google revocation list unavailable; revocation marked unknown"
  fi

  _ki_i=1
  while [ "$_ki_i" -le "$_ki_ncerts" ]; do
    _ki_p_cert="$_ki_dir/cert-$_ki_i.pem"
    _ki_p_nb_e=$(epoch_of_date "$(cert_notbefore "$_ki_p_cert")")
    _ki_p_na_e=$(epoch_of_date "$(cert_notafter "$_ki_p_cert")")
    _ki_p_win="bad"
    if [ -n "$_ki_p_nb_e" ] && [ -n "$_ki_p_na_e" ] && [ "$_ki_now" -ge "$_ki_p_nb_e" ] && [ "$_ki_now" -le "$_ki_p_na_e" ]; then
      _ki_p_win="ok"
    fi
    printf '%s' "$_ki_p_win" > "$_ki_work/win-$_ki_i"
    _ki_p_rev="unknown"
    if [ -n "$_ki_rev_file" ]; then
      _ki_p_ser=$(cert_serial_hex "$_ki_p_cert")
      if serial_revoked "$_ki_p_ser" "$_ki_rev_file" 2>/dev/null; then
        _ki_p_rev="revoked"
      else
        _ki_p_rev="not_revoked"
      fi
      unset _ki_p_ser
    fi
    printf '%s' "$_ki_p_rev" > "$_ki_work/rev-$_ki_i"
    _ki_i=$((_ki_i + 1))
  done
  unset _ki_i _ki_p_cert _ki_p_win _ki_p_rev _ki_p_nb_e _ki_p_na_e

  _ki_leaf_window_ok=0
  if [ "$(cat "$_ki_work/win-1" 2>/dev/null)" = "ok" ]; then
    _ki_leaf_window_ok=1
  fi
  _ki_all_windows_ok=1
  _ki_revoked_cert=0
  _ki_i=1
  while [ "$_ki_i" -le "$_ki_ncerts" ]; do
    if [ "$(cat "$_ki_work/win-$_ki_i" 2>/dev/null)" != "ok" ]; then
      _ki_all_windows_ok=0
    fi
    if [ "$(cat "$_ki_work/rev-$_ki_i" 2>/dev/null)" = "revoked" ]; then
      _ki_revoked_cert=$_ki_i
    fi
    _ki_i=$((_ki_i + 1))
  done
  unset _ki_i

  # -- 4. provisioning info: CBOR extension first, KeyDescription fallback ---
  _ki_pi_certs_issued=""
  _ki_pi_verified_boot=""
  _ki_pi_vbmeta=""
  _ki_pi_boot_state=""
  _ki_pi_fingerprint=""
  _ki_ext30=$(cert_ext_hex "$_ki_leaf" "$ATTEST_OID_GOOGLE")
  if [ -n "$_ki_ext30" ]; then
    _ki_cbor=$(printf '%s' "$_ki_ext30" | parse_cbor_map)
    _ki_pi_certs_issued=$(printf '%s\n' "$_ki_cbor" | sed -n 's/^1=//p' | head -1)
    _ki_pi_verified_boot=$(printf '%s\n' "$_ki_cbor" | sed -n 's/^5\.1=s://p' | head -1)
    _ki_pi_vbmeta=$(printf '%s\n' "$_ki_cbor" | sed -n 's/^5\.2=s://p' | head -1)
    _ki_pi_boot_state=$(printf '%s\n' "$_ki_cbor" | sed -n 's/^5\.3=s://p' | head -1)
    _ki_pi_fingerprint=$(printf '%s\n' "$_ki_cbor" | sed -n 's/^5\.4=s://p' | head -1)
    if [ -z "$_ki_pi_fingerprint" ]; then
      _ki_pi_fingerprint=$(printf '%s\n' "$_ki_cbor" | sed -n 's/^[^=]*=s://p' | grep -E '^[^:]+/[^:]+:[^:]+/.+' | head -1)
    fi
    unset _ki_cbor
  fi
  if [ -z "$_ki_pi_verified_boot" ] && [ -z "$_ki_pi_boot_state" ] && [ -z "$_ki_pi_vbmeta" ]; then
    _ki_ext17=$(cert_ext_hex "$_ki_leaf" "$ATTEST_OID_KEYDESC")
    if [ -n "$_ki_ext17" ]; then
      _ki_att=$(printf '%s' "$_ki_ext17" | parse_keydescription)
      _ki_rot_state=$(printf '%s\n' "$_ki_att" | sed -n 's/^ROT_STATE=//p' | head -1)
      _ki_rot_locked=$(printf '%s\n' "$_ki_att" | sed -n 's/^ROT_LOCKED=//p' | head -1)
      _ki_rot_hash=$(printf '%s\n' "$_ki_att" | sed -n 's/^ROT_HASH=//p' | head -1)
      _ki_rot_key=$(printf '%s\n' "$_ki_att" | sed -n 's/^ROT_KEY=//p' | head -1)
      case "${_ki_rot_state:-}" in
        0) _ki_pi_verified_boot="APPROVED" ;;
        1) _ki_pi_verified_boot="SELF_SIGNED" ;;
        2) _ki_pi_verified_boot="UNVERIFIED" ;;
        3) _ki_pi_verified_boot="FAILED" ;;
      esac
      if [ "${_ki_rot_locked:-}" = "1" ]; then
        _ki_pi_boot_state="APPROVED"
      elif [ "${_ki_rot_locked:-}" = "0" ]; then
        _ki_pi_boot_state="UNLOCKED"
      fi
      _ki_pi_vbmeta="${_ki_rot_hash:-$_ki_rot_key}"
      _ki_pi_fingerprint=$(printf '%s\n' "$_ki_att" | sed -n 's/^TEETAG[0-9]*=s://p' | grep -E '^[^:]+/[^:]+:[^:]+/.+' | head -1)
      if [ -z "$_ki_pi_fingerprint" ]; then
        _ki_pi_fingerprint=$(printf '%s\n' "$_ki_att" | sed -n 's/^SWTAG[0-9]*=s://p' | grep -E '^[^:]+/[^:]+:[^:]+/.+' | head -1)
      fi
      unset _ki_att _ki_rot_state _ki_rot_locked _ki_rot_hash _ki_rot_key
    fi
    unset _ki_ext17
  fi
  unset _ki_ext30

  # -- 5. render the report -------------------------------------------------
  _ki_title="Custom attestation"
  if [ "$_ki_root_hw" -eq 1 ]; then
    _ki_title="Google Hardware Attestation"
  elif [ "$_ki_root_sw" -eq 1 ]; then
    _ki_title="Google Software Attestation"
  fi

  _ki_na_e=$(epoch_of_date "$(cert_notafter "$_ki_leaf")")
  _ki_na_iso=$(iso_of_epoch "$_ki_na_e")
  if [ -z "$_ki_na_iso" ]; then
    _ki_na_iso=$(cert_notafter "$_ki_leaf")
  fi
  if [ -n "$_ki_na_e" ] && [ "$_ki_now" -le "$_ki_na_e" ]; then
    printf '%s · valid until %s\n' "$_ki_title" "$_ki_na_iso" >> "$_ki_rep"
  else
    printf '%s · EXPIRED since %s\n' "$_ki_title" "$_ki_na_iso" >> "$_ki_rep"
  fi
  printf '%s\n' "─────────────" >> "$_ki_rep"

  if [ "${_ki_has_key:-0}" -eq 0 ]; then
    printf '%s\n' "⚠ Private key ↔️ leaf cert (no private key in keybox)" >> "$_ki_rep"
  elif [ "$_ki_pkrc" -eq 0 ]; then
    printf '%s\n' "✅ Private key ↔️ leaf cert" >> "$_ki_rep"
  else
    printf '%s\n' "❌ Private key ↔️ leaf cert (mismatch)" >> "$_ki_rep"
  fi

  if [ "$_ki_root_hw" -eq 1 ]; then
    printf '%s\n' "✅ Root: Google Hardware" >> "$_ki_rep"
  elif [ "$_ki_root_sw" -eq 1 ]; then
    printf '%s\n' "✅ Root: Google Software" >> "$_ki_rep"
  else
    printf '%s\n' "❌ Root: not a Google attestation root" >> "$_ki_rep"
  fi

  printf '✅ Structure: %d certs · %d TEE\n' "$_ki_ncerts" "$_ki_tee" >> "$_ki_rep"

  _ki_fmt="Custom chain"
  if [ "$_ki_rkp" -eq 1 ]; then
    _ki_fmt="RKP (Remote Key Provisioning)"
  elif [ "$_ki_leaf_lab" = "TEE" ] || [ "$_ki_leaf_lab" = "StrongBox" ]; then
    _ki_fmt="Hardware attestation"
  fi
  _ki_expires=""
  if [ -n "$_ki_na_e" ]; then
    _ki_diff=$((_ki_na_e - _ki_now))
    if [ "$_ki_diff" -ge 0 ]; then
      _ki_expires="expires in $(fmt_countdown "$_ki_diff")"
    else
      _ki_expires="expired $(fmt_countdown "$((-_ki_diff))") ago"
    fi
  fi
  if [ -n "$_ki_expires" ]; then
    printf '🔷 Format: %s · %s\n' "$_ki_fmt" "$_ki_expires" >> "$_ki_rep"
  else
    printf '🔷 Format: %s\n' "$_ki_fmt" >> "$_ki_rep"
  fi

  _ki_pif="$_ki_work/pi.txt"
  : > "$_ki_pif"
  if [ -n "$_ki_pi_certs_issued" ]; then printf 'certs_issued=%s\n' "$_ki_pi_certs_issued" >> "$_ki_pif"; fi
  if [ -n "$_ki_pi_verified_boot" ]; then printf 'verified_boot=%s\n' "$_ki_pi_verified_boot" >> "$_ki_pif"; fi
  if [ -n "$_ki_pi_vbmeta" ]; then printf 'vbmeta_digest=%s\n' "$_ki_pi_vbmeta" >> "$_ki_pif"; fi
  if [ -n "$_ki_pi_boot_state" ]; then printf 'boot_state=%s\n' "$_ki_pi_boot_state" >> "$_ki_pif"; fi
  if [ -n "$_ki_pi_fingerprint" ]; then printf 'fingerprint=%s\n' "$_ki_pi_fingerprint" >> "$_ki_pif"; fi
  if [ -s "$_ki_pif" ]; then
    printf '%s\n' "├ Provisioning info:" >> "$_ki_rep"
    awk '{ if (prev != "") printf "│    ├─ %s\n", prev; prev = $0 }
          END { if (prev != "") printf "│    └─ %s\n", prev }' "$_ki_pif" >> "$_ki_rep"
  fi

  if [ "$_ki_revoked_cert" -ne 0 ]; then
    printf '❌ Revocation: revoked (cert #%d)\n' "$_ki_revoked_cert" >> "$_ki_rep"
  elif [ "$_ki_rev_known" -eq 0 ]; then
    printf '%s\n' "⚠ Revocation: revocation list unavailable" >> "$_ki_rep"
  else
    printf '%s\n' "✅ Revocation: not revoked" >> "$_ki_rep"
  fi

  _ki_chain_ok=1
  _ki_i=1
  while [ "$_ki_i" -le "$_ki_ncerts" ]; do
    _ki_c="$_ki_dir/cert-$_ki_i.pem"
    _ki_c_serial=$(cert_serial_hex "$_ki_c")
    _ki_c_sig=$(cert_sig_label "$_ki_c")

    printf '\n🔐 Cert #%d · %s\n' "$_ki_i" "$( [ "$_ki_i" -eq 1 ] && printf '%s' "$_ki_leaf_lab" || { if [ "$_ki_i" -eq "$_ki_ncerts" ]; then printf 'root'; else cert_label "$_ki_c" | sed 's/-/—/'; fi; } )" >> "$_ki_rep"
    printf '├ Serial: %s\n' "${_ki_c_serial:--}" >> "$_ki_rep"

    cert_dn_items subject "$_ki_c" > "$_ki_work/dn.txt"
    if [ -s "$_ki_work/dn.txt" ]; then
      printf '%s\n' "├ Subject:" >> "$_ki_rep"
      awk '{ if (prev != "") printf "│    ├─ %s\n", prev; prev = $0 }
            END { if (prev != "") printf "│    └─ %s\n", prev }' "$_ki_work/dn.txt" >> "$_ki_rep"
    else
      printf '%s\n' "├ Subject: (empty)" >> "$_ki_rep"
    fi

    cert_dn_items issuer "$_ki_c" > "$_ki_work/dn.txt"
    if [ -s "$_ki_work/dn.txt" ]; then
      printf '%s\n' "├ Issuer:" >> "$_ki_rep"
      awk '{ if (prev != "") printf "│    ├─ %s\n", prev; prev = $0 }
            END { if (prev != "") printf "│    └─ %s\n", prev }' "$_ki_work/dn.txt" >> "$_ki_rep"
    else
      printf '%s\n' "├ Issuer: (empty)" >> "$_ki_rep"
    fi

    _ki_f_serial="❌"
    if [ -n "$_ki_c_serial" ]; then _ki_f_serial="✅"; fi
    _ki_f_subj="❌"
    if [ -s "$_ki_work/dn.txt" ]; then _ki_f_subj="✅"; fi
    _ki_f_iss="❌"
    if [ -n "$(cert_dn_items issuer "$_ki_c")" ]; then _ki_f_iss="✅"; fi
    printf '├ Format: serial %s · subject %s · issuer %s\n' "$_ki_f_serial" "$_ki_f_subj" "$_ki_f_iss" >> "$_ki_rep"

    if [ "$_ki_i" -lt "$_ki_ncerts" ]; then
      _ki_issuer_f="$_ki_dir/cert-$((_ki_i + 1)).pem"
    else
      _ki_issuer_f="$_ki_c"
    fi
    _ki_f_chain="❌"
    if openssl verify $KI_VERIFY_OPTS -CAfile "$_ki_issuer_f" "$_ki_c" >/dev/null 2>&1; then
      _ki_f_chain="✅"
    else
      _ki_chain_ok=0
    fi
    printf '├ Signature: %s · %s chain+signature\n' "$_ki_c_sig" "$_ki_f_chain" >> "$_ki_rep"

    _ki_c_nb_e=$(epoch_of_date "$(cert_notbefore "$_ki_c")")
    _ki_c_na_e=$(epoch_of_date "$(cert_notafter "$_ki_c")")
    _ki_f_win="❌"
    if [ -n "$_ki_c_nb_e" ] && [ -n "$_ki_c_na_e" ] && [ "$_ki_now" -ge "$_ki_c_nb_e" ] && [ "$_ki_now" -le "$_ki_c_na_e" ]; then
      _ki_f_win="✅"
    fi
    _ki_nb_iso=$(iso_of_epoch "$_ki_c_nb_e")
    if [ -z "$_ki_nb_iso" ]; then _ki_nb_iso=$(cert_notbefore "$_ki_c"); fi
    _ki_na_iso2=$(iso_of_epoch "$_ki_c_na_e")
    if [ -z "$_ki_na_iso2" ]; then _ki_na_iso2=$(cert_notafter "$_ki_c"); fi
    printf '├ Validity: %s → %s %s\n' "$_ki_nb_iso" "$_ki_na_iso2" "$_ki_f_win" >> "$_ki_rep"

    _ki_rev_state=$(cat "$_ki_work/rev-$_ki_i" 2>/dev/null || echo unknown)
    case "$_ki_rev_state" in
      revoked)     printf '%s\n' "└ Revocation: ❌ revoked" >> "$_ki_rep" ;;
      not_revoked) printf '%s\n' "└ Revocation: ✅ not revoked" >> "$_ki_rep" ;;
      *)           printf '%s\n' "└ Revocation: ⚠ unknown (list unavailable)" >> "$_ki_rep" ;;
    esac

    _ki_i=$((_ki_i + 1))
  done
  unset _ki_i _ki_c _ki_c_serial _ki_c_sig _ki_issuer_f _ki_f_serial _ki_f_subj _ki_f_iss _ki_f_chain _ki_f_win _ki_rev_state _ki_nb_iso _ki_na_iso2 _ki_c_nb_e _ki_c_na_e

  # -- 6. verdict: basic / device / strong ----------------------------------
  _ki_basic=0
  if [ "${_ki_has_key:-0}" -eq 0 ]; then
    _ki_basic=1
  elif [ "$_ki_pkrc" -eq 0 ]; then
    _ki_basic=1
  fi

  _ki_root_google=0
  if [ "$_ki_root_hw" -eq 1 ] || [ "$_ki_root_sw" -eq 1 ]; then
    _ki_root_google=1
  fi

  _ki_device=0
  if [ "$_ki_basic" -eq 1 ] && [ "$_ki_chain_ok" -eq 1 ] && [ "$_ki_root_google" -eq 1 ] \
     && [ "$_ki_leaf_window_ok" -eq 1 ] && [ "$_ki_revoked_cert" -eq 0 ]; then
    if [ "$_ki_leaf_lab" = "TEE" ] || [ "$_ki_leaf_lab" = "StrongBox" ]; then
      _ki_device=1
    fi
  fi

  _ki_strong=0
  if [ "$_ki_device" -eq 1 ] && [ "$_ki_root_hw" -eq 1 ] && [ "$_ki_all_windows_ok" -eq 1 ] \
     && [ "$_ki_rev_known" -eq 1 ] && [ "${_ki_has_key:-0}" -eq 1 ] && [ "$_ki_pkrc" -eq 0 ]; then
    _ki_strong=1
  fi

  if [ "$_ki_strong" -eq 1 ]; then
    _ki_verdict="STRONG"
  elif [ "$_ki_device" -eq 1 ]; then
    _ki_verdict="DEVICE"
  else
    _ki_verdict="BASIC"
  fi

  _ki_m_basic="❌"
  if [ "$_ki_basic" -eq 1 ]; then _ki_m_basic="✅"; fi
  _ki_m_device="❌"
  if [ "$_ki_device" -eq 1 ]; then _ki_m_device="✅"; fi
  _ki_m_strong="❌"
  if [ "$_ki_strong" -eq 1 ]; then _ki_m_strong="✅"; fi

  printf '%s\n' "─────────────" >> "$_ki_rep"
  printf '🔐 Integrity verdict: %s\n' "$_ki_verdict" >> "$_ki_rep"
  printf '├ Basic: %s\n' "$_ki_m_basic" >> "$_ki_rep"
  printf '├ Device: %s\n' "$_ki_m_device" >> "$_ki_rep"
  printf '└ Strong: %s\n' "$_ki_m_strong" >> "$_ki_rep"
  printf '\nVERDICT: %s\n' "$_ki_verdict" >> "$_ki_rep"

  # Telegram status line: cumulative meter from the verdict; a revoked
  # serial overrides everything with its own state.
  _ki_tg_state="$_ki_verdict"
  if [ "${_ki_revoked_cert:-0}" -ne 0 ]; then
    _ki_tg_state="REVOKED"
  fi
  tg_write_status "$_ki_tg" "$_ki_tg_state"
  unset _ki_tg_state

  cat "$_ki_rep"
  unset _ki_tg
  return 0
}

# ---------------------------------------------------------------------------
# Pipeline replay, from features/keybox.sh
# ---------------------------------------------------------------------------

TEMP_FILE="$WORKDIR/keybox.tmp.$$"
DECODE_FILE="$WORKDIR/keybox_decode.$$"

# harness: stands in for detect_keystore_manager + ksm_install_keybox.
# On device this moves the decoded XML into Tricky Store / TEESimulator /
# OhMyKeymint; here it copies to the requested output file.
ksm_install_keybox() {
  # fix: create the parent directory so a non-existent output dir fails the
  # same way here as anywhere else, instead of dying inside cp.
  mkdir -p "$(dirname "$OUTPUT_FILE")" 2>/dev/null || true
  cp "$1" "$OUTPUT_FILE"
}

# Shared tail: structural validation, serial revocation check, install.
# Operates on $DECODE_FILE (an already-decoded keybox.xml). Used by
# _try_keybox_url (Specter catalog) and fetch_simple (yuri/integrity/url).
_finish_keybox() {
  _has_ecdsa=$(sed -n '/<Key algorithm="ecdsa">/,/<\/Key>/p' "$DECODE_FILE" 2>/dev/null)
  _has_rsa=$(sed -n '/<Key algorithm="rsa">/,/<\/Key>/p' "$DECODE_FILE" 2>/dev/null)
  _has_id=$(( $(grep -c '<serial>' "$DECODE_FILE" 2>/dev/null || true) + $(grep -c 'DeviceID' "$DECODE_FILE" 2>/dev/null || true) ))

  if [ -z "$_has_ecdsa" ] && [ -z "$_has_rsa" ]; then
    log_w "KEYBOX" "No ECDSA key, no RSA key in decoded file"
    log_d "KEYBOX" "First 100 bytes: $(head -c 100 "$DECODE_FILE" 2>/dev/null | tr '\n' ' ' | tr '\0' '.')"
    log_e "KEYBOX" "No valid attestation keys found in downloaded keybox"
    return 1
  fi
  [ "$_has_id" -eq 0 ] && { log_e "KEYBOX" "No identifier field found (serial/DeviceID)"; return 1; }
  [ -n "$_has_ecdsa" ] || log_w "KEYBOX" "Missing ECDSA key block"
  [ -n "$_has_rsa" ] || log_w "KEYBOX" "Missing RSA key block"

  # harness: skip the serial branch entirely on shells without slicing/16#
  # arithmetic (dash) -- the repo's in-function guards are not dash-proof.
  _serial=""
  if [ -n "${BASH_VERSION:-}" ]; then
    _serial=$(decode_keybox_serial "$DECODE_FILE" 2>/dev/null || echo "")
  fi
  if [ -n "$_serial" ]; then
    log_i "KEYBOX" "Checking Google revocation for serial $_serial"
    if check_google_revocation "$_serial"; then
      log_w "KEYBOX" "Keybox is revoked by Google"
      return 1
    fi
    log_i "KEYBOX" "Keybox is not revoked"
  else
    log_w "KEYBOX" "Could not extract serial for revocation check"
  fi

  ksm_install_keybox "$DECODE_FILE" || die "Failed to move decoded keybox"
  log_i "KEYBOX" "Keybox installed successfully"
  log_i "KEYBOX" "Keybox install complete"
  return 0
}

# Single-file providers: download one blob and decode it to $DECODE_FILE by the
# provider's own scheme, then run the shared tail.
#   yuri      : one base64 of keybox.xml          (Yurii0307/yurikey)
#   integrity : base64 x10 -> hex -> ROT13        (MeowDump/Integrity-Box "Megatron")
#   url       : a keybox.xml, or one base64 of it, at any http(s) URL
fetch_simple() {
  _fs_url=$1 _fs_kind=$2
  rm -f "$TEMP_FILE" "$DECODE_FILE"
  log_i "KEYBOX" "Downloading keybox ($_fs_kind)..."
  download "$_fs_url" "$TEMP_FILE" || { log_e "KEYBOX" "Download failed"; return 1; }
  log_d "KEYBOX" "Downloaded $(wc -c < "$TEMP_FILE" 2>/dev/null || echo "?") bytes"
  case "$_fs_kind" in
    yuri)
      base64 -d < "$TEMP_FILE" > "$DECODE_FILE" 2>/dev/null \
        || { log_e "KEYBOX" "Base64 decode failed"; return 1; } ;;
    integrity)
      _fs_cur=$TEMP_FILE
      _fs_i=0
      while [ "$_fs_i" -lt 10 ]; do
        _fs_i=$((_fs_i + 1))
        if ! base64 -d < "$_fs_cur" > "$WORKDIR/_int.$_fs_i" 2>/dev/null; then
          log_e "KEYBOX" "Base64 decode failed at layer $_fs_i"; return 1
        fi
        _fs_cur="$WORKDIR/_int.$_fs_i"
      done
      xxd -r -p < "$_fs_cur" > "$WORKDIR/_int.hex" 2>/dev/null \
        || { log_e "KEYBOX" "Hex decode failed"; return 1; }
      tr 'A-Za-z' 'N-ZA-Mn-za-m' < "$WORKDIR/_int.hex" > "$DECODE_FILE" \
        || { log_e "KEYBOX" "ROT13 decode failed"; return 1; } ;;
    url)
      if grep -q '<Keybox' "$TEMP_FILE" 2>/dev/null; then
        cp "$TEMP_FILE" "$DECODE_FILE"
      elif base64 -d < "$TEMP_FILE" > "$DECODE_FILE" 2>/dev/null && grep -q '<Keybox' "$DECODE_FILE" 2>/dev/null; then
        :
      else
        log_e "KEYBOX" "URL is neither a keybox nor its base64"; return 1
      fi ;;
  esac
  [ -s "$DECODE_FILE" ] || { log_e "KEYBOX" "Decoded keybox is empty"; return 1; }
  _finish_keybox
}

# -- _try_keybox_url from features/keybox.sh --
# harness: "exit 0" on success became "return 0" so the caller controls flow;
# everything else (download, decode, structural validation, serial extraction,
# Google revocation check, install) is the repo logic.
_try_keybox_url() {
  _kt_url=$1
  rm -f "$TEMP_FILE" "$DECODE_FILE"
  log_i "KEYBOX" "Downloading keybox..."
  download "$_kt_url" "$TEMP_FILE" || { log_e "KEYBOX" "Download failed"; return 1; }
  log_d "KEYBOX" "Downloaded $(wc -c < "$TEMP_FILE" 2>/dev/null || echo "?") bytes"
  if ! decode_keybox_blob "$TEMP_FILE" "$DECODE_FILE" 2>/dev/null; then
    log_e "KEYBOX" "Base64 decode failed"
    return 1
  fi
  _dk_size=$(wc -c < "$DECODE_FILE" 2>/dev/null || echo "0")
  log_d "KEYBOX" "Decoded $_dk_size bytes"
  [ "$_dk_size" -gt 0 ] || { log_e "KEYBOX" "Decoded keybox is empty"; return 1; }
  unset _dk_size

  _finish_keybox
}

# -- main loop from features/keybox.sh --
# harness: die/exit became return codes; provider comes from the CLI arg
# instead of CONFIG_DIR/val/keybox_provider.val.
run_pipeline() {
  _provider="$1"
  log_i "KEYBOX" "Starting keybox fetch/install (provider=$_provider)"

  # single-file providers and a direct URL skip the Specter catalog entirely
  case "$_provider" in
    yuri)            fetch_simple "$YURI_URL" yuri; return $? ;;
    integrity)       fetch_simple "$INTEGRITY_URL" integrity; return $? ;;
    http://*|https://*) fetch_simple "$_provider" url; return $? ;;
    spectre|specter)
      # the whole Specter catalog: pick a random unrevoked keybox (same as "auto")
      _provider=auto ;;
    tricky|trickyaddon|tricky-addon|kowx)
      # Specter mirrors the kowx712 (Tricky Addon) repository as the "TAKR" source,
      # so its keyboxes are fetchable here through the catalog without the site's
      # browser CAPTCHA. Fall through to the catalog pipeline filtered to TAKR.
      _provider=TAKR ;;
  esac

  check_network || { log_e "KEYBOX" "No internet connection (catalog unreachable)"; return 1; }

  log_i "KEYBOX" "Fetching available keyboxes..."
  _history=$(keybox_catalog || true)

  if [ -z "$_history" ]; then
    log_w "KEYBOX" "Catalog fetch failed, trying fallback keyboxes..."
    for _pair in $FALLBACK_KEYBOXES; do
      log_i "KEYBOX" "Fallback selected: $_pair"
      _try_keybox_url "${KEYBOX_URL}/${_pair}" && return 0
    done
    log_e "KEYBOX" "No working keybox available (all revoked?)"
    return 1
  fi

  if [ "$_provider" = "auto" ]; then
    _objs=$(printf '%s' "$_history" | grep -o '"entries":\[[^]]*\]' | grep -o '{[^}]*}' | grep -v '"revoked":true' || true)
  else
    _objs=$(printf '%s' "$_history" | grep -o '"entries":\[[^]]*\]' | grep -o '{[^}]*"source":"'"$_provider"'"[^}]*}' | grep -v '"revoked":true' || true)
  fi
  _pool=$(printf '%s\n' "$_objs" | keybox_prefer_active "$_history")
  if [ "$_provider" != "auto" ]; then
    _sorted=""
    while IFS= read -r _line || [ -n "$_line" ]; do
      [ -n "$_line" ] || continue
      _ver=$(printf '%s' "$_line" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
      _sorted="${_sorted}${_ver} ${_line}
"
    done <<EOF
$_pool
EOF
    _pool=$(printf '%s\n' "$_sorted" | sort -rn | sed 's/^[^ ]* //')
  fi
  _count=$(printf '%s\n' "$_pool" | grep -c '"source":' || true)
  if [ "${_count:-0}" -eq 0 ]; then
    log_e "KEYBOX" "No working keybox available (all revoked?)"
    return 1
  fi

  _start=0
  if [ "$_provider" = "auto" ] && [ "$_count" -gt 1 ]; then
    _rand_hex=$(hexdump -n 4 -e '4/4 "%08X"' /dev/urandom 2>/dev/null) && _start=$(( 0x${_rand_hex} % _count )) || _start=$(( $$ % _count ))
  fi

  _n=0
  while [ "$_n" -lt "$_count" ]; do
    _pos=$(( (_start + _n) % _count + 1 ))
    _entry=$(printf '%s\n' "$_pool" | sed -n "${_pos}p")
    _src=$(printf '%s' "$_entry" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')
    _ver=$(printf '%s' "$_entry" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    _text=$(printf '%s' "$_entry" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
    [ -n "$_text" ] || _text=$_ver
    if [ "$_n" -eq 0 ] && [ "$_provider" != "auto" ]; then
      log_i "KEYBOX" "Selected provider: $_src $_text"
    elif [ "$_n" -eq 0 ]; then
      log_i "KEYBOX" "Randomly selected: $_src $_text (entry $_pos of $_count)"
    else
      log_i "KEYBOX" "Trying next: $_src $_text (entry $_pos of $_count)"
    fi
    # repo: _try_keybox_url exits the script on success
    _try_keybox_url "${KEYBOX_URL}/${_src}/${_ver}" && return 0
    _n=$((_n + 1))
  done

  log_e "KEYBOX" "No working keybox available (all revoked?)"
  return 1
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# -r|--read mode: no fetch, no analysis. Copy the locally saved keybox.xml
# and tg_message.txt from $HOME/out into the destination folder (2nd arg,
# else $OUT, else ./).
case "$PROVIDER" in
  -r|--read|read)
    _rd_dest="${2:-${OUT:-}}"
    if [ -z "$_rd_dest" ]; then
      _rd_dest="."
    fi
    mkdir -p "$_rd_dest" 2>/dev/null || true
    echo "== Specter keybox read (local copies) =="
    echo "   store: $LOCAL_OUT_DIR"
    echo "   dest:  $_rd_dest"
    echo
    _rd_ok=1
    for _rd_f in keybox.xml tg_message.txt; do
      if [ -f "$LOCAL_OUT_DIR/$_rd_f" ]; then
        if cp "$LOCAL_OUT_DIR/$_rd_f" "$_rd_dest/$_rd_f" 2>/dev/null; then
          echo "copied: $LOCAL_OUT_DIR/$_rd_f -> $_rd_dest/$_rd_f"
        else
          log_e "READ" "copy failed: $_rd_f"
          _rd_ok=0
        fi
      else
        log_e "READ" "no local copy of $_rd_f in $LOCAL_OUT_DIR (run a fetch/--info first)"
        _rd_ok=0
      fi
    done
    if [ "$_rd_ok" -eq 1 ]; then
      echo
      echo "RESULT: local copies restored to $_rd_dest"
      unset _rd_dest _rd_f
      exit 0
    fi
    echo
    echo "RESULT: read incomplete (see errors above)"
    unset _rd_dest _rd_f
    exit 1
    ;;
esac

# list mode: show the whole catalog (every source and version, valid/revoked)
# without fetching or installing anything.
case "$PROVIDER" in
  list|--list|-l)
    echo "== Specter keybox catalog =="
    echo "   catalog: $CATALOG_URL"
    echo
    check_network || { log_e "KEYBOX" "catalog unreachable"; exit 1; }
    _lc=$(keybox_catalog || true)
    [ -n "$_lc" ] || { log_e "KEYBOX" "empty catalog"; exit 1; }
    # one entry per line, from the "entries" array only (the catalog also has
    # working/latest arrays that repeat the same keyboxes)
    _objs=$(printf '%s' "$_lc" | grep -o '"entries":\[[^]]*\]' | grep -o '{[^{}]*}')
    printf '%s\n' "$_objs" | while IFS= read -r _o; do
      [ -n "$_o" ] || continue
      _s=$(printf '%s' "$_o" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')
      _v=$(printf '%s' "$_o" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
      if printf '%s' "$_o" | grep -q '"revoked":true'; then _r="revoked"; else _r="valid"; fi
      _ser=$(printf '%s' "$_o" | sed -n 's/.*"serial":"\([^"]*\)".*/\1/p')
      printf '  %-12s v%-6s %-7s %s\n' "$_s" "$_v" "$_r" "$_ser"
    done | sort
    echo
    _lt=$(printf '%s\n' "$_objs" | grep -c '"source"')
    _lv=$(printf '%s\n' "$_objs" | grep -vc '"revoked":true')
    echo "RESULT: $_lt keyboxes, $_lv not revoked. Fetch one with:"
    echo "  $0 <source>   (e.g. TAKR = Tricky Addon)   or   yuri | integrity | auto | <URL>"
    exit 0 ;;
esac

# --info mode: analyze an existing keybox.xml without fetching anything.
case "$PROVIDER" in
  --info|-i|info)
    if [ -n "${2:-}" ]; then
      OUTPUT_FILE="$2"
    fi
    case "$OUTPUT_FILE" in
      */) OUTPUT_FILE="${OUTPUT_FILE}keybox.xml" ;;
    esac
    if [ -d "$OUTPUT_FILE" ]; then
      OUTPUT_FILE="${OUTPUT_FILE%/}/keybox.xml"
    fi
    # tg_message.txt goes into the input folder passed on the cmd line (the
    # keybox's folder), or ./tg_message.txt when nothing was passed.
    TG_PATH=$(tg_message_path "$OUTPUT_FILE")
    echo "== Specter keybox attestation info =="
    echo "   keybox: $OUTPUT_FILE"
    echo "   tg:     $TG_PATH"
    echo "   local:  $LOCAL_OUT_DIR"
    echo
    if keybox_info "$OUTPUT_FILE" "$TG_PATH"; then
      # mirror the analyzed keybox + status into the local copy store
      local_backup "$OUTPUT_FILE" "$TG_PATH"
      exit 0
    fi
    # analysis failed (missing file, no certs) -> refresh the status copy,
    # keep the last good keybox in the store
    tg_write_status "$TG_PATH" ""
    local_backup "" "$TG_PATH"
    echo "RESULT: could not analyze $OUTPUT_FILE" >&2
    exit 1
    ;;
esac

echo "== Specter keybox direct fetch =="
echo "   catalog:            $CATALOG_URL"
echo "   keybox base:        $KEYBOX_URL"
echo "   revocation:         $GOOGLE_REVOCATION_URL"
echo "   provider:           $PROVIDER"
echo "   output:             $OUTPUT_FILE"
TG_PATH=$(tg_message_path "$OUTPUT_FILE")
echo "   tg message:         $TG_PATH"
echo "   local copy:         $LOCAL_OUT_DIR"
echo

if run_pipeline "$PROVIDER"; then
  echo
  # fix: only report success if the output is an actual regular file
  if [ -f "$OUTPUT_FILE" ]; then
    echo "RESULT: keybox saved to $OUTPUT_FILE ($(wc -c < "$OUTPUT_FILE") bytes)"
    grep -o 'DeviceID="[^"]*"' "$OUTPUT_FILE" 2>/dev/null | head -1 || true
    echo
    log_i "INFO" "Running backend attestation analysis"
    _ki_out=$(keybox_info "$OUTPUT_FILE" "$TG_PATH") || _ki_out=""
    if [ -n "$_ki_out" ]; then
      printf '%s\n' "$_ki_out"
      _ki_verdict_line=$(printf '%s\n' "$_ki_out" | sed -n 's/^VERDICT: //p' | head -1)
      if [ -n "$_ki_verdict_line" ]; then
        log_i "KEYBOX" "Attestation verdict: $_ki_verdict_line"
      fi
      unset _ki_verdict_line
    else
      # analysis produced nothing (openssl missing / unreadable keybox) -> red
      tg_write_status "$TG_PATH" ""
      log_w "INFO" "attestation analysis produced no output (openssl missing or unreadable keybox)"
    fi
    unset _ki_out
    # mirror keybox + status into the local copy store for -r/--read
    local_backup "$OUTPUT_FILE" "$TG_PATH"
  else
    tg_write_status "$TG_PATH" ""
    local_backup "" "$TG_PATH"
    echo "RESULT: install reported success but $OUTPUT_FILE is missing" >&2
    exit 1
  fi
else
  tg_write_status "$TG_PATH" ""
  local_backup "" "$TG_PATH"
  echo
  echo "RESULT: no installable keybox found"
  exit 1
fi
