#!/usr/bin/env bats
# Reviewable installer cleanup: `mo installer --dry-run --json`, `--apply
# <plan_id> --select <file>` and `--trash`. Every case runs the real
# `mo installer` in a temp HOME; only kept fixture files may change. The scan
# also reads /Users/Shared, so assertions look only at items under $HOME and
# every selection names fixture items only.

bats_require_minimum_version 1.5.0

load helpers/common

setup_file() {
    mole_test_setup_home installer-plan
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
    mkdir -p "$HOME/Downloads" "$HOME/Desktop" "$HOME/.config/mole" "$HOME/tmp"
    INSTALLER_TEST_TRASH_DIR=""
}

# Write $2 bytes to the installer fixture $1 (relative to HOME).
make_installer() {
    mkdir -p "$(dirname "$HOME/$1")"
    head -c "$2" /dev/zero > "$HOME/$1"
}

# Run `mo installer ARGS` with stdout and stderr apart, never on a terminal.
run_installer() {
    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="${INSTALLER_TEST_TRASH_DIR:-$HOME/test-trash}" \
        "$PROJECT_ROOT/mole" installer "$@" < /dev/null
    # Bats shows this only when the case fails.
    printf 'mo installer %s -> status %s\nstdout:\n%s\nstderr:\n%s\n' "$*" "$status" "$output" \
        "$(printf '%s\n' "$stderr" | tail -n 15)"
}

# Preview the fixtures as a plan: $HOME/plan.json and PLAN_ID.
make_plan() {
    run_installer --dry-run --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" > "$HOME/plan.json"
    PLAN_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$HOME/plan.json")
    [[ "$PLAN_ID" =~ ^[0-9a-f]{16}$ ]]
}

# Print the id of the plan item whose path is $1.
plan_item_id() {
    python3 - "$HOME/plan.json" "$1" << 'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for section in plan["sections"]:
    for item in section["items"]:
        if item.get("path") == sys.argv[2]:
            print(item["id"])
            sys.exit(0)
sys.exit(1)
PY
}

oplog() {
    cat "$HOME/Library/Logs/mole/operations.log" 2> /dev/null || true
}

@test "installer --dry-run --json prints only a JSON plan of the files the scan finds" {
    make_installer Downloads/App.dmg 3000
    make_installer "Desktop/Tool Setup.pkg" 5
    make_installer Downloads/sub/Deep.iso 70
    make_installer Downloads/notes.txt 10

    make_plan || return 1
    [[ "$stderr" == *"DRY RUN MODE"* && "$stderr" == *"expires in one hour"* ]] || return 1
    python3 - "$HOME/plan.json" "$HOME" << 'PY'
import json, sys
from datetime import datetime
plan = json.load(open(sys.argv[1]))
home = sys.argv[2]
assert plan["schema"] == 1 and plan["command"] == "installer", plan
fmt = "%Y-%m-%dT%H:%M:%SZ"
created = datetime.strptime(plan["created_at"], fmt)
expires = datetime.strptime(plan["expires_at"], fmt)
assert (expires - created).total_seconds() == 3600, plan
assert plan["skipped"] == [], plan["skipped"]
items = {}
for section in plan["sections"]:
    assert section["items"], section
    assert section["bytes"] == sum(i["bytes"] for i in section["items"]), section
    for item in section["items"]:
        for key in ("id", "kind", "path", "bytes", "size_known", "count", "covered_by", "default_selected",
                    "type", "name"):
            assert key in item, (key, item)
        assert item["kind"] == "path" and item["count"] == 1 and item["covered_by"] is None, item
        # The menu starts with nothing ticked.
        assert item["default_selected"] is False and item["size_known"] is True, item
        if item["path"].startswith(home + "/"):
            items[item["path"]] = (section["name"], item)
assert sorted(items) == sorted(f"{home}/{p}" for p in
                               ("Downloads/App.dmg", "Desktop/Tool Setup.pkg", "Downloads/sub/Deep.iso")), items
section, app = items[f"{home}/Downloads/App.dmg"]
assert section == "Downloads" and app["bytes"] == 3000 and app["type"] == "dmg" and app["name"] == "App.dmg", app
section, tool = items[f"{home}/Desktop/Tool Setup.pkg"]
assert section == "Desktop" and tool["bytes"] == 5 and tool["type"] == "pkg", tool
assert items[f"{home}/Downloads/sub/Deep.iso"][1]["type"] == "iso"
assert plan["total_bytes"] == sum(s["bytes"] for s in plan["sections"]), plan
PY
    local plans="$HOME/.config/mole/plans"
    [ "$(/usr/bin/stat -f %Lp "$plans")" = "700" ] || return 1
    [ "$(/usr/bin/stat -f %Lp "$plans/$PLAN_ID.ledger")" = "600" ] || return 1
    # A dry run removes nothing.
    [ -f "$HOME/Downloads/App.dmg" ] && [ -f "$HOME/Desktop/Tool Setup.pkg" ]
}

# shellcheck disable=SC2030 # Bats runs each test in its own subshell.
@test "installer --apply removes only the kept files and a repeat is a no-op" {
    make_installer Downloads/App.dmg 3000
    make_installer Downloads/Other.pkg 4000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1

    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Reviewed plan $PLAN_ID · "*" items kept"* ]] || return 1
    [ ! -e "$HOME/Downloads/App.dmg" ] || return 1
    # The unticked sibling stays and is never handed to a sink.
    [ -f "$HOME/Downloads/Other.pkg" ] || return 1
    oplog | grep -F "REMOVED $HOME/Downloads/App.dmg" > /dev/null || return 1
    if oplog | grep -F "$HOME/Downloads/Other.pkg" > /dev/null; then
        return 1
    fi

    # The same request again: nothing left to remove, nothing else touched.
    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"~/Downloads/App.dmg already removed"* ]] || return 1
    [ -f "$HOME/Downloads/Other.pkg" ]
}

# The stdout lines naming a run, and the one id they carry.
run_id_lines() {
    # shellcheck disable=SC2031 # output comes from run_installer in the calling test.
    printf '%s\n' "$output" | grep -c '^Run id: ' || true
}

@test "installer --apply prints its run id once and the log rows carry it" {
    make_installer Downloads/App.dmg 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1

    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ "$(run_id_lines)" -eq 1 ] || return 1
    local id
    id=$(printf '%s\n' "$output" | sed -n 's/^Run id: //p')
    [[ "$id" =~ ^[0-9]+-[0-9]+-[0-9]+-[0-9]+$ ]] || return 1
    oplog | grep -F "[installer run=$id] REMOVED $HOME/Downloads/App.dmg" > /dev/null || return 1
    oplog | grep -F "# ========== installer run=$id session started" > /dev/null || return 1
    oplog | grep -E "# ========== installer run=$id session ended at .*, 1 items," > /dev/null
}

@test "installer prints no run id outside --apply or with the log disabled" {
    make_installer Downloads/App.dmg 3000
    run_installer --dry-run
    [ "$(run_id_lines)" -eq 0 ] || return 1
    run_installer --dry-run --json
    [ "$(run_id_lines)" -eq 0 ] || return 1
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1
    MO_NO_OPLOG=1 run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ "$(run_id_lines)" -eq 0 ]
}

@test "installer writes a session marker pair on every exit path and names a dry run" {
    # Nothing found.
    run_installer
    [ "$status" -eq 0 ] || return 1
    [ "$(oplog | grep -c '# ========== installer run=.* session started')" -eq 1 ] || return 1
    [ "$(oplog | grep -c '# ========== installer run=.* session ended at .*, 0 items, 0B')" -eq 1 ] || return 1

    # A dry run, text and JSON, is a preview session.
    make_installer Downloads/App.dmg 3000
    run_installer --dry-run
    [ "$status" -eq 0 ] || return 1
    run_installer --dry-run --json
    [ "$status" -eq 0 ] || return 1
    [ "$(oplog | grep -c '# ========== installer-dry-run run=.* session started')" -eq 2 ] || return 1
    [ "$(oplog | grep -c '# ========== installer-dry-run run=.* session ended')" -eq 2 ] || return 1

    # An error exit after the session began still closes it: a failing scan
    # ends the JSON preview through `exit`, and only the EXIT trap can end it.
    mkdir -p "$HOME/bin"
    printf '#!/bin/sh\necho "fd: boom" >&2\nexit 2\n' > "$HOME/bin/fd"
    chmod +x "$HOME/bin/fd"
    mkdir -p "$HOME/Library/Logs/mole"
    : > "$HOME/Library/Logs/mole/operations.log"
    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 PATH="$HOME/bin:$PATH" \
        "$PROJECT_ROOT/mole" installer --dry-run --json < /dev/null
    [ "$status" -ne 0 ] || return 1
    local id
    id=$(oplog | sed -n 's/^# ========== installer-dry-run run=\([^ ]*\) session started.*/\1/p')
    [[ "$id" =~ ^[0-9]+-[0-9]+-[0-9]+-[0-9]+$ ]] || return 1
    oplog | grep -F "# ========== installer-dry-run run=$id session started" > /dev/null || return 1
    oplog | grep -F "# ========== installer-dry-run run=$id session ended" > /dev/null
}

@test "mo history shows an installer session with its run id next to marker-less installer rows" {
    mkdir -p "$HOME/Library/Logs/mole"
    printf '%s\n' '[2026-05-02 10:00:01] [installer] TRASHED /tmp/old.dmg (1KB)' \
        > "$HOME/Library/Logs/mole/operations.log"
    make_installer Downloads/App.dmg 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1
    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    local id
    id=$(printf '%s\n' "$output" | sed -n 's/^Run id: //p')
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" | python3 -c '
import json, sys
id = sys.argv[1]
s = [x for x in json.load(sys.stdin)["sessions"] if x["command"] == "installer"]
mine = [x for x in s if x["run_id"] == id]
assert len(mine) == 1 and mine[0]["items"] == 1, s
assert any(x["run_id"] == "" for x in s), s
' "$id"
}

@test "installer --apply refuses an unknown, expired or cross-command plan and an id not in it" {
    make_installer Downloads/App.dmg 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1
    local plans="$HOME/.config/mole/plans"
    local plan="$plans/$PLAN_ID.ledger"
    cp "$plan" "$HOME/plan.orig"

    run_installer --apply 00000000000000ff --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"mo installer: no plan 00000000000000ff"* && "$stderr" == *"mo installer --dry-run --json"* ]] || return 1

    run_installer --apply ../../etc --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"is not a plan id"* ]] || return 1

    # Header field 2 is the creation time.
    python3 - "$HOME/plan.orig" "$plan" "$(($(date +%s) - 7200))" << 'PY'
import sys
data = open(sys.argv[1], "rb").read().split(b"\0")
data[2] = sys.argv[3].encode()
open(sys.argv[2], "wb").write(b"\0".join(data))
PY
    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"expired at"* && "$stderr" == *"review the new plan"* ]] || return 1
    oplog | grep -F "SKIPPED $plan (plan expired)" > /dev/null || return 1
    cp "$HOME/plan.orig" "$plan"

    # Clean and purge plans naming the same file are refused by installer.
    local devino
    devino=$(/usr/bin/stat -f %d:%i "$HOME/Downloads/App.dmg")
    printf '%s\0' MOLEPLAN 1 "$(date +%s)" "$(id -u)" clean \
        P i1 "User essentials" "$HOME/Downloads/App.dmg" "$devino" 4 1 true "" "" \
        END > "$plans/00000000000000c1.ledger"
    printf '%s\0' MOLEPLAN 1 "$(date +%s)" "$(id -u)" purge \
        A i1 Downloads "$HOME/Downloads/App.dmg" "$devino" 4 1 true "" dist 14 \
        idle true false old "$HOME/Downloads" x "$HOME" x x x x x x x \
        END > "$plans/00000000000000c2.ledger"
    chmod 600 "$plans/00000000000000c1.ledger" "$plans/00000000000000c2.ledger"
    printf 'i1\n' > "$HOME/other-select.txt"
    local other
    for other in clean:00000000000000c1 purge:00000000000000c2; do
        run_installer --apply "${other#*:}" --select "$HOME/other-select.txt"
        [ "$status" -eq 1 ] || return 1
        [[ "$stderr" == *"was made by 'mo ${other%%:*} --dry-run --json', not by mo installer"* ]] || return 1
        [[ "$stderr" == *"mo ${other%%:*} --apply ${other#*:}"* ]] || return 1
        oplog | grep -F "SKIPPED $plans/${other#*:}.ledger (plan of another command)" > /dev/null || return 1
    done

    # This installer plan is refused by clean and by purge.
    local command
    for command in clean purge; do
        run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 \
            "$PROJECT_ROOT/mole" "$command" --apply "$PLAN_ID" --select "$HOME/select.txt" < /dev/null
        [ "$status" -eq 1 ] || return 1
        [[ "$stderr" == *"was made by 'mo installer --dry-run --json', not by mo $command"* ]] || return 1
    done

    printf 'i999\n' > "$HOME/bad-select.txt"
    run_installer --apply "$PLAN_ID" --select "$HOME/bad-select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"'i999', which is not an item of plan $PLAN_ID"* ]] || return 1

    # Every refusal left the file alone; the restored plan still applies.
    [ -f "$HOME/Downloads/App.dmg" ] || return 1
    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$HOME/Downloads/App.dmg" ]
}

@test "installer --apply keeps a file replaced since review" {
    make_installer Downloads/App.dmg 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1

    # Same path, same size, new inode.
    mv "$HOME/Downloads/App.dmg" "$HOME/Downloads/App.reviewed"
    make_installer Downloads/App.dmg 3000

    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/Downloads/App.dmg" ] && [ -f "$HOME/Downloads/App.reviewed" ] || return 1
    [[ "$output" == *"Skipped ~/Downloads/App.dmg (changed since review; run mo installer --dry-run --json again"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/Downloads/App.dmg (changed since review)" > /dev/null
}

@test "installer --apply keeps a file whose size changed since review" {
    make_installer Downloads/App.dmg 3000
    # A fixed mtime, restored after the write, leaves only the size changed.
    touch -t 202001010000 "$HOME/Downloads/App.dmg"
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1
    local devino
    devino=$(/usr/bin/stat -f %d:%i "$HOME/Downloads/App.dmg")
    printf 'more' >> "$HOME/Downloads/App.dmg"
    touch -t 202001010000 "$HOME/Downloads/App.dmg"
    [ "$(/usr/bin/stat -f %d:%i "$HOME/Downloads/App.dmg")" = "$devino" ] || return 1

    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ "$(/usr/bin/stat -f %z "$HOME/Downloads/App.dmg")" = "3004" ] || return 1
    [[ "$output" == *"Skipped ~/Downloads/App.dmg (changed since review;"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/Downloads/App.dmg (changed since review)" > /dev/null
}

@test "installer --apply keeps a file whose folder is no longer scanned" {
    make_installer Downloads/sub/Deep.dmg 3000
    make_installer Downloads/App.dmg 3000
    make_installer Elsewhere/Planted.dmg 3000
    make_plan || return 1
    {
        plan_item_id "$HOME/Downloads/sub/Deep.dmg"
        plan_item_id "$HOME/Downloads/App.dmg"
    } > "$HOME/select.txt" || return 1
    # Point App.dmg's record, identity and all, at a file in a folder
    # installer never scans: the plan gives no authority beyond those folders.
    local plan="$HOME/.config/mole/plans/$PLAN_ID.ledger"
    python3 - "$plan" "$HOME/Downloads/App.dmg" "$HOME/Elsewhere/Planted.dmg" << 'PY'
import os, sys
data = open(sys.argv[1], "rb").read()
fields = data.split(b"\0")
target = sys.argv[3]
st = os.stat(target)
parent = os.path.realpath(os.path.dirname(target))
pst = os.stat(parent)
i = fields.index(sys.argv[2].encode())
# path, devino, then (after size, count, known, covered, type, aux count)
# bytes, identity, scan folder, parent, parent dev:inode.
fields[i] = target.encode()
fields[i + 1] = f"{st.st_dev}:{st.st_ino}".encode()
fields[i + 8] = str(st.st_size).encode()
fields[i + 9] = f"{st.st_dev}:{st.st_ino}:{int(st.st_mtime)}".encode()
fields[i + 11] = parent.encode()
fields[i + 12] = f"{pst.st_dev}:{pst.st_ino}".encode()
open(sys.argv[1], "wb").write(b"\0".join(fields))
PY

    # Deep.dmg sits two levels down; a scan one level deep no longer reaches it.
    MOLE_INSTALLER_SCAN_MAX_DEPTH=1 run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/Downloads/sub/Deep.dmg" ] && [ -f "$HOME/Elsewhere/Planted.dmg" ] || return 1
    [ -f "$HOME/Downloads/App.dmg" ] || return 1
    [[ "$output" == *"no longer one mo installer scans; run mo installer --dry-run --json again"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/Downloads/sub/Deep.dmg (outside installer folders)" > /dev/null || return 1
    oplog | grep -F "SKIPPED $HOME/Elsewhere/Planted.dmg (outside installer folders)" > /dev/null
}

@test "installer --apply accepts a file another scan folder still reaches" {
    # Found under ~/Downloads at depth 2 and under ~/Downloads/Telegram
    # Desktop at depth 1; the plan records the first.
    make_installer "Downloads/Telegram Desktop/Chat.dmg" 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/Telegram Desktop/Chat.dmg" > "$HOME/select.txt" || return 1

    MOLE_INSTALLER_SCAN_MAX_DEPTH=1 run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$HOME/Downloads/Telegram Desktop/Chat.dmg" ] || return 1
    oplog | grep -F "REMOVED $HOME/Downloads/Telegram Desktop/Chat.dmg" > /dev/null
}

@test "installer --apply --trash moves kept files to the Trash and logs TRASHED" {
    make_installer Downloads/App.dmg 3000
    make_installer Downloads/Other.pkg 4000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1

    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt" --trash
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"to Trash"* && "$output" == *"installers to the Trash"* ]] || return 1
    [ ! -e "$HOME/Downloads/App.dmg" ] || return 1
    [ -n "$(find "$HOME/test-trash" -maxdepth 1 -name 'App.dmg.*' -type f)" ] || return 1
    [ -f "$HOME/Downloads/Other.pkg" ] || return 1
    oplog | grep -F "TRASHED $HOME/Downloads/App.dmg" > /dev/null || return 1
    if oplog | grep -F "REMOVED $HOME/Downloads/App.dmg" > /dev/null; then
        return 1
    fi
    # The deletions log names the same Trash move.
    local deletions="$HOME/Library/Logs/mole/deletions.log"
    grep -F "$(printf '\ttrash\t')" "$deletions" | grep -F "$(printf '\tok\t%s' "$HOME/Downloads/App.dmg")" > /dev/null || return 1
    if grep -F "$(printf '\tpermanent\t')" "$deletions" | grep -F "$HOME/Downloads/App.dmg" > /dev/null; then
        return 1
    fi
}

@test "installer --apply --trash names a failed Trash move and keeps the file" {
    make_installer Downloads/App.dmg 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1
    # A file where the Trash folder should be makes every move fail.
    printf 'x\n' > "$HOME/blocker"

    INSTALLER_TEST_TRASH_DIR="$HOME/blocker/trash"
    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt" --trash
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/Downloads/App.dmg" ] || return 1
    [[ "$output" == *"could not move to Trash; run without --trash"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/Downloads/App.dmg (trash-failed)" > /dev/null || return 1
    # The sink's row is the only one.
    [ "$(oplog | grep -c -F "SKIPPED $HOME/Downloads/App.dmg")" -eq 1 ]
}

@test "installer --apply --trash names a timed-out Trash move once and keeps the file" {
    make_installer Downloads/App.dmg 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/App.dmg" > "$HOME/select.txt" || return 1
    # The test Trash move is an mv into the test Trash; this one times out.
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/mv" << EOF
#!/bin/sh
case "\$*" in *"$HOME/test-trash/"*) exit 124 ;; esac
exec /bin/mv "\$@"
EOF
    chmod +x "$HOME/bin/mv"

    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 PATH="$HOME/bin:$PATH" \
        MOLE_TEST_TRASH_DIR="$HOME/test-trash" "$PROJECT_ROOT/mole" installer \
        --apply "$PLAN_ID" --select "$HOME/select.txt" --trash < /dev/null
    [ "$status" -ne 0 ] || return 1
    [ -f "$HOME/Downloads/App.dmg" ] || return 1
    [[ "$output" == *"Skipped ~/Downloads/App.dmg (the move to the Trash timed out; run the same mo installer --apply again"* ]] || return 1
    [[ "$output" == *"App.dmg (move to Trash timed out)"* ]] || return 1
    [[ "$output" == *"The move to the Trash timed out, so later selections were left in place"* ]] || return 1
    [[ "$output" != *"delete failed"* ]] || return 1
    oplog | grep -F "FAILED $HOME/Downloads/App.dmg (move to Trash timed out)" > /dev/null || return 1
    # The sink's row is the only one.
    [ "$(oplog | grep -c -F " $HOME/Downloads/App.dmg (")" -eq 1 ]
}

@test "installer --dry-run --json lists a file whose identity cannot be read as skipped" {
    make_installer Downloads/App.dmg 3000

    # shellcheck disable=SC2016 # The child shell evaluates this script.
    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1
        source "$1"
        exec 7>&1 1>&2
        # The second file went away between the scan and the identity read.
        INSTALLER_PATHS=("$2" "$3")
        INSTALLER_SIZES=(3000 5)
        INSTALLER_SOURCES=(Downloads Downloads)
        installer_plan_collect
        clean_plan_emit_json
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads/App.dmg" "$HOME/Downloads/Gone.dmg"
    [ "$status" -eq 0 ] || return 1
    python3 - "$output" "$HOME" << 'PY'
import json, sys
plan = json.loads(sys.argv[1])
home = sys.argv[2]
paths = [i["path"] for s in plan["sections"] for i in s["items"]]
assert paths == [f"{home}/Downloads/App.dmg"], paths
assert plan["skipped"] == [{"section": "Downloads", "name": f"{home}/Downloads/Gone.dmg",
                            "reason": "could not inspect"}], plan["skipped"]
PY
}

@test "installer --trash sends the confirmed menu selection to the Trash" {
    make_installer Downloads/First.dmg 3

    # shellcheck disable=SC2016 # The child shell evaluates this script.
    run env HOME="$HOME" TERM="xterm-256color" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$HOME/test-trash"
        export MOLE_DELETE_LOG="$HOME/deletions.log"
        source "$1"
        MOLE_CLEAN_TRASH=1
        INSTALLER_PATHS=("$2")
        INSTALLER_SIZES=(3)
        MOLE_SELECTION_RESULT="0"
        delete_selected_installers < <(printf "\n")
        show_summary
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads/First.dmg"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Move 1 installers to the Trash"* && "$output" == *"installers to the Trash"* ]] || return 1
    [ ! -e "$HOME/Downloads/First.dmg" ] || return 1
    [ -n "$(find "$HOME/test-trash" -maxdepth 1 -name 'First.dmg.*' -type f)" ] || return 1
    oplog | grep -F "TRASHED $HOME/Downloads/First.dmg" > /dev/null
}

@test "installer refuses flag combinations the reviewable run does not support" {
    run_installer --json
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"needs --dry-run"* && "$stderr" == *"mo installer --dry-run --json"* ]] || return 1

    run_installer --select "$HOME/s.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"--select needs --apply"* ]] || return 1

    run_installer --apply 0123456789abcdef
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"--apply needs --select"* ]] || return 1

    run_installer --dry-run --apply 0123456789abcdef --select "$HOME/s.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"cannot be combined with --dry-run"* ]] || return 1

    run_installer --dry-run --trash
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"a dry run removes nothing"* ]] || return 1

    run_installer --apply
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Missing plan id for --apply"* ]]
}

@test "installer --help lists the reviewable flags" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" installer --help
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"--json"* && "$output" == *"--apply ID --select FILE"* && "$output" == *"--trash"* ]]
}

@test "installer --dry-run --json prints an error document when the scan fails" {
    make_installer Downloads/App.dmg 3000
    # An fd that fails with a diagnostic other than a permission refusal.
    mkdir -p "$HOME/bin"
    printf '#!/bin/sh\necho "fd: boom" >&2\nexit 2\n' > "$HOME/bin/fd"
    chmod +x "$HOME/bin/fd"

    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 PATH="$HOME/bin:$PATH" \
        "$PROJECT_ROOT/mole" installer --dry-run --json < /dev/null
    [ "$status" -ne 0 ] || return 1
    python3 - "$output" << 'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["command"] == "installer" and doc["schema"] == 1, doc
assert doc["error"]["code"] == "incomplete", doc
assert "plan_id" not in doc
PY
    [[ "$stderr" == *"No plan was saved"* ]] || return 1
    [ -z "$(ls "$HOME/.config/mole/plans" 2> /dev/null)" ]
}

# Source bin/installer.sh with its real traps, then end the run the way a
# scan does: by a signal ($1 = TERM) or by an exit status ($1 = a number).
run_json_trap() {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 ENDING="$1" \
        /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/bin/installer.sh"
exec 7>&1 1>&2
CLEAN_PLAN_JSON_PENDING=true
if [[ "$ENDING" == "TERM" ]]; then
    kill -TERM $$
    sleep 5
fi
exit "$ENDING"
SCRIPT
}

@test "installer --dry-run --json prints a cancelled or incomplete document from its real traps" {
    run_json_trap TERM
    [ "$status" -eq 130 ] || return 1
    [[ "$output" == *'{"schema":1,"command":"installer","error":{"code":"cancelled",'* ]] || return 1

    run_json_trap 130
    [ "$status" -eq 130 ] || return 1
    [[ "$output" == *'"error":{"code":"cancelled",'* ]] || return 1

    run_json_trap 1
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *'{"schema":1,"command":"installer","error":{"code":"incomplete",'* ]]
}

@test "installer --apply keeps a file whose folder was renamed since review" {
    make_installer Downloads/sub/App.dmg 3000
    make_plan || return 1
    plan_item_id "$HOME/Downloads/sub/App.dmg" > "$HOME/select.txt" || return 1
    mv "$HOME/Downloads/sub" "$HOME/Downloads/sub-old"

    run_installer --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" != *"already removed"* ]] || return 1
    [ -f "$HOME/Downloads/sub-old/App.dmg" ] || return 1
    oplog | grep -F "SKIPPED $HOME/Downloads/sub/App.dmg (changed since review)" > /dev/null
}
