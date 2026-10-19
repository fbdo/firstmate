#!/usr/bin/env bash
# fm-jcode-setup.sh - register this home's jcode hook dispatcher.
#
# jcode reads lifecycle hooks only from the machine-wide [hooks] table of
# ~/.jcode/config.toml (or JCODE_HOOK_* in the daemon's environment), so a
# firstmate home cannot ship them as project files the way it ships
# .claude/settings.json. This helper owns that registration.
#
# Usage:
#   fm-jcode-setup.sh print       print the [hooks] lines this home needs (default)
#   fm-jcode-setup.sh env         print `export JCODE_HOOK_*=...` lines for a
#                                 daemon started from a shell (no config edit)
#   fm-jcode-setup.sh status      report whether config.toml registers this home
#   fm-jcode-setup.sh install     add this home's dispatcher to config.toml
#
# install edits the user's jcode config only on that explicit verb, after a
# timestamped backup, and only the three keys it owns inside the [hooks] table:
# `pre_tool` and `turn_end` (the primary's seatbelts and backstop) and
# `turn_start` (the busy source of this home's jcode crewmates and scouts,
# which also uses `turn_end`). An existing single command becomes a two-element
# array with this home's dispatcher appended, so another tool's hook keeps
# running; an existing entry for this exact dispatcher path is left alone.
# It refuses (exit 1) when python3 with tomllib is unavailable or when the file
# does not parse, rather than writing a config jcode might reject. jcode
# re-reads hooks on config reload, so no restart is needed.
#
# Several homes on one machine each register their own dispatcher path; each
# dispatcher acts only for sessions whose working directory is its own home.
#
# A secondmate home (marker .fm-secondmate-home) registers nothing of its own:
# the parent home's dispatcher delegates to the mate's dispatcher. `status` there
# reports registered when the parent's dispatcher is registered and the parent's
# state/<id>.meta records this home as a kind=secondmate harness=jcode task;
# `install` refuses with "register the parent home's hooks instead".
#
# `status` also prints one read-only line when config.toml enables [ambient]
# (Firstmate does not use ambient mode); it never changes the exit status.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
HOOK="$SCRIPT_DIR/fm-jcode-hook.sh"
CONFIG_FILE=${FM_JCODE_CONFIG:-${JCODE_HOME:-$HOME/.jcode}/config.toml}
VERB=${1:-print}

# Mate-home mode: resolve the parent's dispatcher and verify the parent binds us.
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
if [ -f "$ROOT/.fm-secondmate-home" ] && [ ! -L "$ROOT/.fm-secondmate-home" ]; then
  case "$VERB" in
    status|install)
      if [ "$VERB" = install ]; then
        echo "error: this is a secondmate home; register the parent home's hooks instead" >&2
        exit 1
      fi
      MATE_ID=''
      IFS= read -r MATE_ID <"$ROOT/.fm-secondmate-home" || true
      MATE_ID=${MATE_ID//[[:space:]]/}
      PARENT_HOME=''
      route=''
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          route=*) route=${line#route=} ;;
          parent_home=*) PARENT_HOME=${line#parent_home=} ;;
        esac
      done <"$ROOT/.fm-secondmate-parent" 2>/dev/null
      if [ "$route" != local ] || [ ! -f "$PARENT_HOME/bin/fm-jcode-hook.sh" ]; then
        echo "jcode hooks: NOT registered (no usable local parent home recorded in .fm-secondmate-parent)"
        exit 1
      fi
      PMETA="$PARENT_HOME/state/$MATE_ID.meta"
      pm() { awk -F= -v k="$1" '$1 == k { v = substr($0, index($0, "=") + 1) } END { print v }' "$PMETA" 2>/dev/null; }
      pm_home=$(pm home)
      if [ "$(pm kind)" != secondmate ] || [ "$(pm harness)" != jcode ] || [ -z "$pm_home" ] \
        || [ "$(CDPATH='' cd -- "$pm_home" 2>/dev/null && pwd -P)" != "$ROOT" ]; then
        echo "jcode hooks: NOT registered (the parent home does not record this home as a jcode secondmate)"
        exit 1
      fi
      HOOK="$PARENT_HOME/bin/fm-jcode-hook.sh"
      ;;
  esac
fi

toml_string() {  # <value>
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

case "$VERB" in
  print)
    printf '# Add to %s (bin/fm-jcode-setup.sh install does this for you):\n' "$CONFIG_FILE"
    printf '[hooks]\n'
    printf 'turn_start = %s\n' "$(toml_string "$HOOK")"
    printf 'pre_tool = %s\n' "$(toml_string "$HOOK")"
    printf 'turn_end = %s\n' "$(toml_string "$HOOK")"
    ;;
  env)
    printf 'export JCODE_HOOK_TURN_START=%q\n' "$HOOK"
    printf 'export JCODE_HOOK_PRE_TOOL=%q\n' "$HOOK"
    printf 'export JCODE_HOOK_TURN_END=%q\n' "$HOOK"
    ;;
  status|install)
    command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required to read $CONFIG_FILE" >&2; exit 1; }
    python3 - "$VERB" "$CONFIG_FILE" "$HOOK" <<'PY'
import os, shutil, sys, time
verb, path, hook = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import tomllib
except ModuleNotFoundError:
    print("error: python3 tomllib (Python 3.11+) is required", file=sys.stderr); sys.exit(1)
text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
try:
    data = tomllib.loads(text)
except tomllib.TOMLDecodeError as e:
    print(f"error: {path} does not parse ({e}); refusing to edit it", file=sys.stderr); sys.exit(1)
hooks = data.get("hooks", {}) if isinstance(data.get("hooks", {}), dict) else {}
def registered(key):
    v = hooks.get(key)
    return v == hook or (isinstance(v, list) and hook in v)
keys = ("turn_start", "pre_tool", "turn_end")
if verb == "status":
    missing = [k for k in keys if not registered(k)]
    if missing:
        print(f"jcode hooks: NOT registered for this home ({', '.join(missing)} missing in {path})")
        amb = data.get("ambient", {})
        if isinstance(amb, dict) and amb.get("enabled") is True:
            print("jcode ambient: enabled (Firstmate does not use it; workers on this daemon may receive ambient turns)")
        sys.exit(1)
    print(f"jcode hooks: registered for this home in {path}")
    amb = data.get("ambient", {})
    if isinstance(amb, dict) and amb.get("enabled") is True:
        print("jcode ambient: enabled (Firstmate does not use it; workers on this daemon may receive ambient turns)")
    sys.exit(0)
def q(s): return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
def render(key):
    v = hooks.get(key)
    if v is None or v == "" or v == []:
        return f"{key} = {q(hook)}"
    items = v if isinstance(v, list) else [v]
    if hook not in items:
        items = items + [hook]
    return f"{key} = [" + ", ".join(q(i) for i in items) + "]"
todo = [k for k in keys if not registered(k)]
if not todo:
    print(f"jcode hooks: already registered for this home in {path}"); sys.exit(0)
lines = text.splitlines()
start = next((i for i, l in enumerate(lines) if l.strip() == "[hooks]"), None)
if start is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines.append("[hooks]")
    start = len(lines) - 1
end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
while end > start + 1 and not lines[end - 1].strip():
    end -= 1
for key in todo:
    new = render(key)
    idx = next((i for i in range(start + 1, end) if lines[i].split("=", 1)[0].strip() == key), None)
    if idx is None:
        lines.insert(end, new); end += 1
    else:
        lines[idx] = new
out = "\n".join(lines) + "\n"
try:
    tomllib.loads(out)
except tomllib.TOMLDecodeError as e:
    print(f"error: the edited config would not parse ({e}); nothing written", file=sys.stderr); sys.exit(1)
if os.path.exists(path):
    backup = f"{path}.pre-firstmate-{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"backup: {backup}")
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".fm-tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
os.replace(tmp, path)
print(f"jcode hooks: registered {', '.join(todo)} for this home in {path}")
PY
    ;;
  -h|--help)
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "usage: fm-jcode-setup.sh [print|env|status|install]" >&2
    exit 2
    ;;
esac
