#!/usr/bin/env bash
# shellcheck disable=SC2016 # lib() snippets are single-quoted so the library's shell expands them.
# Behavior tests for the free-memory check before heavy work
# (bin/fm-mem-headroom-lib.sh owns the verdict): fm-spawn defers a fresh worker,
# fm-lint drops to one ShellCheck job and waits before each root, and
# fm-test-run clamps --jobs, all against a fake meminfo file so no real memory
# pressure is needed. Unreadable meminfo must always let the work proceed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-mem-headroom)
LOW="$TMP_ROOT/meminfo.low"
HIGH="$TMP_ROOT/meminfo.high"
NOAVAIL="$TMP_ROOT/meminfo.noavail"
printf 'MemTotal: 6796244 kB\nMemAvailable: 512000 kB\nSwapTotal: 4194300 kB\nSwapFree: 512000 kB\n' > "$LOW"
printf 'MemTotal: 6796244 kB\nMemAvailable: 4096000 kB\nSwapTotal: 4194300 kB\nSwapFree: 4194300 kB\n' > "$HIGH"
printf 'MemTotal: 6796244 kB\nMemFree: 100 kB\n' > "$NOAVAIL"

lib() {  # <meminfo> <threshold> <shell snippet>
  FM_MEMINFO_OVERRIDE=$1 FM_MEM_HEADROOM_MIB=$2 bash -c ". '$ROOT/bin/fm-mem-headroom-lib.sh'; $3"
}

test_verdict_counts_available_memory_plus_free_swap() {
  # 500 MiB available + 500 MiB free swap = 1000 MiB.
  lib "$LOW" 1536 'fm_mem_headroom_low && echo "low $FM_MEM_HEADROOM_AVAILABLE_MIB"' | grep -qx 'low 1000' \
    || fail "1000 MiB of memory plus swap was not judged low against 1536 MiB"
  lib "$LOW" 900 'fm_mem_headroom_low' && fail "free swap was not counted as headroom"
  lib "$HIGH" 1536 'fm_mem_headroom_low' && fail "ample memory was judged low"
  pass "headroom is MemAvailable plus free swap, judged against the threshold"
}

test_unmeasurable_memory_steps_aside() {
  lib "$TMP_ROOT/no-such-meminfo" 999999 'fm_mem_headroom_low' && fail "unreadable meminfo blocked work"
  lib "$NOAVAIL" 999999 'fm_mem_headroom_low' && fail "meminfo without MemAvailable blocked work"
  lib "$TMP_ROOT/no-such-meminfo" 999999 'fm_mem_headroom_clamp_jobs 4; echo "$FM_MEM_HEADROOM_JOBS"' | grep -qx 4 \
    || fail "unreadable meminfo clamped jobs"
  pass "unreadable or incomplete meminfo always allows the work"
}

test_threshold_override_and_config() {
  local config="$TMP_ROOT/config"
  mkdir -p "$config"
  lib "$LOW" 0 'fm_mem_headroom_low' && fail "a zero threshold did not disable the check"
  printf '800\n' > "$config/mem-headroom-mib"
  FM_MEMINFO_OVERRIDE=$LOW FM_MEM_HEADROOM_MIB='' FM_CONFIG_OVERRIDE=$config \
    bash -c ". '$ROOT/bin/fm-mem-headroom-lib.sh'; fm_mem_headroom_low" \
    && fail "config/mem-headroom-mib 800 still judged 1000 MiB low"
  printf '2000\n' > "$config/mem-headroom-mib"
  FM_MEMINFO_OVERRIDE=$LOW FM_MEM_HEADROOM_MIB='' FM_CONFIG_OVERRIDE=$config \
    bash -c ". '$ROOT/bin/fm-mem-headroom-lib.sh'; fm_mem_headroom_low" \
    || fail "config/mem-headroom-mib 2000 did not judge 1000 MiB low"
  FM_MEMINFO_OVERRIDE=$LOW FM_MEM_HEADROOM_MIB='' FM_CONFIG_OVERRIDE="$TMP_ROOT/empty-config" \
    bash -c ". '$ROOT/bin/fm-mem-headroom-lib.sh'; fm_mem_headroom_low && echo \$FM_MEM_HEADROOM_THRESHOLD_MIB" | grep -qx 1536 \
    || fail "the default threshold is not 1536 MiB"
  pass "FM_MEM_HEADROOM_MIB, then config/mem-headroom-mib, then 1536 MiB set the threshold; 0 disables it"
}

test_clamp_jobs_fits_shares() {
  lib "$HIGH" 1536 'fm_mem_headroom_clamp_jobs 8; echo "$FM_MEM_HEADROOM_JOBS"' | grep -qx 5 \
    || fail "8 jobs were not clamped to the 5 shares that fit in 8000 MiB"
  lib "$HIGH" 1536 'fm_mem_headroom_clamp_jobs 2; echo "$FM_MEM_HEADROOM_JOBS"' | grep -qx 2 \
    || fail "clamp raised or lowered a job count that already fits"
  lib "$LOW" 1536 'fm_mem_headroom_clamp_jobs 4; echo "$FM_MEM_HEADROOM_JOBS"' | grep -qx 1 \
    || fail "low memory did not clamp to one job"
  pass "the job clamp keeps only the threshold-sized shares that fit, never below one"
}

test_wait_is_bounded() {
  local out
  out=$(FM_MEM_HEADROOM_WAIT_SECONDS=2 FM_MEM_HEADROOM_POLL_SECONDS=1 \
    lib "$LOW" 1536 'fm_mem_headroom_wait probe; echo "rc=$?"' 2>&1)
  assert_contains "$out" "mem-headroom: probe waits for free memory (1000 MiB available, 1536 MiB wanted; up to 2s)" \
    "the wait did not announce itself"
  assert_contains "$out" "mem-headroom: probe starts anyway after waiting 2s" "the wait was not bounded"
  assert_contains "$out" "rc=0" "the bounded wait did not let the work proceed"
  out=$(lib "$HIGH" 1536 'fm_mem_headroom_wait probe; echo "rc=$?"' 2>&1)
  [ "$out" = "rc=0" ] || fail "ample memory still waited: $out"
  pass "the per-root wait is bounded and silent when memory is ample"
}

# --- fm-spawn ---------------------------------------------------------------

spawn_case() {  # <name> <meminfo>
  local case_dir="$TMP_ROOT/$1" fakebin home rc=0 out
  mkdir -p "$case_dir"
  home="$case_dir/home"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" task-m
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir" gh gh-axi no-mistakes)
  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" worktree add --quiet -b wt-task-m "$case_dir/wt" >/dev/null 2>&1
  out=$(FM_MEMINFO_OVERRIDE=$2 FM_MEM_HEADROOM_MIB=1536 FM_BACKEND=tmux \
    fm_test_run_spawn "$home" "$case_dir/wt" "$fakebin" task-m "$case_dir/project" --mode local-only --yolo off) || rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

test_spawn_defers_on_low_memory() {
  local result rc out home="$TMP_ROOT/spawn-low/home"
  result=$(spawn_case spawn-low "$LOW")
  rc=${result%%$'\n'*}
  out=${result#*$'\n'}
  expect_code 75 "$rc" "a spawn on a host short of memory was not deferred: $out"
  assert_contains "$out" "deferred: this host has 1000 MiB of free memory and swap, below the 1536 MiB a fresh worker needs" \
    "the deferral did not name the memory shortfall"
  assert_contains "$out" "task task-m was not launched and its backlog item stays queued" \
    "the deferral did not say the task stays queued"
  assert_absent "$home/state/task-m.meta" "a memory deferral published a task record"
  assert_absent "$home/data/task-m/launch-brief.md" "a memory deferral rendered a launch brief"
  assert_absent "$TMP_ROOT/spawn-low/fakebin/.spawn-window" "a memory deferral opened a window"
  pass "fm-spawn defers a fresh worker with exit 75 and creates nothing when memory is low"
}

test_spawn_proceeds_when_memory_is_unmeasurable() {
  local result rc out
  result=$(spawn_case spawn-unknown "$TMP_ROOT/no-such-meminfo")
  rc=${result%%$'\n'*}
  out=${result#*$'\n'}
  assert_not_contains "$out" "deferred:" "unreadable meminfo deferred a spawn"
  expect_code 0 "$rc" "a spawn with unreadable meminfo failed: $out"
  pass "fm-spawn launches normally when memory cannot be measured"
}

# --- fm-lint ----------------------------------------------------------------

lint_stub() {  # <fakebin>
  cat > "$1/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
exit 0
SH
  chmod +x "$1/shellcheck"
}

test_lint_drops_to_one_job_and_waits() {
  local dir="$TMP_ROOT/lint" fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  lint_stub "$fakebin"
  printf '#!/usr/bin/env bash\necho a\n' > "$dir/a.sh"
  printf '#!/usr/bin/env bash\necho b\n' > "$dir/b.sh"
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_MEMINFO_OVERRIDE=$LOW FM_MEM_HEADROOM_MIB=1536 \
    FM_MEM_HEADROOM_WAIT_SECONDS=1 FM_MEM_HEADROOM_POLL_SECONDS=1 \
    "$ROOT/bin/fm-lint.sh" --jobs 2 "$dir/a.sh" "$dir/b.sh" 2>&1) || fail "low-memory lint failed: $out"
  assert_contains "$out" "fm-lint.sh: 1000 MiB of free memory and swap is below 1536 MiB; running one ShellCheck job" \
    "lint did not drop to one job on low memory"
  assert_contains "$out" "mem-headroom: fm-lint root $dir/a.sh waits for free memory" "lint did not wait before a root"
  assert_contains "$out" "mem-headroom: fm-lint root $dir/b.sh waits for free memory" "lint did not wait before every root"
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_MEMINFO_OVERRIDE=$HIGH FM_MEM_HEADROOM_MIB=1536 \
    "$ROOT/bin/fm-lint.sh" --jobs 2 "$dir/a.sh" "$dir/b.sh" 2>&1) || fail "ample-memory lint failed: $out"
  assert_not_contains "$out" "mem-headroom" "lint waited with ample memory"
  assert_not_contains "$out" "running one ShellCheck job" "lint dropped a job with ample memory"
  pass "fm-lint runs one bounded-waiting ShellCheck job on low memory and is unchanged otherwise"
}

# --- fm-test-run ------------------------------------------------------------

test_test_run_clamps_jobs() {
  local repo="$TMP_ROOT/runner" out s
  mkdir -p "$repo/bin" "$repo/tests"
  for s in fm-test-run.sh fm-timeout-lib.sh fm-mem-headroom-lib.sh fm-jev-mem-guard.py; do
    cp "$ROOT/bin/$s" "$repo/bin/$s"
  done
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  for s in fm-brief.test.sh fm-cd-pretool-check.test.sh; do
    printf '#!/usr/bin/env bash\necho "ok - fixture"\n' > "$repo/tests/$s"
    chmod +x "$repo/tests/$s"
  done
  out=$(cd "$repo" && FM_MEMINFO_OVERRIDE=$LOW FM_MEM_HEADROOM_MIB=1536 \
    bin/fm-test-run.sh --jobs 2 --json "$repo/low.json" tests/fm-brief.test.sh tests/fm-cd-pretool-check.test.sh 2>&1) \
    || fail "low-memory test run failed: $out"
  assert_contains "$out" "holds 1 share(s) of 1536 MiB; running with --jobs 1 instead of 2" \
    "fm-test-run did not clamp --jobs on low memory"
  grep -q '"selection": "[^"]*;jobs=1"' "$repo/low.json" || fail "the timing artifact did not record the clamped count"
  out=$(cd "$repo" && FM_MEMINFO_OVERRIDE=$HIGH FM_MEM_HEADROOM_MIB=1536 \
    bin/fm-test-run.sh --jobs 2 --json "$repo/high.json" tests/fm-brief.test.sh tests/fm-cd-pretool-check.test.sh 2>&1) \
    || fail "ample-memory test run failed: $out"
  assert_not_contains "$out" "running with --jobs" "fm-test-run clamped with ample memory"
  grep -q '"selection": "[^"]*;jobs=2"' "$repo/high.json" || fail "ample memory changed the job count"
  pass "fm-test-run clamps --jobs to the shares free memory holds"
}

test_verdict_counts_available_memory_plus_free_swap
test_unmeasurable_memory_steps_aside
test_threshold_override_and_config
test_clamp_jobs_fits_shares
test_wait_is_bounded
test_spawn_defers_on_low_memory
test_spawn_proceeds_when_memory_is_unmeasurable
test_lint_drops_to_one_job_and_waits
test_test_run_clamps_jobs
