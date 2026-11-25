#!/usr/bin/env bats
# Reviewable clean: `mo clean --dry-run --json`, `--apply <plan_id> --select
# <file>` and `--trash`. Full-pipeline cases run the real sections in a temp
# HOME with every owner tool stubbed; only kept fixture items may change.

bats_require_minimum_version 1.5.0

load helpers/common

setup_file() {
    mole_test_setup_home clean-plan
    # The full pipeline otherwise scans the host's LaunchServices database.
    MOLE_LSREGISTER_PATH=""
    export MOLE_LSREGISTER_PATH
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/* "$HOME/.config" "$HOME/.npm" "$HOME/.Trash"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole" "$HOME/tmp"
}

# Stub every host tool the pipeline could reach. Owner tools record each call
# and fail, so a cleanup command that ran shows up in owner-calls.log; npm
# answers its cache lookup so the preview lists an `npm cache` command item.
plan_stub_toolchains() {
    STUB_BIN="$HOME/stub-bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK
    cat > "$STUB_BIN/lsof" << 'MOCK'
#!/bin/bash
case " $* " in
    *" -p 1 "*) printf 'p1\nu0\n'; exit 0 ;;
    *) exit 1 ;;
esac
MOCK
    printf '#!/bin/bash\nprintf "  PID  PPID COMM ARGS\\n"\n' > "$STUB_BIN/ps"
    printf '#!/bin/bash\nexit 1\n' > "$STUB_BIN/pgrep"
    printf '#!/bin/bash\nexit 1\n' > "$STUB_BIN/sudo"
    printf '#!/bin/bash\nexit 1\n' > "$STUB_BIN/xcrun"
    cat > "$STUB_BIN/npm" << 'MOCK'
#!/bin/bash
printf 'npm %s\n' "$*" >> "$HOME/owner-calls.log"
if [[ "$*" == "config get cache" ]]; then
    printf '%s\n' "$HOME/.npm"
    exit 0
fi
exit 0
MOCK
    local tool
    for tool in pip3 uv corepack pnpm bun mise conda nix-store tart go docker tmutil gem yarn; do
        # shellcheck disable=SC2016  # The stub body expands when the stub runs.
        printf '#!/bin/bash\nprintf "%%s %%s\\n" "${0##*/}" "$*" >> "$HOME/owner-calls.log"\nexit 97\n' > "$STUB_BIN/$tool"
    done
    chmod +x "$STUB_BIN"/*
}

# The environment every real-pipeline `mo clean` run here gets, in
# PLAN_CLEAN_ENV for `env`.
plan_clean_env() {
    # Loose probe budgets: a 2s process-table probe timing out on a loaded
    # runner cancels the preview and fails the case for no product reason.
    PLAN_CLEAN_ENV=(HOME="$HOME" TMPDIR="$HOME/tmp"
        MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MOLE_TIMEOUT_MEDIUM_PROBE_SEC=30
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="${PLAN_TEST_TRASH_DIR:-}"
        MOLE_CHROME_APP_PATHS="$HOME/none/Chrome.app" MOLE_EDGE_APP_PATHS="$HOME/none/Edge.app"
        MOLE_BRAVE_APP_PATHS="$HOME/none/Brave.app" MOLE_EXTERNAL_VOLUMES_ROOT="$HOME/none"
        MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$HOME/none" MOLE_XCODE_XCTEST_DEVICES_DIR="$HOME/none"
        MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$HOME/none"
        PATH="$STUB_BIN:$PATH")
}

# Run `mo clean ARGS` through the real pipeline with stdout and stderr apart.
run_plan_clean() {
    plan_clean_env
    run --separate-stderr env "${PLAN_CLEAN_ENV[@]}" "$PROJECT_ROOT/mole" clean "$@"
    # Bats shows this only when the case fails: the status and the run's end.
    printf 'mo clean %s -> status %s\n%s\n' "$*" "$status" "$(printf '%s\n' "$stderr" | tail -n 12)"
}

# Print the id of the plan item whose path (or command name) is $2.
plan_item_id() {
    python3 - "$1" "$2" << 'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for section in plan["sections"]:
    for item in section["items"]:
        if item.get("path") == sys.argv[2] or item.get("name") == sys.argv[2]:
            print(item["id"])
            sys.exit(0)
sys.exit(1)
PY
}

make_cache_fixture() {
    mkdir -p "$HOME/Library/Caches/AppA" "$HOME/Library/Caches/AppB" "$HOME/Library/Caches/AppC"
    dd if=/dev/zero of="$HOME/Library/Caches/AppA/a.bin" bs=1024 count=64 2> /dev/null
    dd if=/dev/zero of="$HOME/Library/Caches/AppB/b.bin" bs=1024 count=32 2> /dev/null
    dd if=/dev/zero of="$HOME/Library/Caches/AppC/c.bin" bs=1024 count=16 2> /dev/null
}

# Write $HOME/approved.plan from records of four fields each: P path devino "",
# D path "" "" or C section name text.
write_approved_plan() {
    local out="$HOME/approved.plan"
    : > "$out"
    while [[ $# -ge 4 ]]; do
        printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4" >> "$out"
        shift 4
    done
    printf 'END\0' >> "$out"
}

plan_devino() {
    /usr/bin/stat -f %d:%i "$1"
}

# Run a bash script from stdin with the libraries' environment and the fake
# tools in $HOME/fake-bin first on PATH.
run_lib_script() {
    mkdir -p "$HOME/fake-bin"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        PATH="$HOME/fake-bin:$PATH" "$@" /bin/bash --noprofile --norc
    # Bats shows this only when the case fails.
    printf 'status %s\n%s\n' "$status" "$(printf '%s\n' "$output" | tail -n 15)"
}

# A fake tool that appends its name and arguments to $HOME/tool-calls.log.
fake_logging_tool() {
    mkdir -p "$HOME/fake-bin"
    # shellcheck disable=SC2016  # The stub body expands when the stub runs.
    printf '#!/bin/bash\nprintf "%%s %%s\\n" "${0##*/}" "$*" >> "$HOME/tool-calls.log"\nexit 0\n' > "$HOME/fake-bin/$1"
    chmod +x "$HOME/fake-bin/$1"
}

@test "clean --dry-run --json prints only a JSON plan whose totals match the text preview" {
    plan_stub_toolchains
    make_cache_fixture
    local odd_dir="$HOME/Library/Caches/Odd \"quoted\" back\\slash"$'\n'"line"
    mkdir -p "$odd_dir"
    printf 'x\n' > "$odd_dir/f"

    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    [[ "$stderr" == *"Dry run complete"* ]] || return 1

    run python3 - "$HOME/plan.json" "$odd_dir" << 'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
plan = json.loads(raw)
assert plan["schema"] == 1 and plan["command"] == "clean", plan
assert re.fullmatch(r"[0-9a-f]{16}", plan["plan_id"]), plan["plan_id"]
for key in ("created_at", "expires_at"):
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", plan[key]), plan[key]
assert isinstance(plan["free_bytes"], int)
paths, ids, total_bytes, total_items = [], set(), 0, 0
for section in plan["sections"]:
    assert re.fullmatch(r"[a-z0-9-]+", section["id"]), section["id"]
    section_bytes = 0
    for item in section["items"]:
        assert item["id"] not in ids
        ids.add(item["id"])
        assert item["default_selected"] is True
        if item["kind"] == "path":
            paths.append(item["path"])
            if item["covered_by"] is None:
                section_bytes += item["bytes"]
                total_bytes += item["bytes"]
                total_items += item["count"]
        else:
            assert item["kind"] == "command" and "path" not in item and item["name"], item
    assert section["bytes"] == section_bytes, section
assert plan["total_bytes"] == total_bytes and plan["total_items"] == total_items, plan
assert sys.argv[2] in paths, "odd path did not round-trip"
assert any(i.get("name") == "npm cache" for s in plan["sections"] for i in s["items"])
assert {"section": "System", "name": "System caches", "reason": "needs sudo"} in plan["skipped"]
print(f"ITEMS={plan['total_items']} BYTES={plan['total_bytes']} ID={plan['plan_id']}")
PY
    [ "$status" -eq 0 ] || return 1
    local items bytes plan_id
    items=$(sed -n 's/.*ITEMS=\([0-9]*\).*/\1/p' <<< "$output")
    bytes=$(sed -n 's/.*BYTES=\([0-9]*\).*/\1/p' <<< "$output")
    plan_id=$(sed -n 's/.*ID=\([0-9a-f]*\).*/\1/p' <<< "$output")

    local preview="$HOME/.config/mole/clean-list.txt"
    [[ "$(sed -n 's/^# Items: //p' "$preview")" == "$items" ]] || return 1
    local human
    human=$(bash -c 'source "$1/lib/core/base.sh"; bytes_to_human "$2"' _ "$PROJECT_ROOT" "$bytes")
    [[ "$(sed -n 's/^# Potential cleanup: //p' "$preview")" == "$human" ]] || return 1

    [[ "$(/usr/bin/stat -f %Lp "$HOME/.config/mole/plans")" == "700" ]] || return 1
    [[ "$(/usr/bin/stat -f %Lp "$HOME/.config/mole/plans/$plan_id.ledger")" == "600" ]] || return 1
    # A preview changes nothing.
    [ -f "$HOME/Library/Caches/AppA/a.bin" ]
}

@test "clean --dry-run --json removes expired and future-dated plans and keeps a fresh one" {
    plan_stub_toolchains
    local plans="$HOME/.config/mole/plans"
    mkdir -p "$plans"
    chmod 700 "$plans"
    printf 'old' > "$plans/0000000000000001.ledger"
    printf 'future' > "$plans/0000000000000002.ledger"
    printf 'scratch' > "$plans/.plan.AbCdEf"
    printf 'fresh' > "$plans/0000000000000003.ledger"
    touch -t 202001010000 "$plans/0000000000000001.ledger" "$plans/.plan.AbCdEf"
    touch -t 209901010000 "$plans/0000000000000002.ledger"

    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$plans/0000000000000001.ledger" && ! -e "$plans/0000000000000002.ledger" ]] || return 1
    [[ ! -e "$plans/.plan.AbCdEf" ]] || return 1
    [ -f "$plans/0000000000000003.ledger" ]
}

@test "clean --apply removes only kept items, keeps new, deselected and replaced ones, and is safe to repeat" {
    plan_stub_toolchains
    make_cache_fixture
    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    local plan_id id_a id_b id_c
    plan_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    id_a=$(plan_item_id "$HOME/plan.json" "$HOME/Library/Caches/AppA")
    id_b=$(plan_item_id "$HOME/plan.json" "$HOME/Library/Caches/AppB")
    id_c=$(plan_item_id "$HOME/plan.json" "$HOME/Library/Caches/AppC")
    [[ -n "$id_a" && -n "$id_b" && -n "$id_c" ]] || return 1

    # Keep A and C; leave B unticked. After the review a sibling appears and
    # C is replaced by a new folder at the same path.
    printf '%s\n%s\n' "$id_a" "$id_c" > "$HOME/select.txt"
    mkdir -p "$HOME/Library/Caches/AppNew"
    printf 'new\n' > "$HOME/Library/Caches/AppNew/n.bin"
    rm -rf "$HOME/Library/Caches/AppC"
    mkdir -p "$HOME/Library/Caches/AppC"
    printf 'replaced\n' > "$HOME/Library/Caches/AppC/c.bin"
    : > "$HOME/owner-calls.log"

    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Reviewed plan $plan_id"* ]] || return 1
    [[ "$output" == *"Cleanup complete"* ]] || return 1
    [ ! -e "$HOME/Library/Caches/AppA" ] || return 1
    [ -f "$HOME/Library/Caches/AppB/b.bin" ] || return 1
    [ -f "$HOME/Library/Caches/AppNew/n.bin" ] || return 1
    [ -f "$HOME/Library/Caches/AppC/c.bin" ] || return 1
    # No unticked owner command ran, and nothing was written to the whitelist.
    ! grep -Eq 'cache clean|prune|purge|clear|--gc' "$HOME/owner-calls.log" || return 1
    [ ! -e "$HOME/.config/mole/whitelist" ] || return 1

    local oplog="$HOME/Library/Logs/mole/operations.log"
    grep -F "REMOVED $HOME/Library/Caches/AppA" "$oplog" > /dev/null || return 1
    grep -F "SKIPPED $HOME/Library/Caches/AppNew (not in reviewed plan)" "$oplog" > /dev/null || return 1
    grep -F "SKIPPED $HOME/Library/Caches/AppC (changed since review)" "$oplog" > /dev/null || return 1
    grep -F "SKIPPED npm cache (not in reviewed plan)" "$oplog" > /dev/null || return 1

    # The same request again: A is back under a new inode and stays.
    mkdir -p "$HOME/Library/Caches/AppA"
    printf 'again\n' > "$HOME/Library/Caches/AppA/a.bin"
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ -f "$HOME/Library/Caches/AppA/a.bin" ] || return 1
    grep -F "SKIPPED $HOME/Library/Caches/AppA (changed since review)" "$oplog" > /dev/null || return 1

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ] || return 1
    python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert any(s["command"] == "clean" for s in d["sessions"]), d' <<< "$output"
}

@test "clean --apply prints its run id once and no plain, dry-run or log-off run does" {
    plan_stub_toolchains
    make_cache_fixture
    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    local plan_id id_a
    plan_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    id_a=$(plan_item_id "$HOME/plan.json" "$HOME/Library/Caches/AppA")
    [[ -n "$id_a" ]] || return 1
    printf '%s\n' "$id_a" > "$HOME/select.txt"
    run_plan_clean --dry-run
    [ "$(printf '%s\n' "$output" | grep -c '^Run id: ')" -eq 0 ] || return 1

    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ "$(printf '%s\n' "$output" | grep -c '^Run id: ')" -eq 1 ] || return 1
    local id
    id=$(printf '%s\n' "$output" | sed -n 's/^Run id: //p')
    grep -F "[clean run=$id] " "$HOME/Library/Logs/mole/operations.log" > /dev/null
}

@test "clean --apply runs a kept owner command and only that one" {
    plan_stub_toolchains
    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    local plan_id npm_id
    plan_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    npm_id=$(plan_item_id "$HOME/plan.json" "npm cache")
    [[ -n "$npm_id" ]] || return 1
    printf '%s\n' "$npm_id" > "$HOME/select.txt"
    : > "$HOME/owner-calls.log"

    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    grep -Fx 'npm cache clean --force' "$HOME/owner-calls.log" > /dev/null || return 1
    if grep -Ev '^npm (config get cache|cache clean --force)$' "$HOME/owner-calls.log" |
        grep -Eq 'prune|purge|clear|--gc|clean'; then
        return 1
    fi
}

@test "clean --apply refuses a missing, expired, foreign, symlinked or damaged plan with its cause" {
    plan_stub_toolchains
    make_cache_fixture
    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    local plan_id id_a plans="$HOME/.config/mole/plans"
    plan_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    id_a=$(plan_item_id "$HOME/plan.json" "$HOME/Library/Caches/AppA")
    printf '%s\n' "$id_a" > "$HOME/select.txt"
    local plan="$plans/$plan_id.ledger"
    cp "$plan" "$HOME/plan.orig"

    # Rewrite one header field (created epoch = 2, uid = 3) or drop the end mark.
    rewrite_plan() {
        python3 - "$HOME/plan.orig" "$plan" "$1" "$2" << 'PY'
import sys
data = open(sys.argv[1], "rb").read().split(b"\0")
if sys.argv[3] == "truncate":
    data = data[:-3] + [b""]
else:
    data[int(sys.argv[3])] = sys.argv[4].encode()
open(sys.argv[2], "wb").write(b"\0".join(data))
PY
    }

    run_plan_clean --apply 00000000000000ff --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"no plan 00000000000000ff"* && "$stderr" == *"mo clean --dry-run --json"* ]] || return 1

    run_plan_clean --apply ../../etc --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"is not a plan id"* ]] || return 1

    rewrite_plan 2 "$(($(date +%s) - 7200))"
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"expired at"* && "$stderr" == *"review the new plan"* ]] || return 1

    rewrite_plan 2 "$(($(date +%s) + 7200))"
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"expired at"* ]] || return 1

    rewrite_plan 3 "$(($(id -u) + 1))"
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"saved by another user"* ]] || return 1

    rewrite_plan truncate x
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"not a complete Mole plan"* ]] || return 1

    cp "$HOME/plan.orig" "$plan"
    ln -s "$plan" "$plans/00000000000000aa.ledger"
    run_plan_clean --apply 00000000000000aa --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"is a symbolic link"* ]] || return 1

    printf 'i999999\n' > "$HOME/bad-select.txt"
    run_plan_clean --apply "$plan_id" --select "$HOME/bad-select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"'i999999', which is not an item of plan $plan_id"* ]] || return 1

    printf '\n  \n' > "$HOME/empty-select.txt"
    run_plan_clean --apply "$plan_id" --select "$HOME/empty-select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"lists no items"* ]] || return 1

    run_plan_clean --apply "$plan_id" --select "$HOME/missing-select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"cannot be read"* ]] || return 1

    # Every refusal left the fixture alone; the restored plan still applies.
    [ -f "$HOME/Library/Caches/AppA/a.bin" ] || return 1
    grep -F "SKIPPED $plan (plan expired)" "$HOME/Library/Logs/mole/operations.log" > /dev/null || return 1
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$HOME/Library/Caches/AppA" ]
}

@test "clean --apply --trash moves kept items to the Trash and logs TRASHED" {
    plan_stub_toolchains
    make_cache_fixture
    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    local plan_id id_a
    plan_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    id_a=$(plan_item_id "$HOME/plan.json" "$HOME/Library/Caches/AppA")
    printf '%s\n' "$id_a" > "$HOME/select.txt"

    PLAN_TEST_TRASH_DIR="$HOME/test-trash"
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt" --trash
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"to Trash"* ]] || return 1
    [ ! -e "$HOME/Library/Caches/AppA" ] || return 1
    local moved
    moved=$(find "$HOME/test-trash" -maxdepth 1 -name 'AppA.*' -type d | head -1)
    [[ -n "$moved" && -f "$moved/a.bin" ]] || return 1
    [ -f "$HOME/Library/Caches/AppB/b.bin" ] || return 1
    grep -F "TRASHED $HOME/Library/Caches/AppA" "$HOME/Library/Logs/mole/operations.log" > /dev/null || return 1
    if grep -F "REMOVED $HOME/Library/Caches/AppA" "$HOME/Library/Logs/mole/operations.log" > /dev/null; then
        return 1
    fi
}

# Save a plan over five cache folders with all of them kept, and put a slow
# `mv` on PATH for moves into the test Trash: it records each start in
# $HOME/moves.log, then sleeps 3 s before moving.
plan_slow_trash_apply_fixture() {
    plan_stub_toolchains
    local n
    for n in 1 2 3 4 5; do
        mkdir -p "$HOME/Library/Caches/Slow$n"
        dd if=/dev/zero of="$HOME/Library/Caches/Slow$n/f.bin" bs=1024 count=16 2> /dev/null
    done
    plan_clean_env
    env "${PLAN_CLEAN_ENV[@]}" "$PROJECT_ROOT/mole" clean --dry-run --json \
        > "$HOME/plan.json" 2> "$HOME/dry-run.err" || {
        tail -n 12 "$HOME/dry-run.err"
        return 1
    }
    python3 - "$HOME/plan.json" > "$HOME/select.txt" << 'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for section in plan["sections"]:
    for item in section["items"]:
        if "/Library/Caches/Slow" in (item.get("path") or ""):
            print(item["id"])
PY
    [ "$(grep -c . "$HOME/select.txt")" -eq 5 ] || return 1
    PLAN_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    PLAN_TEST_TRASH_DIR="$HOME/test-trash"
    cat > "$STUB_BIN/mv" << MOCK
#!/bin/bash
if [[ "\${2:-}" == "$PLAN_TEST_TRASH_DIR"/* ]]; then
    printf '%s\n' "\$1" >> "$HOME/moves.log"
    /bin/sleep 3
fi
exec /bin/mv "\$@"
MOCK
    chmod +x "$STUB_BIN/mv"
}

# Start `mo clean --apply --trash` in its own process group with default
# signal dispositions, as Mole Review does, wait (up to 90 s, for a loaded
# parallel run) until its second Trash move is under way, send $1 to the
# whole group and wait at most 10 s for it to end. Sets APPLY_STATUS,
# APPLY_SECONDS (signal to exit), MOVES_AT_SIGNAL and MOVES_AT_END; a run
# still alive is killed and fails the case.
plan_signal_slow_trash_apply() {
    local sig="$1"
    plan_clean_env
    rm -f "$HOME/moves.log" "$HOME/apply.pid" "$HOME/apply.status"
    /usr/bin/perl -e '
        my ($pidfile, $statusfile, @cmd) = @ARGV;
        my $pid = fork() // exit 125;
        # A background job starts with INT and QUIT ignored, and bash cannot
        # trap a signal ignored at entry; the app spawns with defaults.
        if ($pid == 0) { setpgrp(0, 0); $SIG{$_} = "DEFAULT" for qw(INT QUIT TERM HUP); exec @cmd; exit 127; }
        open(my $fh, ">", $pidfile) or exit 125; print $fh "$pid\n"; close $fh;
        waitpid($pid, 0);
        my $rc = ($? & 127) ? 128 + ($? & 127) : $? >> 8;
        open($fh, ">", "$statusfile.tmp") or exit 125; print $fh "$rc\n"; close $fh;
        rename("$statusfile.tmp", $statusfile);
    ' "$HOME/apply.pid" "$HOME/apply.status" \
        env "${PLAN_CLEAN_ENV[@]}" "$PROJECT_ROOT/mole" clean --apply "$PLAN_ID" \
        --select "$HOME/select.txt" --trash > "$HOME/apply.out" 2>&1 &
    local launcher=$! i pid=""
    for ((i = 0; i < 900; i++)); do
        [[ -s "$HOME/apply.pid" ]] && pid=$(< "$HOME/apply.pid")
        [[ -n "$pid" && -f "$HOME/moves.log" && $(grep -c . "$HOME/moves.log") -ge 2 ]] && break
        [[ -f "$HOME/apply.status" ]] && break
        /bin/sleep 0.1
    done
    MOVES_AT_SIGNAL=$(grep -c . "$HOME/moves.log" 2> /dev/null || true)
    [[ -n "$pid" && ! -f "$HOME/apply.status" ]] || {
        printf 'apply ended before the second move: %s\n' "$(tail -n 5 "$HOME/apply.out")"
        return 1
    }
    local started=$SECONDS
    kill -s "$sig" -- "-$pid"
    for ((i = 0; i < 100; i++)); do
        [[ -f "$HOME/apply.status" ]] && break
        /bin/sleep 0.1
    done
    APPLY_SECONDS=$((SECONDS - started))
    if [[ ! -f "$HOME/apply.status" ]]; then
        kill -s KILL -- "-$pid" 2> /dev/null || true
        wait "$launcher" 2> /dev/null || true
        printf '%s left the apply running past 10 s\n' "$sig"
        return 1
    fi
    wait "$launcher" 2> /dev/null || true
    APPLY_STATUS=$(< "$HOME/apply.status")
    MOVES_AT_END=$(grep -c . "$HOME/moves.log" 2> /dev/null || true)
    printf '%s: status %s after %ss, moves %s at signal, %s at end\n' \
        "$sig" "$APPLY_STATUS" "$APPLY_SECONDS" "$MOVES_AT_SIGNAL" "$MOVES_AT_END"
}

# The apply's own session in operations.log: its start row, TRASHED rows and
# end row, by the run id of the last `clean` session started.
plan_last_apply_session() {
    local log="$HOME/Library/Logs/mole/operations.log" run_id
    run_id=$(grep -o '# ========== clean run=[^ ]* session started' "$log" | tail -n 1 | sed 's/.*run=\([^ ]*\) .*/\1/')
    [[ -n "$run_id" ]] || return 1
    grep -F "run=$run_id" "$log"
}

@test "S8: clean --apply --trash stops at the item in flight on INT or TERM to its group and logs the session end" {
    plan_slow_trash_apply_fixture

    plan_signal_slow_trash_apply INT
    [ "$APPLY_STATUS" -eq 130 ] || return 1
    # Loose for a loaded runner; a run that went on to the next item would
    # start another 3 s move, which the move count below catches.
    [ "$APPLY_SECONDS" -le 8 ] || return 1
    # The first move finished; the second was under way and nothing started after.
    [ "$MOVES_AT_END" -eq "$MOVES_AT_SIGNAL" ] || return 1
    local session
    session=$(plan_last_apply_session)
    printf '%s\n' "$session"
    [ "$(grep -c 'TRASHED ' <<< "$session")" -eq 1 ] || return 1
    grep -q 'session ended at' <<< "$session" || return 1
    [ "$(grep -c 'session ended at' <<< "$session")" -eq 1 ] || return 1

    plan_signal_slow_trash_apply TERM
    [ "$APPLY_STATUS" -eq 143 ] || return 1
    [ "$APPLY_SECONDS" -le 8 ] || return 1
    [ "$MOVES_AT_END" -eq "$MOVES_AT_SIGNAL" ] || return 1
    session=$(plan_last_apply_session)
    printf '%s\n' "$session"
    [ "$(grep -c 'TRASHED ' <<< "$session")" -eq 1 ] || return 1
    [ "$(grep -c 'session ended at' <<< "$session")" -eq 1 ] || return 1
    # Two moves completed, one per run; the others stay where they were.
    [ "$(find "$HOME/test-trash" -mindepth 1 -maxdepth 1 -name 'Slow*' | wc -l | tr -d ' ')" -eq 2 ] || return 1
    [ "$(find "$HOME/Library/Caches" -mindepth 1 -maxdepth 1 -name 'Slow*' | wc -l | tr -d ' ')" -eq 3 ]
}

@test "clean refuses flag combinations the reviewable clean does not support" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --json
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"needs --dry-run"* && "$output" == *"mo clean --dry-run --json"* ]] || return 1

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --select "$HOME/s.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"--select needs --apply"* ]] || return 1

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --apply 0123456789abcdef
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"--apply needs --select"* ]] || return 1

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run --apply 0123456789abcdef --select "$HOME/s.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"cannot be combined with --dry-run"* ]] || return 1

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run --trash
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"a dry run removes nothing"* ]] || return 1

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --apply
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"Missing plan id for --apply"* ]]
}

# Write an approved-items file the sinks read, keeping one root. keptx shares
# its prefix and is not in the plan.
# shellcheck disable=SC2016  # The heredoc bodies expand inside the child shell.
PLAN_FUNNEL_PRELUDE='
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
export MOLE_CURRENT_COMMAND=clean
kept="$HOME/funnel/kept"
keptx="$HOME/funnel/keptx"
outside="$HOME/funnel/outside"
mkdir -p "$kept/sub" "$keptx" "$outside"
printf "k\n" > "$kept/sub/file.log"
printf "x\n" > "$keptx/file.log"
printf "o\n" > "$outside/file.log"
approved="$HOME/approved.plan"
printf "P\0%s\0%s\0\0END\0" "$kept" "$(/usr/bin/stat -f %d:%i "$kept")" > "$approved"
export MOLE_APPLY_PLAN="$approved"
'

@test "safe_remove under a reviewed plan refuses a path outside the kept items" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 PRELUDE="$PLAN_FUNNEL_PRELUDE" \
        /bin/bash --noprofile --norc << 'SCRIPT'
eval "$PRELUDE"
rc=0
safe_remove "$outside/file.log" true || rc=$?
printf 'OUTSIDE_RC=%s\n' "$rc"
[[ -f "$outside/file.log" ]] || exit 1
safe_remove "$kept/sub/file.log" true
[[ ! -e "$kept/sub/file.log" ]] || exit 1
grep -F "SKIPPED $outside/file.log (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"OUTSIDE_RC=1"* && "$output" == *"DONE"* ]]
}

@test "safe_sudo_remove under a reviewed plan refuses a path outside the kept items before sudo" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 PRELUDE="$PLAN_FUNNEL_PRELUDE" \
        /bin/bash --noprofile --norc << 'SCRIPT'
eval "$PRELUDE"
sudo() { printf 'SUDO-CALLED %s\n' "$*"; }
rc=0
safe_sudo_remove "$outside/file.log" || rc=$?
printf 'OUTSIDE_RC=%s\n' "$rc"
[[ -f "$outside/file.log" ]] || exit 1
grep -F "SKIPPED $outside/file.log (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"OUTSIDE_RC=13"* && "$output" == *"DONE"* ]] || return 1
    [[ "$output" != *"SUDO-CALLED"* ]]
}

@test "safe_find_delete under a reviewed plan keeps matches outside the kept items" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 PRELUDE="$PLAN_FUNNEL_PRELUDE" \
        /bin/bash --noprofile --norc << 'SCRIPT'
eval "$PRELUDE"
safe_find_delete "$HOME/funnel" "*.log" 0 f || true
[[ -f "$outside/file.log" ]] || exit 1
[[ ! -e "$kept/sub/file.log" ]] || exit 1
grep -F "SKIPPED $outside/file.log (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "safe_sudo_find_delete under a reviewed plan leaves matches outside the kept items out of its batch" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 PRELUDE="$PLAN_FUNNEL_PRELUDE" \
        /bin/bash --noprofile --norc << 'SCRIPT'
eval "$PRELUDE"
should_protect_path() { return 1; }
_mole_privileged_path_has_mutable_ancestor() { return 1; }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        test) [[ "${2:-}" == "-d" ]] ;;
        find) printf '%s\0' "$outside/file.log" "$kept/sub/file.log" ;;
        */stat) printf '1:2:3:8\n' ;;
        xargs)
            while IFS= read -r -d '' record; do
                rest=${record#*:}
                rest=${rest#*:}
                rest=${rest#*:}
                printf '%s\0' "$rest"
            done
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_find_delete "$HOME/funnel" "*.log" 0 f || true
grep -F "SKIPPED $outside/file.log (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
grep -F "REMOVED $kept/sub/file.log (batch)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
if grep -q "REMOVED .*/outside/" "$OPERATIONS_LOG_FILE"; then exit 1; fi
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "mole_delete under a reviewed plan refuses a path outside the kept items" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 PRELUDE="$PLAN_FUNNEL_PRELUDE" \
        /bin/bash --noprofile --norc << 'SCRIPT'
eval "$PRELUDE"
rc=0
mole_delete "$outside/file.log" || rc=$?
printf 'OUTSIDE_RC=%s\n' "$rc"
[[ -f "$outside/file.log" ]] || exit 1
mole_delete "$kept/sub/file.log"
[[ ! -e "$kept/sub/file.log" ]] || exit 1
grep -F "SKIPPED $outside/file.log (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"OUTSIDE_RC=1"* && "$output" == *"DONE"* ]]
}

@test "S9 reviewed plan index preserves literal paths and fails closed on reload" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
first="$HOME/space [*] _ café"
second="$HOME/space [*] _ cafe"
third="$HOME/line
break"
mkdir -p "$first" "$second" "$third"
first_id=$(/usr/bin/stat -f %d:%i "$first")
second_id=$(/usr/bin/stat -f %d:%i "$second")
third_id=$(/usr/bin/stat -f %d:%i "$third")
MOLE_APPLY_PLAN="$HOME/one.plan"
printf 'P\0%s\0%s\0\0P\0%s\0wrong\0\0P\0%s\0%s\0\0P\0%s\0%s\0\0END\0' \
    "$first" "$first_id" "$first" "$second" "$second_id" "$third" "$third_id" > "$MOLE_APPLY_PLAN"
# A caller's environment cannot inject an identity into the internal index.
_mole_apply_plan_key "$first"
printf -v "$_MOLE_APPLY_PLAN_KEY" '%s' "$second_id"
export "$_MOLE_APPLY_PLAN_KEY"
for path in "$first" "$second" "$third"; do
    mole_apply_plan_allows "$path" || exit 1
    [[ "$_MOLE_APPLY_PLAN_MATCHED_SELF" == true ]] || exit 1
done
MOLE_APPLY_PLAN="$HOME/two.plan"
printf 'P\0%s\0%s\0\0END\0' "$second" "$second_id" > "$MOLE_APPLY_PLAN"
mole_apply_plan_allows "$second" || exit 1
if mole_apply_plan_allows "$first"; then exit 1; fi
[[ "$_MOLE_APPLY_PLAN_REASON" == 'not in reviewed plan' ]] || exit 1
MOLE_APPLY_PLAN="$HOME/truncated.plan"
printf 'P\0%s\0%s\0\0' "$first" "$first_id" > "$MOLE_APPLY_PLAN"
if mole_apply_plan_allows "$first"; then exit 1; fi
[[ "$_MOLE_APPLY_PLAN_REASON" == 'reviewed plan unavailable' ]] || exit 1
printf 'literal paths, duplicate, reload and truncation checked\n'
SCRIPT
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *'literal paths, duplicate, reload and truncation checked'* ]]
}

@test "a reviewed plan refuses a kept root replaced since review and every path when its file is gone" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 PRELUDE="$PLAN_FUNNEL_PRELUDE" \
        /bin/bash --noprofile --norc << 'SCRIPT'
eval "$PRELUDE"
rm -rf "$kept"
mkdir -p "$kept/sub"
printf "k\n" > "$kept/sub/file.log"
safe_remove "$kept/sub/file.log" true || true
[[ -f "$kept/sub/file.log" ]] || exit 1
grep -F "SKIPPED $kept/sub/file.log (changed since review)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
MOLE_APPLY_PLAN="$HOME/no-such.plan"
safe_remove "$kept/sub/file.log" true || true
[[ -f "$kept/sub/file.log" ]] || exit 1
grep -F "SKIPPED $kept/sub/file.log (reviewed plan unavailable)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "clean_tool_cache under a reviewed plan runs an owner command only when its item was kept" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
export MOLE_CURRENT_COMMAND=clean
DRY_RUN=false
CURRENT_SECTION="Developer tools"
note_activity() { :; }
owner() { printf 'OWNER-RAN %s\n' "$1" >> "$HOME/owner-ran.log"; }
printf 'C\0Developer tools\0kept tool\0\0END\0' > "$HOME/approved.plan"
export MOLE_APPLY_PLAN="$HOME/approved.plan"
clean_tool_cache "kept tool" "" owner kept
clean_tool_cache "other tool" "" owner other
grep -F "SKIPPED other tool (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
cat "$HOME/owner-ran.log"
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"OWNER-RAN kept"* && "$output" == *"DONE"* ]] || return 1
    [[ "$output" != *"OWNER-RAN other"* ]]
}

@test "safe_remove under clean --trash moves to the Trash, never deletes, and keeps Trash items" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$HOME/test-trash" /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
export MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_TRASH=1
mkdir -p "$HOME/Library/Caches/TrashMe" "$HOME/.Trash/old"
printf 'x\n' > "$HOME/Library/Caches/TrashMe/f"
safe_remove "$HOME/Library/Caches/TrashMe" true
[[ ! -e "$HOME/Library/Caches/TrashMe" ]] || exit 1
ls "$HOME/test-trash" | grep -q '^TrashMe\.' || exit 1
grep -F "TRASHED $HOME/Library/Caches/TrashMe" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
safe_remove "$HOME/.Trash/old" true || true
[[ -d "$HOME/.Trash/old" ]] || exit 1
sudo() { printf 'SUDO-CALLED\n'; }
mkdir -p "$HOME/Library/Caches/RootOwned"
rc=0
safe_sudo_remove "$HOME/Library/Caches/RootOwned" || rc=$?
printf 'SUDO_RC=%s\n' "$rc"
[[ -d "$HOME/Library/Caches/RootOwned" ]] || exit 1
grep -F "SKIPPED $HOME/Library/Caches/RootOwned (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SUDO_RC=13"* && "$output" == *"DONE"* ]] || return 1
    [[ "$output" != *"SUDO-CALLED"* ]]
}

@test "S2 review #1: an unticked item between two kept ones survives the apply" {
    local x="$HOME/funnel/X"
    mkdir -p "$x/Y/Z" "$x/W" "$HOME/.config/mole/plans"
    chmod 700 "$HOME/.config/mole/plans"
    printf 'w\n' > "$x/W/f"
    printf 'y\n' > "$x/Y/f"
    printf 'z\n' > "$x/Y/Z/f"
    {
        printf '%s\0' MOLEPLAN 1 "$(date +%s)" "$(id -u)"
        local n=0 p
        for p in "$x" "$x/Y" "$x/Y/Z"; do
            n=$((n + 1))
            printf '%s\0' P "i$n" "User essentials" "$p" "$(plan_devino "$p")" 4 1 true "" ""
        done
        printf 'END\0'
    } > "$HOME/.config/mole/plans/00000000000000c1.ledger"
    printf 'i1\ni3\n' > "$HOME/select.txt"

    run_lib_script X="$x" << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/plan.sh"
export MOLE_CURRENT_COMMAND=clean
clean_plan_prepare_apply 00000000000000c1 "$HOME/select.txt"
safe_remove "$X" true || true
[[ -f "$X/Y/f" ]] || { echo "UNTICKED-Y-REMOVED"; exit 1; }
safe_remove "$X/Y/f" true || true
[[ -f "$X/Y/f" ]] || { echo "UNTICKED-Y-CONTENT-REMOVED"; exit 1; }
safe_remove "$X/Y/Z" true
[[ ! -e "$X/Y/Z" ]] || exit 1
safe_remove "$X/W" true
[[ ! -e "$X/W" ]] || exit 1
grep -F "SKIPPED $X (holds unticked item)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
grep -F "SKIPPED $X/Y/f (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "S2 review #2: clean --trash keeps owner commands, tmutil and the analyzer sweep and lists them" {
    fake_logging_tool tmutil
    mkdir -p "$HOME/.cache/mole" "$HOME/Volumes/B"
    printf 'x' > "$HOME/.cache/mole/old.cache"
    mkdir -p "$HOME/Volumes/B/2026-01-01.inprogress"

    run_lib_script MOLE_CLEAN_TRASH=1 MOLE_CURRENT_COMMAND=clean << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_DRY_RUN=0
CURRENT_SECTION="Developer tools"
note_activity() { :; }
owner() { printf 'OWNER-RAN\n' >> "$HOME/owner-ran.log"; }
clean_tool_cache "npm cache" "" owner
rc=0
_time_machine_delete_inprogress "$HOME/Volumes/B/2026-01-01.inprogress" "" || rc=$?
printf 'TM_RC=%s\n' "$rc"
start_legacy_analyzer_cache_sweep
sleep 0.5
[[ -f "$HOME/.cache/mole/old.cache" ]] || { echo "SWEEP-RAN"; exit 1; }
[[ ! -e "$HOME/owner-ran.log" ]] || { echo "OWNER-RAN"; exit 1; }
[[ ! -e "$HOME/tool-calls.log" ]] || { echo "TMUTIL-RAN"; exit 1; }
for label in "npm cache" "$HOME/Volumes/B/2026-01-01.inprogress" "$HOME/.cache/mole"; do
    grep -F "SKIPPED $label (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || { echo "NO-LOG $label"; exit 1; }
done
printf 'SKIPPED_LIST=%s\n' "${MOLE_CLEAN_TRASH_SKIPPED//$'\n'/|}"
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"TM_RC=13"* && "$output" == *"DONE"* ]] || return 1
    [[ "$output" == *"SKIPPED_LIST=npm cache|$HOME/Volumes/B/2026-01-01.inprogress|$HOME/.cache/mole"* ]]
}

@test "S2 review #2: clean --apply --trash keeps a kept owner command and says so in the summary" {
    plan_stub_toolchains
    run_plan_clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    local plan_id npm_id
    plan_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    npm_id=$(plan_item_id "$HOME/plan.json" "npm cache")
    [[ -n "$npm_id" ]] || return 1
    printf '%s\n' "$npm_id" > "$HOME/select.txt"
    : > "$HOME/owner-calls.log"

    PLAN_TEST_TRASH_DIR="$HOME/test-trash"
    run_plan_clean --apply "$plan_id" --select "$HOME/select.txt" --trash
    [ "$status" -eq 0 ] || return 1
    if grep -F 'cache clean' "$HOME/owner-calls.log"; then
        return 1
    fi
    grep -F "SKIPPED npm cache (needs permanent delete)" "$HOME/Library/Logs/mole/operations.log" > /dev/null || return 1
    [[ "$output" == *"needs a permanent delete"*"npm cache"* ]]
}

@test "S2 review #3: a kept root replaced after the entry check is kept, not removed" {
    run_lib_script PRELUDE="$PLAN_FUNNEL_PRELUDE" << 'SCRIPT'
eval "$PRELUDE"
swap_kept_root() {
    mv "$kept" "$kept-old"
    mkdir -p "$kept"
    printf "new\n" > "$kept/new.log"
}
_MOLE_SAFE_REMOVE_FINAL_GUARD=swap_kept_root
rc=0
safe_remove "$kept" true || rc=$?
printf 'RC=%s\n' "$rc"
[[ -f "$kept/new.log" ]] || { echo "REPLACEMENT-REMOVED"; exit 1; }
grep -F "SKIPPED $kept (changed since review)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=1"* && "$output" == *"DONE"* ]]
}

# ps lists two leaked automation browsers (ppid 1, automation profile).
fake_leaked_browsers() {
    mkdir -p "$HOME/fake-bin"
    cat > "$HOME/fake-bin/ps" << 'MOCK'
#!/bin/bash
printf '%s\n' \
    '  902     1 01-20:00:00 Tue Sep  1 02:03:04 2026 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-old' \
    '  906     1 01-21:00:00 Wed Sep  2 02:03:04 2026 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-later'
MOCK
    # shellcheck disable=SC2016  # The stub body expands when the stub runs.
    printf '#!/bin/bash\nprintf "%%s/\\n" "$HOME/tmproot"\n' > "$HOME/fake-bin/getconf"
    printf '#!/bin/bash\nexit 1\n' > "$HOME/fake-bin/pgrep"
    chmod +x "$HOME/fake-bin/ps" "$HOME/fake-bin/getconf" "$HOME/fake-bin/pgrep"
    mkdir -p "$HOME/tmproot"
}

# shellcheck disable=SC2016  # Expands inside the child shell.
BROWSER_PRELUDE='
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
export MOLE_CURRENT_COMMAND=clean
CURRENT_SECTION="Developer tools"
run_with_timeout() { shift; "$@"; }
kill() { printf "KILL %s\n" "$*" >> "$HOME/kill.trace"; return 0; }
sleep() { :; }
safe_clean() { :; }
note_activity() { :; }
'

@test "S2 review #4: a reviewed apply stops only the browsers the preview listed" {
    fake_leaked_browsers
    run_lib_script PRELUDE="$BROWSER_PRELUDE" << 'SCRIPT'
eval "$PRELUDE"
DRY_RUN=true
export MOLE_DRY_RUN=1
CLEAN_PREVIEW_COMMAND_LEDGER_FILE="$HOME/commands.ledger"
: > "$CLEAN_PREVIEW_COMMAND_LEDGER_FILE"
clean_dev_automation_browsers > /dev/null
tr '\0' '\n' < "$CLEAN_PREVIEW_COMMAND_LEDGER_FILE"
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"kill -TERM 902|Tue Sep 1 02:03:04 2026; 906|Wed Sep 2 02:03:04 2026"* ]] || return 1

    # Approved: only 902, as if 906 leaked after the review.
    write_approved_plan C "Developer tools" "Leaked automation browsers" "kill -TERM 902|Tue Sep 1 02:03:04 2026"
    run_lib_script PRELUDE="$BROWSER_PRELUDE" << 'SCRIPT'
eval "$PRELUDE"
DRY_RUN=false
export MOLE_APPLY_PLAN="$HOME/approved.plan"
clean_dev_automation_browsers
cat "$HOME/kill.trace"
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"KILL -TERM 902"* ]] || return 1
    [[ "$output" != *"906"* ]]
}

@test "S2 review #5: a sibling sharing a kept root's prefix survives safe_remove, safe_sudo_find_delete and mole_delete" {
    run_lib_script MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 PRELUDE="$PLAN_FUNNEL_PRELUDE" << 'SCRIPT'
eval "$PRELUDE"
safe_remove "$keptx/file.log" true || true
[[ -f "$keptx/file.log" ]] || { echo "SAFE-REMOVE-TOOK-KEPTX"; exit 1; }
mole_delete "$keptx/file.log" || true
[[ -f "$keptx/file.log" ]] || { echo "MOLE-DELETE-TOOK-KEPTX"; exit 1; }
should_protect_path() { return 1; }
_mole_privileged_path_has_mutable_ancestor() { return 1; }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        test) [[ "${2:-}" == "-d" ]] ;;
        find) printf '%s\0' "$keptx/file.log" "$kept/sub/file.log" ;;
        */stat) printf '1:2:3:8\n' ;;
        xargs)
            while IFS= read -r -d '' record; do
                rest=${record#*:}
                rest=${rest#*:}
                rest=${rest#*:}
                printf '%s\0' "$rest"
            done
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_find_delete "$HOME/funnel" "*.log" 0 f || true
if grep -q "REMOVED .*/keptx/" "$OPERATIONS_LOG_FILE"; then echo "SUDO-FIND-TOOK-KEPTX"; exit 1; fi
grep -F "REMOVED $kept/sub/file.log (batch)" "$OPERATIONS_LOG_FILE" > /dev/null || { echo "KEPT-NOT-REMOVED"; exit 1; }
[[ $(grep -c -F "SKIPPED $keptx/file.log (not in reviewed plan)" "$OPERATIONS_LOG_FILE") -eq 3 ]] || { echo "KEPTX-NOT-LOGGED"; exit 1; }
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "S2 review #6: tmutil delete asks the reviewed plan and --trash" {
    fake_logging_tool tmutil
    local backup="$HOME/Volumes/B/2026-01-01.inprogress"
    mkdir -p "$backup"
    write_approved_plan P "$HOME/elsewhere" "1:1" ""
    run_lib_script BACKUP="$backup" << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
export MOLE_CURRENT_COMMAND=clean MOLE_APPLY_PLAN="$HOME/approved.plan"
rc=0
_time_machine_delete_inprogress "$BACKUP" "" || rc=$?
printf 'UNTICKED_RC=%s\n' "$rc"
grep -F "SKIPPED $BACKUP (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
[[ ! -e "$HOME/tool-calls.log" ]] || { echo "TMUTIL-RAN-UNTICKED"; exit 1; }
printf 'P\0%s\0%s\0\0END\0' "$BACKUP" "$(/usr/bin/stat -f %d:%i "$BACKUP")" > "$HOME/approved2.plan"
MOLE_APPLY_PLAN="$HOME/approved2.plan"
rc=0
MOLE_CLEAN_TRASH=1 _time_machine_delete_inprogress "$BACKUP" "" || rc=$?
printf 'TRASH_RC=%s\n' "$rc"
grep -F "SKIPPED $BACKUP (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
[[ ! -e "$HOME/tool-calls.log" ]] || { echo "TMUTIL-RAN-UNDER-TRASH"; exit 1; }
_time_machine_delete_inprogress "$BACKUP" ""
grep -F "tmutil delete $BACKUP" "$HOME/tool-calls.log" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"UNTICKED_RC=13"* && "$output" == *"TRASH_RC=13"* && "$output" == *"DONE"* ]]
}

@test "S2 review #6: the container stub carve-out asks the reviewed plan and --trash" {
    local stub="$HOME/Library/Containers/com.macpaw.CleanMyMacX"
    mkdir -p "$stub"
    : > "$stub/.com.apple.containermanagerd.metadata.plist"
    write_approved_plan P "$HOME/elsewhere" "1:1" ""
    run_lib_script STUB="$stub" << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
export MOLE_CURRENT_COMMAND=clean MOLE_APPLY_PLAN="$HOME/approved.plan"
rc=0
_remove_verified_container_stub "$STUB" "$STUB/.com.apple.containermanagerd.metadata.plist" || rc=$?
printf 'UNTICKED_RC=%s\n' "$rc"
[[ -d "$STUB" ]] || exit 1
grep -F "SKIPPED $STUB (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
printf 'P\0%s\0%s\0\0END\0' "$STUB" "$(/usr/bin/stat -f %d:%i "$STUB")" > "$HOME/approved2.plan"
MOLE_APPLY_PLAN="$HOME/approved2.plan"
rc=0
MOLE_CLEAN_TRASH=1 _remove_verified_container_stub "$STUB" "$STUB/.com.apple.containermanagerd.metadata.plist" || rc=$?
printf 'TRASH_RC=%s\n' "$rc"
[[ -d "$STUB" ]] || exit 1
grep -F "SKIPPED $STUB (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
_remove_verified_container_stub "$STUB" "$STUB/.com.apple.containermanagerd.metadata.plist"
[[ ! -e "$STUB" ]] || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"UNTICKED_RC=13"* && "$output" == *"TRASH_RC=13"* && "$output" == *"DONE"* ]]
}

# xcrun lists one unavailable simulator and logs `simctl delete`.
fake_unavailable_simulator() {
    mkdir -p "$HOME/fake-bin" "$HOME/Xcode.app/Contents/Developer" \
        "$HOME/Library/Developer/CoreSimulator/Devices/ABCDEF01-2345-6789-ABCD-EF0123456789"
    cat > "$HOME/fake-bin/xcrun" << 'MOCK'
#!/bin/bash
case "$*" in
    "--find simctl") exit 0 ;;
    "simctl list devices unavailable")
        printf '    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)\n'
        exit 0
        ;;
    "simctl delete unavailable")
        printf 'simctl delete unavailable\n' >> "$HOME/tool-calls.log"
        exit 0
        ;;
esac
exit 1
MOCK
    # shellcheck disable=SC2016  # The stub body expands when the stub runs.
    printf '#!/bin/bash\nprintf "%%s\\n" "$HOME/Xcode.app/Contents/Developer"\n' > "$HOME/fake-bin/xcode-select"
    chmod +x "$HOME/fake-bin/xcrun" "$HOME/fake-bin/xcode-select"
}

# shellcheck disable=SC2016  # Expands inside the child shell.
SIMCTL_PRELUDE='
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
export MOLE_CURRENT_COMMAND=clean
DRY_RUN=false
device="$HOME/Library/Developer/CoreSimulator/Devices/ABCDEF01-2345-6789-ABCD-EF0123456789"
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
safe_remove() { echo "UNEXPECTED_FALLBACK:$1"; return 1; }
note_activity() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
'

@test "S2 review #6: simctl delete unavailable asks the reviewed plan and --trash" {
    fake_unavailable_simulator
    write_approved_plan P "$HOME/elsewhere" "1:1" ""
    run_lib_script PRELUDE="$SIMCTL_PRELUDE" << 'SCRIPT'
eval "$PRELUDE"
export MOLE_APPLY_PLAN="$HOME/approved.plan"
clean_dev_mobile
grep -F "SKIPPED simctl delete unavailable (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
[[ ! -e "$HOME/tool-calls.log" ]] || { echo "SIMCTL-RAN-UNTICKED"; exit 1; }
printf 'P\0%s\0%s\0\0END\0' "$device" "$(/usr/bin/stat -f %d:%i "$device")" > "$HOME/approved2.plan"
MOLE_APPLY_PLAN="$HOME/approved2.plan"
MOLE_CLEAN_TRASH=1 clean_dev_mobile
grep -F "SKIPPED simctl delete unavailable (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
[[ ! -e "$HOME/tool-calls.log" ]] || { echo "SIMCTL-RAN-UNDER-TRASH"; exit 1; }
clean_dev_mobile
grep -F "simctl delete unavailable" "$HOME/tool-calls.log" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* && "$output" != *"UNEXPECTED_FALLBACK"* ]]
}

@test "S2 review #7: a signal during the simulator plan check cancels the step" {
    fake_unavailable_simulator
    write_approved_plan P "$HOME/elsewhere" "1:1" ""
    run_lib_script PRELUDE="$SIMCTL_PRELUDE" << 'SCRIPT'
eval "$PRELUDE"
export MOLE_APPLY_PLAN="$HOME/approved.plan"
mole_apply_plan_allows() { return 130; }
rc=0
clean_dev_mobile || rc=$?
printf 'RC=%s CANCEL=%s\n' "$rc" "${MOLE_CLEAN_CANCEL_STATUS:-0}"
[[ ! -e "$HOME/tool-calls.log" ]] || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130 CANCEL=130"* && "$output" == *"DONE"* ]]
}

@test "S2 review #6: docker prune asks the reviewed plan and --trash" {
    write_approved_plan C "Developer tools" "other" ""
    run_lib_script << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
export MOLE_CURRENT_COMMAND=clean
DRY_RUN=false
CURRENT_SECTION="Developer tools"
note_activity() { :; }
mole_docker_endpoint_is_local() { return 0; }
is_path_whitelisted() { return 1; }
run_with_timeout() { shift; "$@"; }
docker() {
    printf 'docker %s\n' "$*" >> "$HOME/tool-calls.log"
    case "$1" in
        info) echo 27.0 ;;
        context) echo default ;;
    esac
}
MOLE_APPLY_PLAN="$HOME/approved.plan" clean_docker_unused_data
grep -F "SKIPPED Docker build cache and dangling images (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
MOLE_CLEAN_TRASH=1 clean_docker_unused_data
grep -F "SKIPPED Docker build cache and dangling images (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
if grep -F prune "$HOME/tool-calls.log"; then exit 1; fi
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "S2 review #6: go clean asks the reviewed plan and --trash" {
    mkdir -p "$HOME/go-cache"
    write_approved_plan C "Developer tools" "other" ""
    run_lib_script << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
export MOLE_CURRENT_COMMAND=clean
DRY_RUN=false
CURRENT_SECTION="Developer tools"
note_activity() { :; }
go() { :; }
run_with_timeout() { shift; printf '%s\n' "$*" >> "$HOME/tool-calls.log"; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
MOLE_APPLY_PLAN="$HOME/approved.plan" clean_go_cache_root "$HOME/go-cache" GOCACHE -cache "Go build cache"
grep -F "SKIPPED Go build cache (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
MOLE_CLEAN_TRASH=1 clean_go_cache_root "$HOME/go-cache" GOCACHE -cache "Go build cache"
grep -F "SKIPPED Go build cache (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
if grep -F clean "$HOME/tool-calls.log" 2> /dev/null; then exit 1; fi
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "S2 review #6: brew cleanup asks the reviewed plan and --trash" {
    write_approved_plan C "Homebrew" "other" ""
    run_lib_script << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"
export MOLE_CURRENT_COMMAND=clean
DRY_RUN=false
CURRENT_SECTION="Homebrew"
note_activity() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
is_path_whitelisted() { return 1; }
run_with_timeout() { shift; "$@"; }
brew() { printf 'brew %s\n' "$*" >> "$HOME/tool-calls.log"; }
MOLE_APPLY_PLAN="$HOME/approved.plan" clean_homebrew
grep -F "SKIPPED Homebrew cleanup (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
MOLE_CLEAN_TRASH=1 clean_homebrew
grep -F "SKIPPED Homebrew cleanup (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
if grep -F cleanup "$HOME/tool-calls.log" 2> /dev/null; then exit 1; fi
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "S2 review #6: tart prune asks the reviewed plan and --trash" {
    mkdir -p "$HOME/.tart/cache/OCIs"
    write_approved_plan C "Virtualization" "other" ""
    run_lib_script << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
export MOLE_CURRENT_COMMAND=clean
DRY_RUN=false
CURRENT_SECTION="Virtualization"
note_activity() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 4096; }
run_with_timeout() { shift; "$@"; }
tart() { printf 'tart %s\n' "$*" >> "$HOME/tool-calls.log"; }
MOLE_APPLY_PLAN="$HOME/approved.plan" clean_tart_caches
grep -F "SKIPPED Tart caches (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
MOLE_CLEAN_TRASH=1 clean_tart_caches
grep -F "SKIPPED Tart caches (needs permanent delete)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
if grep -F prune "$HOME/tool-calls.log" 2> /dev/null; then exit 1; fi
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "S2 review #6: the automation-browser stop asks the reviewed plan" {
    fake_leaked_browsers
    write_approved_plan C "Developer tools" "other" ""
    run_lib_script PRELUDE="$BROWSER_PRELUDE" << 'SCRIPT'
eval "$PRELUDE"
DRY_RUN=false
export MOLE_APPLY_PLAN="$HOME/approved.plan"
clean_dev_automation_browsers
grep -F "SKIPPED Leaked automation browsers (not in reviewed plan)" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
[[ ! -e "$HOME/kill.trace" ]] || { echo "KILLED-UNTICKED"; exit 1; }
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}

@test "S2 review #8: a root --apply is refused as a root run, not as a foreign plans folder" {
    run_lib_script << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/plan.sh"
is_root_user() { return 0; }
rc=0
clean_plan_prepare_apply 0123456789abcdef "$HOME/select.txt" || rc=$?
printf 'RC=%s\n' "$rc"
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"as your own user"* ]] || return 1
    [[ "$output" != *"Remove it"* && "$output" != *"no plan"* ]]
}

@test "S2 review #9: a preview that stops or is cancelled prints a JSON error document" {
    local rc code
    for rc in 75 130; do
        code=incomplete
        [[ $rc -eq 130 ]] && code=cancelled
        # shellcheck disable=SC2016  # The script expands in the child shell.
        run --separate-stderr env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
            STOP_RC="$rc" /bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/bin/clean.sh"
start_cleanup() { :; }
mole_report_program_status() { :; }
perform_cleanup() { echo "section output"; return "$STOP_RC"; }
main --dry-run --json'
        [ "$status" -eq "$rc" ] || return 1
        python3 -c '
import json, sys
doc = json.loads(sys.argv[1])
assert doc["schema"] == 1 and doc["command"] == "clean", doc
assert doc["error"]["code"] == sys.argv[2], doc
assert doc["error"]["message"], doc
assert "plan_id" not in doc, doc
' "$output" "$code" || return 1
    done
}

@test "S2 review #10: an unticked path holding a separator byte makes the plan unavailable, not ignored" {
    local x="$HOME/funnel/X" odd
    odd="$x/a"$'\x1f'"b"
    mkdir -p "$odd"
    printf 'u\n' > "$odd/f"
    write_approved_plan P "$x" "$(plan_devino "$x")" "" D "$odd" "" ""
    run_lib_script X="$x" << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
export MOLE_CURRENT_COMMAND=clean MOLE_APPLY_PLAN="$HOME/approved.plan"
odd="$X/a"$'\x1f'"b"
safe_remove "$X" true || true
[[ -f "$odd/f" ]] || { echo "UNTICKED-REMOVED"; exit 1; }
grep -F "SKIPPED $X (reviewed plan unavailable" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
grep -F "separator" "$OPERATIONS_LOG_FILE" > /dev/null || exit 1
echo DONE
SCRIPT
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DONE"* ]]
}
