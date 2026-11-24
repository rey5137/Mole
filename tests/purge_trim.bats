#!/usr/bin/env bats
# Rust `target` trim in `mo purge`: the trim row of the review (menu and
# `--dry-run --json`), the trim rule, and `--apply` of a trim. Every case runs
# in a temp HOME whose only purge path is $HOME/www.

bats_require_minimum_version 1.5.0

load helpers/common

setup_file() {
    mole_test_setup_home purge-trim
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/* "$HOME/.config" "$HOME/.cache" "$HOME/.Trash"
    mkdir -p "$HOME/www" "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/tmp"
    printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"
    OLD_STAMP=$(/bin/date -v-8d +%Y%m%d%H%M)
    FRESH_STAMP=$(/bin/date -v-1d +%Y%m%d%H%M)
}

# $1 bytes into file $2, dated $3 (a touch -t stamp) when given.
put() {
    mkdir -p "$(dirname "$2")"
    head -c "$1" /dev/zero > "$2"
    [[ -z "${3:-}" ]] || touch -t "$3" "$2"
}

# A Rust project ~/www/$1 whose target holds one profile (debug) and one
# cross-compile profile (aarch64-apple-darwin/release), with old and fresh
# entries in deps, build and .fingerprint, a fresh incremental cache, and the
# outputs a trim must keep.
make_rust() {
    local project="$HOME/www/$1" t="$HOME/www/$1/target"
    put 10 "$project/Cargo.toml" "$OLD_STAMP"
    put 100 "$t/.rustc_info.json" "$OLD_STAMP"
    put 100 "$t/CACHEDIR.TAG" "$OLD_STAMP"
    put 40960 "$t/debug/myapp" "$OLD_STAMP"
    put 40960 "$t/debug/incremental/myapp-1/s-1/dep-graph.bin"
    put 40960 "$t/debug/deps/libold-1.rlib" "$OLD_STAMP"
    put 40960 "$t/debug/deps/libnew-2.rlib" "$FRESH_STAMP"
    put 40960 "$t/debug/build/oldpkg-1/out/gen.rs" "$OLD_STAMP"
    touch -t "$OLD_STAMP" "$t/debug/build/oldpkg-1/out" "$t/debug/build/oldpkg-1"
    put 4096 "$t/debug/build/newpkg-2/out/gen.rs" "$FRESH_STAMP"
    touch -t "$FRESH_STAMP" "$t/debug/build/newpkg-2"
    put 4096 "$t/debug/.fingerprint/old-1/hash" "$OLD_STAMP"
    touch -t "$OLD_STAMP" "$t/debug/.fingerprint/old-1"
    put 4096 "$t/debug/.fingerprint/new-2/hash" "$FRESH_STAMP"
    touch -t "$FRESH_STAMP" "$t/debug/.fingerprint/new-2"
    put 40960 "$t/doc/index.html" "$OLD_STAMP"
    local cross="$t/aarch64-apple-darwin/release"
    put 40960 "$cross/incremental/x/data.bin" "$OLD_STAMP"
    put 40960 "$cross/deps/libcross-9.rlib" "$OLD_STAMP"
    put 4096 "$cross/deps/libcrossnew-8.rlib" "$FRESH_STAMP"
    put 40960 "$cross/crossapp" "$OLD_STAMP"
}

run_purge() {
    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$HOME/test-trash" "$PROJECT_ROOT/mole" purge "$@" < /dev/null
    printf 'mo purge %s -> status %s\nstdout:\n%s\nstderr:\n%s\n' "$*" "$status" "$output" \
        "$(printf '%s\n' "$stderr" | tail -n 15)"
}

make_plan() {
    run_purge --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    PLAN_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    [[ "$PLAN_ID" =~ ^[0-9a-f]{16}$ ]]
}

# The id of the plan item of kind $2 (path or trim) whose path is $1.
plan_item_id() {
    python3 - "$HOME/plan.json" "$1" "$2" << 'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for section in plan["sections"]:
    for item in section["items"]:
        if item.get("path") == sys.argv[2] and item["kind"] == sys.argv[3]:
            print(item["id"])
            sys.exit(0)
sys.exit(1)
PY
}

oplog() {
    cat "$HOME/Library/Logs/mole/operations.log" 2> /dev/null || true
}

teardown() {
    # A case may leave an immutable fixture file behind.
    chflags -R nouchg "$HOME/www" 2> /dev/null || true
}

# Source Mole's purge libraries in a bash that then runs the rest of stdin.
purge_lib_shell() {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 MOLE_CURRENT_COMMAND=purge "$@" \
        /bin/bash --noprofile --norc
}

# Print the output of the last run without colors.
plain_output() {
    printf '%s\n' "$output" | sed $'s/\x1b\\[[0-9;]*m//g'
}

# The size the summary prints for the trim entries $2.. of project $1, as
# measured now.
expected_freed() {
    local project="$1"
    shift
    local t="$HOME/www/$project/target" kb=0 entry entry_kb
    for entry in "$@"; do
        entry_kb=$(/usr/bin/du -skP "$t/$entry" | awk '{print $1}')
        kb=$((kb + entry_kb))
    done
    # shellcheck disable=SC2016  # Expanded by the inner bash.
    env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" KB="$kb" /bin/bash --noprofile --norc -c \
        'source "$PROJECT_ROOT/lib/core/common.sh"; bytes_to_human_kb "$KB"'
}

# What a trim must keep in the make_rust fixture, $1 the project.
assert_trim_kept() {
    local t="$HOME/www/$1/target"
    local kept
    for kept in .rustc_info.json CACHEDIR.TAG debug/myapp debug/deps/libnew-2.rlib debug/build/newpkg-2/out/gen.rs \
        debug/.fingerprint/new-2/hash doc/index.html aarch64-apple-darwin/release/deps/libcrossnew-8.rlib \
        aarch64-apple-darwin/release/crossapp ../Cargo.toml; do
        [ -e "$t/$kept" ] || {
            echo "missing: $kept"
            return 1
        }
    done
}

# What a trim must take in the make_rust fixture, $1 the project.
assert_trim_taken() {
    local t="$HOME/www/$1/target"
    local gone
    for gone in debug/incremental debug/deps/libold-1.rlib debug/build/oldpkg-1 debug/.fingerprint/old-1 \
        aarch64-apple-darwin/release/incremental aarch64-apple-darwin/release/deps/libcross-9.rlib; do
        [ ! -e "$t/$gone" ] || {
            echo "still there: $gone"
            return 1
        }
    done
}

@test "purge_rust_trim_list takes incremental and old profile entries and keeps everything else" {
    make_rust rs
    local t="$HOME/www/rs/target"
    # A symlinked deps folder is never walked, so its old entries stay.
    mkdir -p "$HOME/elsewhere/deps"
    put 4096 "$HOME/elsewhere/deps/liblinked.rlib" "$OLD_STAMP"
    put 4096 "$t/linked/.fingerprint/x/hash" "$OLD_STAMP"
    touch -t "$OLD_STAMP" "$t/linked/.fingerprint/x"
    ln -s "$HOME/elsewhere/deps" "$t/linked/deps"
    # A profile reached through a symlinked triple is never listed.
    mkdir -p "$HOME/elsewhere/triple/debug/deps"
    put 4096 "$HOME/elsewhere/triple/debug/deps/libtriple.rlib" "$OLD_STAMP"
    ln -s "$HOME/elsewhere/triple" "$t/x86_64-linked"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" T="$t" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
list=$(mktemp "$HOME/tmp/list.XXXXXX")
purge_rust_trim_list "$T" "$list"
tr '\0' '\n' < "$list" | sed "s|^$T/||" | LC_ALL=C sort
EOF
    [ "$status" -eq 0 ] || return 1
    local expected
    expected=$(printf '%s\n' aarch64-apple-darwin/release/deps/libcross-9.rlib aarch64-apple-darwin/release/incremental \
        debug/.fingerprint/old-1 debug/build/oldpkg-1 debug/deps/libold-1.rlib debug/incremental \
        linked/.fingerprint/x | LC_ALL=C sort)
    printf 'got:\n%s\nwant:\n%s\n' "$output" "$expected"
    [ "$output" = "$expected" ]
}

@test "purge --dry-run --json lists a trim row for a Rust target only, covered by its whole item" {
    make_rust rs
    # A Maven target shares the name; it is offered whole and never trimmed.
    put 10 "$HOME/www/mvn/pom.xml" "$OLD_STAMP"
    put 4096 "$HOME/www/mvn/target/classes/A.class" "$OLD_STAMP"
    put 4096 "$HOME/www/mvn/target/debug/deps/libx.rlib" "$OLD_STAMP"
    put 4096 "$HOME/www/mvn/target/debug/incremental/x" "$OLD_STAMP"
    # A Rust target with nothing to trim gets no trim row.
    put 10 "$HOME/www/bare/Cargo.toml" "$OLD_STAMP"
    put 4096 "$HOME/www/bare/target/debug/bare" "$OLD_STAMP"
    put 4096 "$HOME/www/bare/target/debug/deps/libfresh.rlib" "$FRESH_STAMP"

    # The text preview lists whole folders only, as before.
    run_purge --dry-run
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"trim"* ]] || return 1

    make_plan || return 1
    python3 - "$HOME/plan.json" "$HOME" << 'PY'
import json, subprocess, sys
plan = json.load(open(sys.argv[1]))
home = sys.argv[2]
rows = [item for section in plan["sections"] for item in section["items"]]
keys = ["id", "kind", "path", "bytes", "size_known", "count", "covered_by", "default_selected", "artifact", "age", "cloud"]
by = {(r["kind"], r["path"]): r for r in rows}
rs = f"{home}/www/rs/target"
whole, trim = by[("path", rs)], by[("trim", rs)]
# Shared fields first, in the order of the whole item, so one decoder reads both.
assert list(trim.keys()) == keys, list(trim.keys())
assert list(whole.keys()) == keys, list(whole.keys())
assert trim["covered_by"] == whole["id"], (trim, whole)
assert trim["default_selected"] is False and trim["artifact"] == "target", trim
assert trim["count"] == 6 and trim["size_known"] is True, trim
entries = ["debug/incremental", "debug/deps/libold-1.rlib", "debug/build/oldpkg-1", "debug/.fingerprint/old-1",
           "aarch64-apple-darwin/release/incremental", "aarch64-apple-darwin/release/deps/libcross-9.rlib"]
du = subprocess.run(["/usr/bin/du", "-skP"] + [f"{rs}/{e}" for e in entries], capture_output=True, text=True, check=True)
expected_kb = sum(int(line.split()[0]) for line in du.stdout.splitlines())
assert trim["bytes"] == expected_kb * 1024 and trim["bytes"] < whole["bytes"], (trim, expected_kb, whole)
assert trim["age"] == whole["age"] and trim["cloud"] == whole["cloud"], (trim, whole)
ids = [r["id"] for r in rows]
assert ids.index(trim["id"]) == ids.index(whole["id"]) + 1, ids
assert ("trim", f"{home}/www/mvn/target") not in by and ("path", f"{home}/www/mvn/target") in by, by.keys()
assert ("trim", f"{home}/www/bare/target") not in by and ("path", f"{home}/www/bare/target") in by, by.keys()
# The trim adds nothing to the totals: its bytes are part of the whole folder's.
assert plan["total_bytes"] == sum(r["bytes"] for r in rows if r["covered_by"] is None), plan["total_bytes"]
assert plan["total_bytes"] == sum(s["bytes"] for s in plan["sections"])
PY
}

@test "purge offers no trim row while its Rust target is in use" {
    make_rust rs
    # The idle project proves the run offers trim rows at all.
    make_rust idle
    (
        cd /
        exec 9< "$HOME/www/rs/target/debug/myapp"
        exec sleep 30
    ) &
    local holder=$!
    sleep 0.3
    run_purge --dry-run --json
    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    plan_item_id "$HOME/www/idle/target" trim > /dev/null || return 1
    [[ "$output" != *"www/rs/target"* ]]
}

@test "purge --apply of a trim alone trims the target and keeps it" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    assert_trim_taken rs || return 1
    assert_trim_kept rs || return 1
    oplog | grep -F "REMOVED $HOME/www/rs/target/debug/incremental" > /dev/null || return 1
    oplog | grep -F "REMOVED $HOME/www/rs/target/debug/deps/libold-1.rlib" > /dev/null || return 1
    if oplog | grep -F "REMOVED $HOME/www/rs/target " > /dev/null; then
        return 1
    fi
    [ "$(grep -c "	$HOME/www/rs/target/" "$HOME/Library/Logs/mole/deletions.log")" -eq 6 ] || return 1

    # The same request again: nothing old is left, so nothing is removed.
    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    assert_trim_kept rs
}

@test "purge --apply of a trim and its whole target removes the target once" {
    make_rust rs
    make_plan || return 1
    {
        plan_item_id "$HOME/www/rs/target" path
        plan_item_id "$HOME/www/rs/target" trim
    } > "$HOME/select.txt" || return 1

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$HOME/www/rs/target" ] || return 1
    [ -f "$HOME/www/rs/Cargo.toml" ] || return 1
    [ "$(oplog | grep -c -F "$HOME/www/rs/target")" -eq 1 ] || return 1
    oplog | grep -F "REMOVED $HOME/www/rs/target" > /dev/null || return 1
    [[ "$output" == *"Items: 1"* ]]
}

@test "purge --apply refuses a trim whose target was replaced since review" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    mv "$HOME/www/rs/target" "$HOME/www/rs/target.reviewed"
    make_rust rs

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ -d "$HOME/www/rs/target/debug/incremental" ] || return 1
    [ -f "$HOME/www/rs/target/debug/deps/libold-1.rlib" ] || return 1
    [[ "$output" == *"Kept · 1 item: ~/www/rs/target (changed since review)"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/rs/target (changed since review)" > /dev/null
}

@test "purge --apply refuses a trim while its target is in use" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    (
        cd /
        exec 9< "$HOME/www/rs/target/debug/myapp"
        exec sleep 30
    ) &
    local holder=$!
    sleep 0.3

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
    [ "$status" -eq 1 ] || return 1
    [ -d "$HOME/www/rs/target/debug/incremental" ] || return 1
    [ -f "$HOME/www/rs/target/debug/deps/libold-1.rlib" ] || return 1
    [[ "$output" == *"in use; stop what has it open"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/rs/target (in use)" > /dev/null
}

@test "purge --apply --trash moves trim entries to the Trash" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt" --trash
    [ "$status" -eq 0 ] || return 1
    assert_trim_taken rs || return 1
    assert_trim_kept rs || return 1
    [ -n "$(find "$HOME/test-trash" -maxdepth 1 -name 'libold-1.rlib*')" ] || return 1
    [ -n "$(find "$HOME/test-trash" -maxdepth 1 -name 'incremental*' -type d)" ] || return 1
    oplog | grep -F "TRASHED $HOME/www/rs/target/debug/deps/libold-1.rlib" > /dev/null || return 1
    if oplog | grep -F "REMOVED $HOME/www/rs/target/" > /dev/null; then
        return 1
    fi
}

@test "purge --apply recomputes the trim set and keeps an entry that became fresh" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    # Rebuilt since review: no longer older than the trim age.
    touch "$HOME/www/rs/target/debug/deps/libold-1.rlib"
    # Old since review, though the review never listed it.
    put 4096 "$HOME/www/rs/target/debug/deps/liblater-3.rlib" "$OLD_STAMP"

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ -f "$HOME/www/rs/target/debug/deps/libold-1.rlib" ] || return 1
    [ ! -e "$HOME/www/rs/target/debug/deps/liblater-3.rlib" ] || return 1
    [ ! -e "$HOME/www/rs/target/debug/incremental" ]
}

@test "purge --apply of a trim never lets the sinks take the target folder itself" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1

    # Stage the approval of that trim and ask the sink gate about the target,
    # a binary beside the trim scope, and entries inside it.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PLAN_ID="$PLAN_ID" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
source "$PROJECT_ROOT/lib/clean/plan.sh"
source "$PROJECT_ROOT/lib/clean/purge_plan.sh"
CLEAN_PLAN_COMMAND=purge
clean_plan_load_selection "$PLAN_ID" "$HOME/select.txt"
clean_plan_stage_path_selection
t="$HOME/www/rs/target"
for p in "$t" "$t/debug/myapp" "$t/debug" "$t/debug/deps/libnew-2.rlib" "$t/aarch64-apple-darwin/release/deps/libcrossnew-8.rlib"; do
    if mole_apply_plan_allows "$p"; then echo "allowed ${p#"$t"}"; else echo "refused ${p#"$t"} ($_MOLE_APPLY_PLAN_REASON)"; fi
done
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"refused  (not in reviewed plan)"* ]] || return 1
    [[ "$output" == *"refused /debug/myapp (not in reviewed plan)"* ]] || return 1
    [[ "$output" == *"refused /debug (not in reviewed plan)"* ]] || return 1
    [[ "$output" == *"allowed /debug/deps/libnew-2.rlib"* ]] || return 1
    [[ "$output" == *"allowed /aarch64-apple-darwin/release/deps/libcrossnew-8.rlib"* ]]
}

@test "purge menu counts a trim once and drops it when its whole target is ticked" {
    command -v python3 > /dev/null 2>&1 || skip "python3 not available"
    run python3 "$PROJECT_ROOT/tests/purge_trim_menu_pty.py"
    [ "$status" -eq 0 ]
}

@test "purge menu run removes a ticked target once when its trim is ticked too" {
    command -v python3 > /dev/null 2>&1 || skip "python3 not available"
    make_rust rs
    run python3 "$PROJECT_ROOT/tests/purge_trim_menu_run_pty.py" "$HOME" "$PROJECT_ROOT"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"CONFIRM "*"Remove 1 artifact,"* ]] || return 1
    [[ "$output" == *"Items: 1"* ]] || return 1
    [[ "$output" == *"EXIT 0"* ]] || return 1
    [[ "$output" != *"Skipped"* ]] || return 1
    [ ! -e "$HOME/www/rs/target" ] || return 1
    [ "$(oplog | grep -c -F "REMOVED $HOME/www/rs/target")" -eq 1 ]
}

@test "purge trim reports its own refusal cause, never a stale one from an earlier item" {
    make_rust rs
    purge_lib_shell T="$HOME/www/rs/target" << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
item_path="$T"
display_item_path="~/www/rs/target (trim)"
# An earlier item's Trash failure, then a sink that refuses before safe_remove.
_MOLE_SAFE_REMOVE_SKIP_REASON="trash-failed"
mole_delete() { return 1; }
_purge_trim_selected_item || echo "rc=$?"
EOF
    [[ "$output" == *"rc=1"* ]] || return 1
    [[ "$output" == *"(final removal check failed)"* ]] || return 1
    [[ "$output" != *"Trash"* ]]
}

@test "purge trim asks its final guard before removing a symlinked incremental" {
    make_rust rs
    local t="$HOME/www/rs/target"
    rm -rf "$t/debug/incremental"
    mkdir -p "$HOME/elsewhere/incr"
    put 4096 "$HOME/elsewhere/incr/keep.bin"
    ln -s "$HOME/elsewhere/incr" "$t/debug/incremental"
    # The final guard refuses every entry here: it has no reviewed target.
    purge_lib_shell T="$t" << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
item_path="$T"
display_item_path="~/www/rs/target (trim)"
_MOLE_PURGE_FINAL_TRIM_TARGET=""
_MOLE_SAFE_REMOVE_FINAL_GUARD="_mole_purge_trim_final_guard"
_purge_trim_selected_item || echo "rc=$?"
EOF
    [[ "$output" == *"rc=1"* ]] || return 1
    [ -L "$t/debug/incremental" ] || return 1
    [ -f "$HOME/elsewhere/incr/keep.bin" ] || return 1
    [ -f "$t/debug/deps/libold-1.rlib" ] || return 1
    oplog | grep -F "SKIPPED $t/debug/incremental (sink guard denied)" > /dev/null
}

@test "purge trim total counts only the entries it removed" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    # Rebuilt since review: kept, so it frees nothing.
    touch "$HOME/www/rs/target/debug/deps/libold-1.rlib"
    local expected
    expected=$(expected_freed rs debug/incremental debug/build/oldpkg-1 debug/.fingerprint/old-1 \
        aarch64-apple-darwin/release/incremental aarch64-apple-darwin/release/deps/libcross-9.rlib)

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ -f "$HOME/www/rs/target/debug/deps/libold-1.rlib" ] || return 1
    plain_output | grep -F "Estimated space freed: $expected | Items: 1" > /dev/null
}

@test "purge trim counts the entries removed when another entry fails" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    # One entry cannot be removed.
    chflags uchg "$HOME/www/rs/target/debug/.fingerprint/old-1/hash"
    local expected
    expected=$(expected_freed rs debug/incremental debug/deps/libold-1.rlib debug/build/oldpkg-1 \
        aarch64-apple-darwin/release/incremental aarch64-apple-darwin/release/deps/libcross-9.rlib)

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/www/rs/target/debug/.fingerprint/old-1/hash" ] || return 1
    [ ! -e "$HOME/www/rs/target/debug/deps/libold-1.rlib" ] || return 1
    plain_output | grep -F "Estimated space freed: $expected | Items: 1" > /dev/null || return 1
    [[ "$output" == *"Kept · 1 item: ~/www/rs/target (trim incomplete)"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/rs/target (trim incomplete)" > /dev/null
}

# shellcheck disable=SC2030 # Bats runs each test in its own subshell.
@test "purge --apply names a trim whose scope could not be listed while staging" {
    make_rust rs
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    # The profile listing times out once, while the sink approval is staged.
    purge_lib_shell PLAN_ID="$PLAN_ID" << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
source "$PROJECT_ROOT/lib/clean/plan.sh"
source "$PROJECT_ROOT/lib/clean/purge_plan.sh"
CLEAN_PLAN_COMMAND=purge
eval "$(declare -f _purge_rust_trim_profiles | sed '1s/_purge_rust_trim_profiles/_real_trim_profiles/')"
PROFILE_CALLS=0
_purge_rust_trim_profiles() {
    PROFILE_CALLS=$((PROFILE_CALLS + 1))
    [[ $PROFILE_CALLS -gt 1 ]] || return 124
    _real_trim_profiles "$@"
}
mkdir -p "$HOME/.cache/mole"
clean_plan_load_selection "$PLAN_ID" "$HOME/select.txt"
PURGE_APPLY_PLAN_ID="$PLAN_ID"
purge_plan_apply
echo "outcome=$PURGE_RUN_OUTCOME"
printf 'kept=%s\n' "$PURGE_APPLY_SKIPPED"
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"(its trim set could not be listed in time; run mo purge again)"* ]] || return 1
    [[ "$output" != *"not in reviewed plan"* ]] || return 1
    [[ "$output" == *"outcome=incomplete"* ]] || return 1
    [[ "$output" == *"kept=~/www/rs/target (could not list trim)"* ]] || return 1
    [ -d "$HOME/www/rs/target/debug/incremental" ] || return 1
    oplog | grep -F "SKIPPED $HOME/www/rs/target (could not list trim)" > /dev/null
}

# A Rust project ~/www/$1 whose debug profile holds $2 old deps entries.
make_rust_deps() {
    local t="$HOME/www/$1/target" i
    put 10 "$HOME/www/$1/Cargo.toml" "$OLD_STAMP"
    put 100 "$t/.rustc_info.json" "$OLD_STAMP"
    mkdir -p "$t/debug/deps"
    for ((i = 0; i < $2; i++)); do
        head -c 2048 /dev/zero > "$t/debug/deps/lib$i.rlib"
    done
    touch -t "$OLD_STAMP" "$t/debug/deps/"*
}

# Apply the reviewed trim of PLAN_ID ($HOME/select.txt, from make_plan) in a
# shell with Mole's purge libraries, after running the bash given on stdin
# (stubs and hooks), then print the trim's outcome.
apply_trim_in_shell() {
    local hooks
    hooks=$(cat)
    purge_lib_shell PLAN_ID="$PLAN_ID" HOOKS="$hooks" << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
source "$PROJECT_ROOT/lib/clean/plan.sh"
source "$PROJECT_ROOT/lib/clean/purge_plan.sh"
CLEAN_PLAN_COMMAND=purge
eval "$HOOKS"
mkdir -p "$HOME/.cache/mole"
clean_plan_load_selection "$PLAN_ID" "$HOME/select.txt"
PURGE_APPLY_PLAN_ID="$PLAN_ID"
purge_plan_apply
echo "outcome=${PURGE_RUN_OUTCOME:-done} removed=$_PURGE_TRIM_REMOVED_COUNT"
EOF
    # shellcheck disable=SC2031 # status and output come from purge_lib_shell in this same test.
    printf 'trim apply -> status %s\n%s\n' "$status" "$output"
}

@test "purge trim rebinds its target once per batch and sizes each entry once" {
    make_rust_deps rs 40
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    # Every du the trim runs names its operands here.
    mkdir -p "$HOME/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" >> "%s"\nexec /usr/bin/du "$@"\n' "$HOME/du-args" > "$HOME/bin/du"
    chmod +x "$HOME/bin/du"

    # Counted in files: several of these run in command substitutions.
    apply_trim_in_shell << 'HOOKS'
PATH="$HOME/bin:$PATH"
deps="$HOME/www/rs/target/debug/deps"
eval "$(declare -f _mole_purge_final_artifact_unchanged | sed '1s/^_mole_purge_final_artifact_unchanged /_real_unchanged /')"
_mole_purge_final_artifact_unchanged() {
    echo x >> "$HOME/folder-rebinds"
    _real_unchanged "$@"
}
eval "$(declare -f get_path_size_kb | sed '1s/^get_path_size_kb /_real_size_kb /')"
get_path_size_kb() {
    printf '%s\n' "$1" >> "$HOME/size-args"
    _real_size_kb "$@"
}
eval "$(declare -f mole_deletion_identity | sed '1s/^mole_deletion_identity /_real_identity /')"
mole_deletion_identity() {
    [[ "$1" != "$deps" ]] || echo x >> "$HOME/root-reads"
    _real_identity "$@"
}
HOOKS
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"outcome=completed removed=40"* ]] || return 1
    [ -z "$(ls "$HOME/www/rs/target/debug/deps")" ] || return 1
    [ "$(oplog | grep -c "REMOVED $HOME/www/rs/target/debug/deps/lib")" -eq 40 ] || return 1
    # Batches of at most 32: the target folder and the plan's deps root are
    # each read exactly once a batch, not once an entry and not skipped.
    local batches=$(((40 + 31) / 32))
    [ "$(wc -l < "$HOME/folder-rebinds")" -eq "$batches" ] || return 1
    [ "$(cat "$HOME/root-reads" 2> /dev/null | wc -l)" -eq "$batches" ] || return 1
    # Each entry is measured exactly once, by du or by get_path_size_kb.
    local i sized
    for ((i = 0; i < 40; i++)); do
        sized=$(cat "$HOME/du-args" "$HOME/size-args" 2> /dev/null |
            grep -cxF "$HOME/www/rs/target/debug/deps/lib$i.rlib" || true)
        [ "$sized" -eq 1 ] || {
            echo "lib$i.rlib sized $sized times"
            return 1
        }
    done
}

@test "purge trim refuses the rest of a batch once its target is swapped for a copy" {
    make_rust_deps rs 40
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1

    # After the fifth removal the target is replaced by a copy: same names,
    # same old dates, other inodes.
    apply_trim_in_shell << 'HOOKS'
eval "$(declare -f log_operation | sed '1s/^log_operation /_real_log_operation /')"
log_operation() {
    _real_log_operation "$@"
    if [[ "$2" == REMOVED ]]; then
        REMOVED_ROWS=$((${REMOVED_ROWS:-0} + 1))
        if [[ $REMOVED_ROWS -eq 5 ]]; then
            mv "$HOME/www/rs/target" "$HOME/www/rs/target.reviewed"
            cp -Rp "$HOME/www/rs/target.reviewed" "$HOME/www/rs/target"
        fi
    fi
    return 0
}
HOOKS
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"outcome=incomplete removed=5"* ]] || return 1
    [[ "$output" == *"Skipped 35 "*" of ~/www/rs/target (trim) (changed since review;"* ]] || return 1
    [ "$(find "$HOME/www/rs/target/debug/deps" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 35 ] || return 1
    [ "$(find "$HOME/www/rs/target.reviewed/debug/deps" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 35 ] || return 1
    [ "$(oplog | grep -c "REMOVED $HOME/www/rs/target")" -eq 5 ]
}

@test "purge trim refuses an entry swapped for a symlink after its identity was read" {
    make_rust_deps rs 40
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1
    put 4096 "$HOME/outside/keep.rlib" "$OLD_STAMP"

    # Validation runs after the trim read the entry's identity.
    apply_trim_in_shell << 'HOOKS'
victim="$HOME/www/rs/target/debug/deps/lib7.rlib"
eval "$(declare -f validate_path_for_deletion | sed '1s/^validate_path_for_deletion /_real_validate /')"
validate_path_for_deletion() {
    if [[ "$1" == "$victim" && ! -L "$victim" && -z "${SWAPPED:-}" ]]; then
        SWAPPED=1
        rm -f "$victim"
        ln -s "$HOME/outside/keep.rlib" "$victim"
    fi
    _real_validate "$@"
}
HOOKS
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"outcome=incomplete removed=39"* ]] || return 1
    [ -L "$HOME/www/rs/target/debug/deps/lib7.rlib" ] || return 1
    [ -f "$HOME/outside/keep.rlib" ] || return 1
    [ "$(find "$HOME/www/rs/target/debug/deps" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
}

@test "purge --apply --trash trashes every entry of a large trim with one row each" {
    make_rust_deps rs 40
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt" --trash
    [ "$status" -eq 0 ] || return 1
    [ -z "$(ls "$HOME/www/rs/target/debug/deps")" ] || return 1
    [ "$(find "$HOME/test-trash" -maxdepth 1 -name 'lib*.rlib*' | wc -l)" -eq 40 ] || return 1
    [ "$(oplog | grep -c "TRASHED $HOME/www/rs/target/debug/deps/lib")" -eq 40 ] || return 1
    if oplog | grep -F "REMOVED $HOME/www/rs/target/" > /dev/null; then
        return 1
    fi
    [ "$(grep -c "	trash	[0-9]*	ok	$HOME/www/rs/target/debug/deps/lib" "$HOME/Library/Logs/mole/deletions.log")" -eq 40 ]
}

@test "purge trim stops at a signal from its sink and counts only what went" {
    make_rust_deps rs 40
    purge_lib_shell T="$HOME/www/rs/target" << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
item_path="$T"
display_item_path="~/www/rs/target (trim)"
# The third entry's removal is interrupted. The sink runs rm in a command
# substitution, so the count lives in a file.
rm() {
    if [[ "${!#}" == */debug/deps/* ]]; then
        echo x >> "$HOME/rm-calls"
        [[ $(wc -l < "$HOME/rm-calls") -ne 3 ]] || return 130
    fi
    command rm "$@"
}
_purge_trim_selected_item || echo "rc=$?"
echo "removed=$_PURGE_TRIM_REMOVED_COUNT"
EOF
    [[ "$output" == *"rc=130"* ]] || return 1
    [[ "$output" == *"removed=2"* ]] || return 1
    [ "$(find "$HOME/www/rs/target/debug/deps" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 38 ]
}

@test "purge trim dry run removes nothing and logs each entry as a preview" {
    make_rust_deps rs 40
    purge_lib_shell T="$HOME/www/rs/target" MOLE_DRY_RUN=1 << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
item_path="$T"
display_item_path="~/www/rs/target (trim)"
_purge_trim_selected_item || echo "rc=$?"
echo "removed=$_PURGE_TRIM_REMOVED_COUNT"
EOF
    [[ "$output" != *"rc="* ]] || return 1
    [[ "$output" == *"removed=40"* ]] || return 1
    [ "$(find "$HOME/www/rs/target/debug/deps" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 40 ] || return 1
    [ "$(grep -c "	dry-run	$HOME/www/rs/target/debug/deps/lib" "$HOME/Library/Logs/mole/deletions.log")" -eq 40 ]
}

@test "purge trim keeps an entry rewritten in place after its batch began" {
    make_rust_deps rs 40
    make_plan || return 1
    plan_item_id "$HOME/www/rs/target" trim > "$HOME/select.txt" || return 1

    # After the fifth removal a build rewrites every entry left in place:
    # same inodes, new mtimes.
    apply_trim_in_shell << 'HOOKS'
eval "$(declare -f log_operation | sed '1s/^log_operation /_real_log_operation /')"
log_operation() {
    _real_log_operation "$@"
    if [[ "$2" == REMOVED ]]; then
        REMOVED_ROWS=$((${REMOVED_ROWS:-0} + 1))
        [[ $REMOVED_ROWS -ne 5 ]] || touch "$HOME/www/rs/target/debug/deps/"*
    fi
    return 0
}
HOOKS
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"outcome=incomplete removed=5"* ]] || return 1
    [ "$(find "$HOME/www/rs/target/debug/deps" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 35 ] || return 1
    [ "$(grep -c "	identity-changed	$HOME/www/rs/target/debug/deps/lib" "$HOME/Library/Logs/mole/deletions.log")" -eq 27 ]
}

@test "purge trim dry run leaves out an entry the run would refuse as another user's" {
    make_rust_deps rs 40
    purge_lib_shell T="$HOME/www/rs/target" MOLE_DRY_RUN=1 << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
item_path="$T"
display_item_path="~/www/rs/target (trim)"
# As if a sudo build left this one root-owned.
_mole_user_sink_refuses_on_ownership() { [[ "$1" == */lib7.rlib ]]; }
_purge_trim_selected_item || echo "rc=$?"
echo "removed=$_PURGE_TRIM_REMOVED_COUNT"
EOF
    [[ "$output" == *"removed=39"* ]] || return 1
    [ "$(find "$HOME/www/rs/target/debug/deps" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 40 ] || return 1
    if grep -q "	dry-run	$HOME/www/rs/target/debug/deps/lib7.rlib$" "$HOME/Library/Logs/mole/deletions.log"; then
        return 1
    fi
    oplog | grep -F "SKIPPED $HOME/www/rs/target/debug/deps/lib7.rlib (owned by another user)" > /dev/null
}
