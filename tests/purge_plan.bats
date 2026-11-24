#!/usr/bin/env bats
# Reviewable purge: `mo purge --dry-run --json`, `--apply <plan_id> --select
# <file>` and `--trash`. Every case runs the real `mo purge` in a temp HOME
# whose only purge path is $HOME/www; only kept fixture artifacts may change.

bats_require_minimum_version 1.5.0

load helpers/common

setup_file() {
    mole_test_setup_home purge-plan
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
}

# A project under ~/www with one `dist` artifact holding $3 bytes. An `old`
# artifact was last touched in 2020; a `new` one now (recent activity).
make_artifact() {
    local project="$HOME/www/$1"
    mkdir -p "$project/dist"
    touch "$project/package.json"
    head -c "$3" /dev/zero > "$project/dist/blob.bin"
    if [[ "$2" == "old" ]]; then
        touch -t 202001010000 "$project/dist/blob.bin" "$project/dist" "$project/package.json"
    fi
}

# Run `mo purge ARGS` with stdout and stderr apart, never on a terminal.
run_purge() {
    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="${PURGE_TEST_TRASH_DIR:-$HOME/test-trash}" "$PROJECT_ROOT/mole" purge "$@" < /dev/null
    # Bats shows this only when the case fails.
    printf 'mo purge %s -> status %s\nstdout:\n%s\nstderr:\n%s\n' "$*" "$status" "$output" \
        "$(printf '%s\n' "$stderr" | tail -n 15)"
}

# Preview the fixtures as a plan: $HOME/plan.json and PLAN_ID.
make_plan() {
    run_purge --dry-run --json
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

@test "purge --dry-run --json prints only a JSON plan of the same artifacts the text preview lists" {
    make_artifact alpha old 8192
    make_artifact beta old 4096
    make_artifact gamma new 4096

    run_purge --dry-run
    [ "$status" -eq 0 ] || return 1
    local text_preview="$output"
    [[ "$text_preview" == *"[DRY RUN] ~/www/alpha/dist"* ]] || return 1

    make_plan || return 1
    [[ "$stderr" == *"DRY RUN MODE"* ]] || return 1
    python3 - "$HOME/plan.json" "$HOME" << 'PY'
import json, sys
from datetime import datetime
plan = json.load(open(sys.argv[1]))
home = sys.argv[2]
assert plan["schema"] == 1 and plan["command"] == "purge", plan
fmt = "%Y-%m-%dT%H:%M:%SZ"
created = datetime.strptime(plan["created_at"], fmt)
expires = datetime.strptime(plan["expires_at"], fmt)
assert (expires - created).total_seconds() == 3600, plan
assert plan["skipped"] == [], plan["skipped"]
items = {}
for section in plan["sections"]:
    assert section["items"], section
    for item in section["items"]:
        for key in ("id", "kind", "path", "bytes", "size_known", "count", "covered_by", "default_selected"):
            assert key in item, (key, item)
        assert item["kind"] == "path" and item["count"] == 1 and item["covered_by"] is None, item
        assert section["name"] == "~/www/" + item["path"].split("/")[-2], (section, item)
        items[item["path"]] = item
assert sorted(items) == sorted(f"{home}/www/{p}/dist" for p in ("alpha", "beta", "gamma")), items
assert items[f"{home}/www/alpha/dist"]["default_selected"] is True
assert items[f"{home}/www/beta/dist"]["default_selected"] is True
# Recent activity: listed, but not pre-selected, as in the menu.
assert items[f"{home}/www/gamma/dist"]["default_selected"] is False
assert items[f"{home}/www/alpha/dist"]["bytes"] >= 8192
assert plan["total_bytes"] == sum(s["bytes"] for s in plan["sections"])
PY
    # The text preview removes exactly the pre-selected rows.
    [[ "$text_preview" == *"[DRY RUN] ~/www/beta/dist"* ]] || return 1
    [[ "$text_preview" != *"[DRY RUN] ~/www/gamma/dist"* ]] || return 1

    local plans="$HOME/.config/mole/plans"
    [ "$(/usr/bin/stat -f %Lp "$plans")" = "700" ] || return 1
    [ "$(/usr/bin/stat -f %Lp "$plans/$PLAN_ID.ledger")" = "600" ] || return 1
    # A dry run removes nothing.
    [ -f "$HOME/www/alpha/dist/blob.bin" ] && [ -f "$HOME/www/gamma/dist/blob.bin" ]
}

@test "purge --apply removes only the kept artifacts and a repeat is a no-op" {
    make_artifact alpha old 8192
    make_artifact beta old 4096
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Reviewed plan $PLAN_ID · 1 of 2 items kept"* ]] || return 1
    [ ! -e "$HOME/www/alpha/dist" ] || return 1
    # The unticked sibling stays, and so does the project around the artifact.
    [ -f "$HOME/www/beta/dist/blob.bin" ] || return 1
    [ -f "$HOME/www/alpha/package.json" ] || return 1
    oplog | grep -F "REMOVED $HOME/www/alpha/dist" > /dev/null || return 1
    if oplog | grep -F "$HOME/www/beta/dist" > /dev/null; then
        return 1
    fi

    # The same request again: nothing left to remove, nothing else touched.
    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"~/www/alpha/dist already removed"* ]] || return 1
    [ -f "$HOME/www/beta/dist/blob.bin" ]
}

@test "purge --apply refuses an unknown, expired or cross-command plan and an id not in it" {
    make_artifact alpha old 8192
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1
    local plans="$HOME/.config/mole/plans"
    local plan="$plans/$PLAN_ID.ledger"
    cp "$plan" "$HOME/plan.orig"

    run_purge --apply 00000000000000ff --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"mo purge: no plan 00000000000000ff"* && "$stderr" == *"mo purge --dry-run --json"* ]] || return 1

    run_purge --apply ../../etc --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"is not a plan id"* ]] || return 1

    # Header field 2 is the creation time.
    python3 - "$HOME/plan.orig" "$plan" "$(($(date +%s) - 7200))" << 'PY'
import sys
data = open(sys.argv[1], "rb").read().split(b"\0")
data[2] = sys.argv[3].encode()
open(sys.argv[2], "wb").write(b"\0".join(data))
PY
    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"expired at"* && "$stderr" == *"review the new plan"* ]] || return 1
    oplog | grep -F "SKIPPED $plan (plan expired)" > /dev/null || return 1
    cp "$HOME/plan.orig" "$plan"

    # A clean plan is refused by purge, and this purge plan by clean.
    local clean_plan="$plans/00000000000000c1.ledger"
    printf '%s\0' MOLEPLAN 1 "$(date +%s)" "$(id -u)" clean \
        P i1 "User essentials" "$HOME/www/alpha/dist" "$(/usr/bin/stat -f %d:%i "$HOME/www/alpha/dist")" 8 1 true "" "" \
        END > "$clean_plan"
    chmod 600 "$clean_plan"
    printf 'i1\n' > "$HOME/clean-select.txt"
    run_purge --apply 00000000000000c1 --select "$HOME/clean-select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"was made by 'mo clean --dry-run --json', not by mo purge"* ]] || return 1
    [[ "$stderr" == *"mo clean --apply 00000000000000c1"* ]] || return 1
    oplog | grep -F "SKIPPED $clean_plan (plan of another command)" > /dev/null || return 1

    run --separate-stderr env HOME="$HOME" TMPDIR="$HOME/tmp" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" clean --apply "$PLAN_ID" --select "$HOME/select.txt" < /dev/null
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"was made by 'mo purge --dry-run --json', not by mo clean"* ]] || return 1

    printf 'i999\n' > "$HOME/bad-select.txt"
    run_purge --apply "$PLAN_ID" --select "$HOME/bad-select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"'i999', which is not an item of plan $PLAN_ID"* ]] || return 1

    printf '\n \n' > "$HOME/empty-select.txt"
    run_purge --apply "$PLAN_ID" --select "$HOME/empty-select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"lists no items"* && "$stderr" == *"List the item ids to purge"* ]] || return 1

    # Every refusal left the artifact alone; the restored plan still applies.
    [ -f "$HOME/www/alpha/dist/blob.bin" ] || return 1
    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$HOME/www/alpha/dist" ]
}

@test "purge --apply keeps an artifact replaced since review" {
    make_artifact alpha old 8192
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1

    # Same path, new inode.
    mv "$HOME/www/alpha/dist" "$HOME/www/alpha/dist.reviewed"
    mkdir "$HOME/www/alpha/dist"
    printf 'new\n' > "$HOME/www/alpha/dist/new.txt"
    touch -t 202001010000 "$HOME/www/alpha/dist/new.txt" "$HOME/www/alpha/dist"

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/www/alpha/dist/new.txt" ] || return 1
    [ -f "$HOME/www/alpha/dist.reviewed/blob.bin" ] || return 1
    [[ "$output" == *"Kept · 1 item: ~/www/alpha/dist (changed since review)"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/alpha/dist (changed since review)" > /dev/null
}

@test "purge --apply keeps an artifact that is in use or was modified since review" {
    make_artifact alpha old 8192
    make_artifact beta old 4096
    make_plan || return 1
    {
        plan_item_id "$HOME/www/alpha/dist"
        plan_item_id "$HOME/www/beta/dist"
    } > "$HOME/select.txt" || return 1

    # alpha is held open by another process; beta gained a fresh file.
    (
        cd /
        exec 9< "$HOME/www/alpha/dist/blob.bin"
        exec sleep 30
    ) &
    local holder=$!
    sleep 0.3
    printf 'fresh\n' > "$HOME/www/beta/dist/fresh.js"

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/www/alpha/dist/blob.bin" ] || return 1
    [ -f "$HOME/www/beta/dist/blob.bin" ] || return 1
    oplog | grep -F "SKIPPED $HOME/www/alpha/dist (in use)" > /dev/null || return 1
    oplog | grep -F "SKIPPED $HOME/www/beta/dist (modified since review)" > /dev/null || return 1
    [[ "$output" == *"Kept · 2 items:"* ]]
}

@test "purge --apply --trash moves kept artifacts to the Trash and logs TRASHED" {
    make_artifact alpha old 8192
    make_artifact beta old 4096
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt" --trash
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"to Trash"* && "$output" == *"Moved to Trash"* ]] || return 1
    [ ! -e "$HOME/www/alpha/dist" ] || return 1
    local moved
    moved=$(find "$HOME/test-trash" -maxdepth 1 -name 'dist.*' -type d | head -1)
    [[ -n "$moved" && -f "$moved/blob.bin" ]] || return 1
    [ -f "$HOME/www/beta/dist/blob.bin" ] || return 1
    oplog | grep -F "TRASHED $HOME/www/alpha/dist" > /dev/null || return 1
    if oplog | grep -F "REMOVED $HOME/www/alpha/dist" > /dev/null; then
        return 1
    fi
}

@test "purge --trash --yes moves the pre-selected artifacts to the Trash" {
    make_artifact alpha old 8192
    make_artifact gamma new 4096

    run_purge --trash --yes
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$HOME/www/alpha/dist" ] || return 1
    [ -n "$(find "$HOME/test-trash" -maxdepth 1 -name 'dist.*' -type d)" ] || return 1
    [ -f "$HOME/www/gamma/dist/blob.bin" ] || return 1
    oplog | grep -F "TRASHED $HOME/www/alpha/dist" > /dev/null
}

@test "purge refuses flag combinations the reviewable purge does not support" {
    run_purge --json
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"needs --dry-run"* && "$stderr" == *"mo purge --dry-run --json"* ]] || return 1

    run_purge --select "$HOME/s.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"--select needs --apply"* ]] || return 1

    run_purge --apply 0123456789abcdef
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"--apply needs --select"* ]] || return 1

    run_purge --dry-run --apply 0123456789abcdef --select "$HOME/s.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"cannot be combined with --dry-run"* ]] || return 1

    run_purge --dry-run --trash
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"a dry run removes nothing"* ]] || return 1

    run_purge --apply
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Missing plan id for --apply"* ]]
}

@test "purge --help lists the reviewable purge flags" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" purge --help
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"--json"* && "$output" == *"--apply ID --select FILE"* && "$output" == *"--trash"* ]]
}

@test "purge --dry-run --json prints an error document when a scan root does not finish" {
    make_artifact alpha old 8192
    mkdir -p "$HOME/locked/project"
    printf '%s\n' "$HOME/www" "$HOME/locked" > "$HOME/.config/mole/purge_paths"
    chmod 000 "$HOME/locked"

    run_purge --dry-run --json
    chmod 755 "$HOME/locked"
    [ "$status" -ne 0 ] || return 1
    python3 - "$output" << 'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["command"] == "purge" and doc["schema"] == 1, doc
assert doc["error"]["code"] == "incomplete", doc
assert "plan_id" not in doc
PY
    [[ "$stderr" == *"no plan was saved"* ]] || return 1
    [ -z "$(ls "$HOME/.config/mole/plans" 2> /dev/null)" ]
}

# Source bin/purge.sh with its real traps, then end the run the way a scan
# does: by a signal ($1 = TERM) or by an exit status ($1 = a number).
run_json_trap() {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 ENDING="$1" \
        /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/bin/purge.sh"
exec 7>&1 1>&2
CLEAN_PLAN_JSON_PENDING=true
if [[ "$ENDING" == "TERM" ]]; then
    kill -TERM $$
    sleep 5
fi
exit "$ENDING"
SCRIPT
}

@test "purge --dry-run --json prints a cancelled or incomplete document from its real traps" {
    run_json_trap TERM
    [ "$status" -eq 130 ] || return 1
    [[ "$output" == *'{"schema":1,"command":"purge","error":{"code":"cancelled",'* ]] || return 1

    run_json_trap 130
    [ "$status" -eq 130 ] || return 1
    [[ "$output" == *'"error":{"code":"cancelled",'* ]] || return 1

    run_json_trap 1
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *'{"schema":1,"command":"purge","error":{"code":"incomplete",'* ]]
}

@test "purge --apply keeps an artifact whose project was renamed since review" {
    make_artifact alpha old 8192
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1
    mv "$HOME/www/alpha" "$HOME/www/alpha-old"

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" != *"already removed"* ]] || return 1
    [ -f "$HOME/www/alpha-old/dist/blob.bin" ] || return 1
    [[ "$output" == *"Kept · 1 item: ~/www/alpha/dist (changed since review)"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/alpha/dist (changed since review)" > /dev/null
}

@test "purge --apply keeps an artifact whose scan root was replaced since review" {
    make_artifact alpha old 8192
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1
    # The reviewed root moves away (an ejected disk, a renamed folder) and a
    # new, empty folder takes its path.
    mv "$HOME/www" "$HOME/www-reviewed"
    mkdir "$HOME/www"

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" != *"already removed"* ]] || return 1
    [ -f "$HOME/www-reviewed/alpha/dist/blob.bin" ] || return 1
    oplog | grep -F "SKIPPED $HOME/www/alpha/dist (scan root changed since review)" > /dev/null
}

@test "purge --apply --trash names a failed Trash move and keeps the artifact" {
    make_artifact alpha old 8192
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1
    # A file where the Trash folder should be makes every move fail.
    printf 'x\n' > "$HOME/blocker"

    PURGE_TEST_TRASH_DIR="$HOME/blocker/trash"
    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt" --trash
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/www/alpha/dist/blob.bin" ] || return 1
    [[ "$output" == *"could not move to Trash; run without --trash"* ]] || return 1
    [[ "$output" != *"final removal check failed"* ]] || return 1
    [[ "$output" == *"Kept · 1 item: ~/www/alpha/dist (could not move to Trash)"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/alpha/dist (trash-failed)" > /dev/null
}

@test "purge --apply keeps an artifact whitelisted since review" {
    make_artifact alpha old 8192
    make_artifact beta old 4096
    # A SwiftPM scratch root with dependencies is offered as its outputs; a
    # glob entry on the root gives those outputs no inheritance at the sink.
    local swift="$HOME/www/swiftpkg"
    # An index-build that resolved its own dependencies decomposes one level
    # further; its outputs are kept by the entry on the scratch root above it.
    local index_out="$swift/.build/index-build/arm64-apple-macosx"
    mkdir -p "$swift/.build/checkouts/dep/.git" "$swift/.build/out/Products" \
        "$swift/.build/index-build/checkouts/dep/.git" "$index_out"
    touch "$swift/Package.swift"
    printf '{}\n' > "$swift/.build/workspace-state.json"
    head -c 4096 /dev/zero > "$swift/.build/out/Products/app"
    head -c 4096 /dev/zero > "$index_out/index.db"
    touch -t 202001010000 "$swift/.build/out/Products/app" "$swift/.build/out/Products" "$swift/.build/out" \
        "$index_out/index.db" "$index_out" "$swift/Package.swift"
    make_plan || return 1
    {
        plan_item_id "$HOME/www/alpha/dist"
        plan_item_id "$HOME/www/beta/dist"
        plan_item_id "$swift/.build/out"
        plan_item_id "$index_out"
    } > "$HOME/select.txt" || return 1
    printf '%s\n' "$HOME/www/alpha/dist" "$HOME/www/*/.build" > "$HOME/.config/mole/whitelist"

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/www/alpha/dist/blob.bin" ] || return 1
    [ -f "$swift/.build/out/Products/app" ] || return 1
    [ -f "$index_out/index.db" ] || return 1
    [ ! -e "$HOME/www/beta/dist" ] || return 1
    [[ "$output" == *"Skipped ~/www/alpha/dist (whitelisted)"* ]] || return 1
    [[ "$output" == *"Skipped ~/www/swiftpkg/.build/out (whitelisted)"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/alpha/dist (whitelist)" > /dev/null || return 1
    oplog | grep -F "SKIPPED $swift/.build/out (whitelist)" > /dev/null
}

@test "purge --apply keeps an artifact whose scan root left purge paths since review" {
    make_artifact alpha old 8192
    make_plan || return 1
    plan_item_id "$HOME/www/alpha/dist" > "$HOME/select.txt" || return 1
    mkdir -p "$HOME/elsewhere"
    printf '%s\n' "$HOME/elsewhere" > "$HOME/.config/mole/purge_paths"

    run_purge --apply "$PLAN_ID" --select "$HOME/select.txt"
    [ "$status" -eq 1 ] || return 1
    [ -f "$HOME/www/alpha/dist/blob.bin" ] || return 1
    [[ "$output" == *"no longer a purge path; run mo purge --dry-run --json again"* ]] || return 1
    oplog | grep -F "SKIPPED $HOME/www/alpha/dist (outside purge paths)" > /dev/null
}
