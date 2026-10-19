#!/usr/bin/env bash
# fm-jcode-usage.sh - jcode provider usage as supplementary quota evidence.
#
# Active only when config/jcode-usage-evidence exists; otherwise prints
# `jcode-usage: off` and exits 0. Runs `jcode --quiet --no-update usage --json`
# (about 1-2 s, a short-lived process), caches the raw JSON at
# state/jcode/usage.json for 300 seconds, and prints one row per provider limit:
#
#   provider,window,usagePercent,resetsAt,error
#
# It is data only. quota-axi stays the ranker (AGENTS.md section 4): this never
# computes a spendPriority and never blocks a candidate by itself; the
# quota-array-dispatch skill says when to read it. Exit 1 when the call fails,
# times out, or its output does not parse.
#
# Environment: FM_JCODE_USAGE_TTL_SECS (300), FM_JCODE_USAGE_TIMEOUT_SECS (10).
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_HOME=${FM_HOME:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

case "${1:-}" in
  -h | --help)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ ! -e "$CONFIG/jcode-usage-evidence" ]; then
  echo "jcode-usage: off"
  exit 0
fi

command -v node >/dev/null 2>&1 || { echo "error: node is required to read jcode usage" >&2; exit 1; }
CACHE="$STATE/jcode/usage.json"
TTL=${FM_JCODE_USAGE_TTL_SECS:-300}
fresh() {
  local mtime now
  [ -s "$CACHE" ] || return 1
  mtime=$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $((now - mtime)) -lt "$TTL" ]
}

if ! fresh; then
  JCODE_BIN=$(command -v jcode 2>/dev/null) || { echo "error: jcode executable not found on PATH" >&2; exit 1; }
  mkdir -p "$STATE/jcode" || exit 1
  tmp="$CACHE.tmp.$$"
  if ! timeout "${FM_JCODE_USAGE_TIMEOUT_SECS:-10}" "$JCODE_BIN" --quiet --no-update usage --json >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: jcode usage --json failed or timed out" >&2
    exit 1
  fi
  mv -f "$tmp" "$CACHE"
fi

node -e '
  const fs = require("fs");
  let v;
  try { v = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(2); }
  if (!v || !Array.isArray(v.providers)) process.exit(2);
  const cell = (x) => String(x ?? "").replace(/[,\n]/g, " ");
  console.log("provider,window,usagePercent,resetsAt,error");
  for (const p of v.providers) {
    const err = cell(p.error);
    const limits = Array.isArray(p.limits) ? p.limits : [];
    if (!limits.length) console.log([cell(p.provider_name), "", "", "", err].join(","));
    for (const l of limits) console.log([cell(p.provider_name), cell(l.name), cell(l.usage_percent), cell(l.resets_at), err].join(","));
  }
' "$CACHE" || {
  rm -f "$CACHE"
  echo "error: jcode usage output did not parse" >&2
  exit 1
}
