#!/bin/bash
# Mole - Reviewable clean plans.
# `mo clean --dry-run --json` prints the preview as one JSON document and saves
# the same candidate ledger as a plan; `mo clean --apply <plan_id> --select
# <file>` cleans only the plan items the user kept. Mole reads the saved ledger
# back, never the JSON. The sinks in lib/core/file_ops.sh enforce the selection.

set -euo pipefail

readonly CLEAN_PLAN_SCHEMA=1
readonly CLEAN_PLAN_TTL_SEC=3600
readonly CLEAN_PLAN_MAGIC="MOLEPLAN"

CLEAN_PLAN_ID=""
# Set once `--json` has moved stdout to fd 7, cleared once a document starts.
CLEAN_PLAN_JSON_PENDING=false
CLEAN_PLAN_SAVE_FAILED=false
declare -a CLEAN_PLAN_SKIPPED_SECTIONS=()
declare -a CLEAN_PLAN_SKIPPED_NAMES=()
declare -a CLEAN_PLAN_SKIPPED_REASONS=()
declare -a CLEAN_APPLY_DESELECTED_PATHS=()
CLEAN_APPLY_KEPT_COUNT=0
CLEAN_APPLY_ITEM_COUNT=0

# Records read back from a plan file by _clean_plan_read.
CLEAN_PLAN_R_CREATED=""
CLEAN_PLAN_R_UID=""
declare -a CLEAN_PLAN_R_KIND=()
declare -a CLEAN_PLAN_R_ID=()
declare -a CLEAN_PLAN_R_SECTION=()
declare -a CLEAN_PLAN_R_TARGET=()
declare -a CLEAN_PLAN_R_DEVINO=()
declare -a CLEAN_PLAN_R_SIZE=()
declare -a CLEAN_PLAN_R_COUNT=()
declare -a CLEAN_PLAN_R_KNOWN=()
declare -a CLEAN_PLAN_R_COVERED=()
declare -a CLEAN_PLAN_R_EXTRA=()

clean_plan_dir() {
    printf '%s\n' "${MOLE_USER_HOME:-$HOME}/.config/mole/plans"
}

# A skipped row of the JSON preview (a section that needs sudo, a family
# deferred while its app runs).
clean_plan_note_skipped() {
    CLEAN_PLAN_SKIPPED_SECTIONS+=("${1:-}")
    CLEAN_PLAN_SKIPPED_NAMES+=("${2:-}")
    CLEAN_PLAN_SKIPPED_REASONS+=("${3:-}")
}

# One cause line and one next action, then a nonzero status.
_clean_plan_refuse() {
    printf 'mo clean: %s\n%s\n' "$1" "$2" >&2
    return 1
}

_clean_plan_iso_time() {
    date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2> /dev/null || printf '%s\n' "$1"
}

_clean_plan_valid_id() {
    [[ "${1:-}" =~ ^[0-9a-f]{16}$ ]]
}

_clean_plan_new_id() {
    local id=""
    id=$(od -An -N8 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n') || id=""
    _clean_plan_valid_id "$id" || return 1
    printf '%s\n' "$id"
}

# The plans folder must be a real folder this user owns, mode 0700.
_clean_plan_prepare_dir() {
    local dir
    dir=$(clean_plan_dir)
    if [[ -L "$dir" || (-e "$dir" && ! -d "$dir") || (-d "$dir" && ! -O "$dir") ]]; then
        _clean_plan_refuse "the plans folder $dir is a link, not a folder, or belongs to another user." \
            "Remove it, then run 'mo clean --dry-run --json' again."
        return 1
    fi
    if [[ ! -d "$dir" ]]; then
        ensure_user_dir "$(dirname "$dir")"
        mkdir -m 700 "$dir" 2> /dev/null || true
    fi
    if [[ ! -d "$dir" || -L "$dir" || ! -O "$dir" ]] || ! chmod 700 "$dir" 2> /dev/null; then
        _clean_plan_refuse "the plans folder $dir could not be created." \
            "Check that ~/.config/mole is writable, then run 'mo clean --dry-run --json' again."
        return 1
    fi
    printf '%s\n' "$dir"
}

# Plans expire after an hour; a file dated in the future is expired too.
# Also removes the scratch file of a save that was interrupted.
clean_plan_prune_expired() {
    local dir="$1"
    local now entry mtime
    now=$(date +%s)
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob
    for entry in "$dir"/*.ledger "$dir"/.plan.*; do
        [[ -f "$entry" && ! -L "$entry" && -O "$entry" ]] || continue
        mtime=$("$STAT_BSD" -f %m "$entry" 2> /dev/null) || continue
        [[ "$mtime" =~ ^[0-9]+$ ]] || continue
        if ((now - mtime >= CLEAN_PLAN_TTL_SEC || now < mtime)); then
            rm -f -- "$entry" 2> /dev/null || true # SAFE: Mole's own expired plan file in its 0700 plans folder
        fi
    done
    eval "$_ng_state"
}

# Read NUL-separated paths on stdin and print each one's lstat dev:inode
# (empty when it cannot be read), NUL-separated, in the same order.
_clean_plan_lstat_identities() {
    if [[ -x /usr/bin/perl ]]; then
        # shellcheck disable=SC2016  # Embedded Perl uses Perl variables inside single quotes.
        run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" /usr/bin/perl -e '
            local $/ = "\0";
            binmode STDIN;
            binmode STDOUT;
            while (defined(my $path = <STDIN>)) {
                chomp $path;
                my @st = lstat($path);
                print((@st ? "$st[0]:$st[1]" : ""), "\0");
            }
        '
        return $?
    fi
    local path identity
    while IFS= read -r -d '' path; do
        identity=$(mole_deletion_identity "$path" 2> /dev/null) || identity=""
        [[ -z "$identity" ]] || identity="${identity%:*}"
        printf '%s\0' "$identity"
    done
}

# Save the finished dry-run ledger as a plan. Prints the plan file path.
clean_plan_save() {
    if is_root_user; then
        _clean_plan_refuse "a reviewable plan is not saved for a root run." \
            "Run 'mo clean --dry-run --json' as your own user."
        return 1
    fi
    local dir
    dir=$(_clean_plan_prepare_dir) || return 1
    clean_plan_prune_expired "$dir"

    local plan_id
    if ! plan_id=$(_clean_plan_new_id); then
        _clean_plan_refuse "no random plan id could be read from /dev/urandom." \
            "Run 'mo clean --dry-run --json' again."
        return 1
    fi

    local records_file paths_file ids_file stage
    records_file=$(create_temp_file) || return 1
    paths_file=$(create_temp_file) || return 1
    ids_file=$(create_temp_file) || return 1
    emit_deduplicated_dry_run_ledger > "$records_file"

    local identity size_kb count size_known section path covered_by
    while IFS= read -r -d '' identity &&
        IFS= read -r -d '' size_kb &&
        IFS= read -r -d '' count &&
        IFS= read -r -d '' size_known &&
        IFS= read -r -d '' section &&
        IFS= read -r -d '' path &&
        IFS= read -r -d '' covered_by; do
        printf '%s\0' "$path"
    done < "$records_file" > "$paths_file"
    if ! _clean_plan_lstat_identities < "$paths_file" > "$ids_file"; then
        _clean_plan_refuse "the file identities of the preview could not be read in time." \
            "Run 'mo clean --dry-run --json' again."
        return 1
    fi

    stage=$(umask 077 && mktemp "$dir/.plan.XXXXXX") || {
        _clean_plan_refuse "the plan could not be written to $dir." \
            "Check that the folder is writable, then run 'mo clean --dry-run --json' again."
        return 1
    }

    local created index=0 devino seen_commands="" rs=$'\x1f' fs=$'\x1e'
    created=$(date +%s)
    {
        printf '%s\0%s\0%s\0%s\0' "$CLEAN_PLAN_MAGIC" "$CLEAN_PLAN_SCHEMA" "$created" "$(id -u)"
        while IFS= read -r -d '' identity &&
            IFS= read -r -d '' size_kb &&
            IFS= read -r -d '' count &&
            IFS= read -r -d '' size_known &&
            IFS= read -r -d '' section &&
            IFS= read -r -d '' path &&
            IFS= read -r -d '' covered_by &&
            IFS= read -r -d '' devino <&4; do
            index=$((index + 1))
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count=1
            printf 'P\0i%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0\0' \
                "$index" "$section" "$path" "$devino" "$size_kb" "$count" "$size_known" "$covered_by"
        done < "$records_file" 4< "$ids_file"
        local name command_text key
        if [[ -n "${CLEAN_PREVIEW_COMMAND_LEDGER_FILE:-}" && -f "$CLEAN_PREVIEW_COMMAND_LEDGER_FILE" ]]; then
            while IFS= read -r -d '' section &&
                IFS= read -r -d '' name &&
                IFS= read -r -d '' command_text; do
                key="$rs$section$fs$name$rs"
                [[ "$seen_commands" != *"$key"* ]] || continue
                seen_commands+="$key"
                index=$((index + 1))
                printf 'C\0i%s\0%s\0%s\0\0%s\0%s\0%s\0\0%s\0' \
                    "$index" "$section" "$name" 0 1 false "$command_text"
            done < "$CLEAN_PREVIEW_COMMAND_LEDGER_FILE"
        fi
        printf 'END\0'
    } > "$stage"

    local plan_file="$dir/$plan_id.ledger"
    if [[ -e "$plan_file" || -L "$plan_file" ]] || ! mv -n "$stage" "$plan_file" 2> /dev/null ||
        [[ -e "$stage" ]]; then
        rm -f -- "$stage" 2> /dev/null || true # SAFE: exact mktemp plan scratch file created above
        _clean_plan_refuse "the plan could not be saved as $plan_file." \
            "Run 'mo clean --dry-run --json' again."
        return 1
    fi
    CLEAN_PLAN_ID="$plan_id"
    printf '%s\n' "$plan_file"
}

# Load a plan file into the CLEAN_PLAN_R_* arrays. 1 when it is damaged.
_clean_plan_read() {
    local file="$1"
    CLEAN_PLAN_R_CREATED=""
    CLEAN_PLAN_R_KIND=()
    CLEAN_PLAN_R_ID=()
    CLEAN_PLAN_R_SECTION=()
    CLEAN_PLAN_R_TARGET=()
    CLEAN_PLAN_R_DEVINO=()
    CLEAN_PLAN_R_SIZE=()
    CLEAN_PLAN_R_COUNT=()
    CLEAN_PLAN_R_KNOWN=()
    CLEAN_PLAN_R_COVERED=()
    CLEAN_PLAN_R_EXTRA=()

    local magic schema created uid complete=false
    local kind id section target devino size_kb count known covered extra
    {
        IFS= read -r -d '' magic || return 1
        IFS= read -r -d '' schema || return 1
        IFS= read -r -d '' created || return 1
        IFS= read -r -d '' uid || return 1
        [[ "$magic" == "$CLEAN_PLAN_MAGIC" && "$schema" == "$CLEAN_PLAN_SCHEMA" ]] || return 1
        [[ "$created" =~ ^[0-9]+$ && "$uid" =~ ^[0-9]+$ ]] || return 1
        while IFS= read -r -d '' kind; do
            if [[ "$kind" == "END" ]]; then
                complete=true
                break
            fi
            [[ "$kind" == "P" || "$kind" == "C" ]] || return 1
            IFS= read -r -d '' id &&
                IFS= read -r -d '' section &&
                IFS= read -r -d '' target &&
                IFS= read -r -d '' devino &&
                IFS= read -r -d '' size_kb &&
                IFS= read -r -d '' count &&
                IFS= read -r -d '' known &&
                IFS= read -r -d '' covered &&
                IFS= read -r -d '' extra || return 1
            CLEAN_PLAN_R_KIND+=("$kind")
            CLEAN_PLAN_R_ID+=("$id")
            CLEAN_PLAN_R_SECTION+=("$section")
            CLEAN_PLAN_R_TARGET+=("$target")
            CLEAN_PLAN_R_DEVINO+=("$devino")
            CLEAN_PLAN_R_SIZE+=("$size_kb")
            CLEAN_PLAN_R_COUNT+=("$count")
            CLEAN_PLAN_R_KNOWN+=("$known")
            CLEAN_PLAN_R_COVERED+=("$covered")
            CLEAN_PLAN_R_EXTRA+=("$extra")
        done
    } < "$file"
    [[ "$complete" == "true" ]] || return 1
    CLEAN_PLAN_R_CREATED="$created"
    CLEAN_PLAN_R_UID="$uid"
}

_clean_plan_section_slug() {
    local slug
    slug=$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -cs 'a-z0-9' '-')
    slug="${slug#-}"
    slug="${slug%-}"
    printf '%s\n' "${slug:-section}"
}

# Print the JSON document of a saved plan. Totals follow the text preview:
# a row counted under a measured ancestor (covered_by) stays listed but adds
# nothing, and command items carry no bytes.
clean_plan_render_json() {
    local plan_file="$1"
    local plan_id="$2"
    local free_kb="${3:-}"
    _clean_plan_read "$plan_file" || return 1

    local rs=$'\x1f' fs=$'\x1e'
    local -a section_names=()
    local -a section_bytes=()
    local path_ids="" idx s found total_bytes=0 total_items=0 bytes
    local record_count=${#CLEAN_PLAN_R_ID[@]}
    for ((idx = 0; idx < record_count; idx++)); do
        found=-1
        for ((s = 0; s < ${#section_names[@]}; s++)); do
            if [[ "${section_names[$s]}" == "${CLEAN_PLAN_R_SECTION[$idx]}" ]]; then
                found=$s
                break
            fi
        done
        if [[ $found -lt 0 ]]; then
            section_names+=("${CLEAN_PLAN_R_SECTION[$idx]}")
            section_bytes+=(0)
            found=$((${#section_names[@]} - 1))
        fi
        [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "P" ]] || continue
        path_ids+="$rs${CLEAN_PLAN_R_TARGET[$idx]}$fs${CLEAN_PLAN_R_ID[$idx]}$rs"
        [[ -z "${CLEAN_PLAN_R_COVERED[$idx]}" ]] || continue
        bytes=$((${CLEAN_PLAN_R_SIZE[$idx]} * 1024))
        section_bytes[found]=$((section_bytes[found] + bytes))
        total_bytes=$((total_bytes + bytes))
        total_items=$((total_items + ${CLEAN_PLAN_R_COUNT[$idx]}))
    done

    local free_bytes="null"
    [[ "$free_kb" =~ ^[0-9]+$ ]] && free_bytes=$((free_kb * 1024))
    local created="$CLEAN_PLAN_R_CREATED"

    printf '{\n'
    printf '  "schema": %s,\n' "$CLEAN_PLAN_SCHEMA"
    printf '  "command": "clean",\n'
    printf '  "plan_id": "%s",\n' "$plan_id"
    printf '  "created_at": "%s",\n' "$(_clean_plan_iso_time "$created")"
    printf '  "expires_at": "%s",\n' "$(_clean_plan_iso_time "$((created + CLEAN_PLAN_TTL_SEC))")"
    printf '  "free_bytes": %s,\n' "$free_bytes"
    printf '  "total_bytes": %s,\n' "$total_bytes"
    printf '  "total_items": %s,\n' "$total_items"
    printf '  "sections": ['

    local used_slugs="" slug base_slug suffix first_section=true first_item covered covered_id
    for ((s = 0; s < ${#section_names[@]}; s++)); do
        base_slug=$(_clean_plan_section_slug "${section_names[$s]}")
        slug="$base_slug"
        suffix=2
        while [[ "$used_slugs" == *"|$slug|"* ]]; do
            slug="$base_slug-$suffix"
            suffix=$((suffix + 1))
        done
        used_slugs+="|$slug|"

        [[ "$first_section" == "true" ]] || printf ','
        first_section=false
        printf '\n    {"id": "%s", "name": ' "$slug"
        history_json_string "${section_names[$s]}"
        printf ', "bytes": %s, "items": [' "${section_bytes[$s]}"
        first_item=true
        for ((idx = 0; idx < record_count; idx++)); do
            [[ "${CLEAN_PLAN_R_SECTION[$idx]}" == "${section_names[$s]}" ]] || continue
            [[ "$first_item" == "true" ]] || printf ','
            first_item=false
            printf '\n      {"id": "%s", ' "${CLEAN_PLAN_R_ID[$idx]}"
            if [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "C" ]]; then
                printf '"kind": "command", "name": '
                history_json_string "${CLEAN_PLAN_R_TARGET[$idx]}"
                printf ', "command": '
                history_json_string "${CLEAN_PLAN_R_EXTRA[$idx]}"
                printf ', "bytes": 0, "size_known": false, "count": 1, "covered_by": null, "default_selected": true}'
                continue
            fi
            printf '"kind": "path", "path": '
            history_json_string "${CLEAN_PLAN_R_TARGET[$idx]}"
            bytes=$((${CLEAN_PLAN_R_SIZE[$idx]} * 1024))
            covered="${CLEAN_PLAN_R_COVERED[$idx]}"
            covered_id="null"
            if [[ -n "$covered" && "$covered" != *"$rs"* && "$covered" != *"$fs"* &&
                "$path_ids" == *"$rs$covered$fs"* ]]; then
                covered_id="${path_ids#*"$rs$covered$fs"}"
                covered_id="\"${covered_id%%"$rs"*}\""
            fi
            local size_known_json=false
            [[ "${CLEAN_PLAN_R_KNOWN[$idx]}" == "true" ]] && size_known_json=true
            printf ', "bytes": %s, "size_known": %s, "count": %s, "covered_by": %s, "default_selected": true}' \
                "$bytes" "$size_known_json" "${CLEAN_PLAN_R_COUNT[$idx]}" "$covered_id"
        done
        if [[ "$first_item" == "true" ]]; then
            printf ']}'
        else
            printf '\n    ]}'
        fi
    done
    if [[ "$first_section" == "true" ]]; then
        printf '],\n'
    else
        printf '\n  ],\n'
    fi

    printf '  "skipped": ['
    local k
    for ((k = 0; k < ${#CLEAN_PLAN_SKIPPED_NAMES[@]}; k++)); do
        [[ $k -eq 0 ]] || printf ','
        printf '\n    {"section": '
        history_json_string "${CLEAN_PLAN_SKIPPED_SECTIONS[$k]}"
        printf ', "name": '
        history_json_string "${CLEAN_PLAN_SKIPPED_NAMES[$k]}"
        printf ', "reason": '
        history_json_string "${CLEAN_PLAN_SKIPPED_REASONS[$k]}"
        printf '}'
    done
    if [[ ${#CLEAN_PLAN_SKIPPED_NAMES[@]} -gt 0 ]]; then
        printf '\n  ]\n'
    else
        printf ']\n'
    fi
    printf '}\n'
}

# Save the plan of the finished dry run and print its JSON to fd 7, the
# command's real stdout (bin/clean.sh sends everything else to stderr).
clean_plan_emit_json() {
    local plan_file
    if ! plan_file=$(clean_plan_save); then
        CLEAN_PLAN_SAVE_FAILED=true
        return 1
    fi
    local free_kb=""
    free_kb=$(get_free_space_kb 2> /dev/null) || free_kb=""
    CLEAN_PLAN_JSON_PENDING=false
    clean_plan_render_json "$plan_file" "$(basename "$plan_file" .ledger)" "$free_kb" >&7
}

# A failed or cancelled `--dry-run --json` prints this one document on stdout
# instead of a plan, and keeps its nonzero exit status: a signal is
# `cancelled`, a finished preview whose plan could not be saved is
# `plan_not_saved`, and any other stop is `incomplete`.
clean_plan_emit_json_error() {
    [[ "$CLEAN_PLAN_JSON_PENDING" == "true" ]] || return 0
    CLEAN_PLAN_JSON_PENDING=false
    local exit_code="$1" code message
    if mole_rc_signal "$exit_code"; then
        code="cancelled"
        message="The preview was cancelled before it finished; no plan was saved."
    elif [[ "$CLEAN_PLAN_SAVE_FAILED" == "true" ]]; then
        code="plan_not_saved"
        message="The preview finished, but its plan could not be saved; stderr names the cause."
    else
        code="incomplete"
        message="The preview stopped before it finished (exit $exit_code); no plan was saved."
    fi
    printf '{"schema":%s,"command":"clean","error":{"code":%s,"message":%s}}\n' "$CLEAN_PLAN_SCHEMA" \
        "$(history_json_string "$code")" "$(history_json_string "$message")" >&7 2> /dev/null || true
}

_clean_plan_normalize_path() {
    local path="$1" _slash_single="/" _slash_double="//"
    while [[ "$path" == *"$_slash_double"* ]]; do
        path="${path//$_slash_double/$_slash_single}"
    done
    while [[ ${#path} -gt 1 && "$path" == */ ]]; do
        path="${path%/}"
    done
    printf '%s' "$path"
}

# Check a plan and a selection for `--apply`, then write the approved-items
# file the sinks read (MOLE_APPLY_PLAN: kept paths, unticked paths and kept
# commands with their recorded text) and collect the deselected paths that
# become run-only whitelist entries. Refuses with a cause and a next action.
clean_plan_prepare_apply() {
    local plan_id="$1"
    local select_file="$2"
    local rerun="Run 'mo clean --dry-run --json' to create a new plan, then apply its plan_id."

    # Plans are saved per user and never for a root run, so a root apply has
    # no plan of its own to read.
    if is_root_user; then
        _clean_plan_refuse "a reviewed plan is not applied by a root run." \
            "Run 'mo clean --apply <plan_id> --select <file>' as your own user."
        return 1
    fi
    if ! _clean_plan_valid_id "$plan_id"; then
        _clean_plan_refuse "'$plan_id' is not a plan id; plan ids are 16 lowercase hex characters." "$rerun"
        return 1
    fi
    local dir plan_file
    dir=$(clean_plan_dir)
    plan_file="$dir/$plan_id.ledger"
    if [[ -L "$dir" || (-d "$dir" && ! -O "$dir") ]]; then
        _clean_plan_refuse "the plans folder $dir is a link or belongs to another user." \
            "Remove it, then run 'mo clean --dry-run --json' again."
        log_operation "clean" "SKIPPED" "$plan_file" "plan folder not owned"
        return 1
    fi
    if [[ -L "$plan_file" ]]; then
        _clean_plan_refuse "plan $plan_id is a symbolic link, not a plan Mole saved." \
            "Remove $plan_file. $rerun"
        log_operation "clean" "SKIPPED" "$plan_file" "plan is a symlink"
        return 1
    fi
    if [[ ! -e "$plan_file" ]]; then
        _clean_plan_refuse "no plan $plan_id in $dir; it may have expired and been removed." "$rerun"
        log_operation "clean" "SKIPPED" "$plan_file" "plan missing"
        return 1
    fi
    if [[ ! -O "$plan_file" ]]; then
        _clean_plan_refuse "plan $plan_id belongs to another user." "$rerun"
        log_operation "clean" "SKIPPED" "$plan_file" "plan owned by another user"
        return 1
    fi
    if [[ ! -f "$plan_file" ]] || ! _clean_plan_read "$plan_file"; then
        _clean_plan_refuse "plan $plan_id is not a complete Mole plan." "$rerun"
        log_operation "clean" "SKIPPED" "$plan_file" "plan damaged"
        return 1
    fi
    if [[ "$CLEAN_PLAN_R_UID" != "$(id -u)" ]]; then
        _clean_plan_refuse "plan $plan_id was saved by another user." "$rerun"
        log_operation "clean" "SKIPPED" "$plan_file" "plan owned by another user"
        return 1
    fi
    local now
    now=$(date +%s)
    if ((now < CLEAN_PLAN_R_CREATED || now - CLEAN_PLAN_R_CREATED >= CLEAN_PLAN_TTL_SEC)); then
        _clean_plan_refuse "plan $plan_id expired at $(_clean_plan_iso_time "$((CLEAN_PLAN_R_CREATED + CLEAN_PLAN_TTL_SEC))"); plans last one hour." \
            "Run 'mo clean --dry-run --json' again and review the new plan."
        log_operation "clean" "SKIPPED" "$plan_file" "plan expired"
        return 1
    fi

    if [[ ! -f "$select_file" || ! -r "$select_file" ]]; then
        _clean_plan_refuse "the selection file $select_file cannot be read." \
            "Pass a readable file that lists the kept item ids, one per line."
        return 1
    fi

    local rs=$'\x1f'
    local plan_ids="" idx
    local record_count=${#CLEAN_PLAN_R_ID[@]}
    for ((idx = 0; idx < record_count; idx++)); do
        plan_ids+="$rs${CLEAN_PLAN_R_ID[$idx]}$rs"
    done

    local selected="" line kept=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # shellcheck disable=SC2295
        line="${line#"${line%%[![:space:]]*}"}"
        # shellcheck disable=SC2295
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        if [[ ! "$line" =~ ^i[0-9]+$ || "$plan_ids" != *"$rs$line$rs"* ]]; then
            _clean_plan_refuse "the selection names '$line', which is not an item of plan $plan_id." \
                "List only item ids from that plan's JSON, one per line."
            return 1
        fi
        if [[ "$selected" != *"$rs$line$rs"* ]]; then
            selected+="$rs$line$rs"
            kept=$((kept + 1))
        fi
    done < "$select_file"
    if [[ $kept -eq 0 ]]; then
        _clean_plan_refuse "the selection file $select_file lists no items." \
            "List the item ids to clean, one per line, or skip the clean."
        return 1
    fi

    # Ancestors of kept paths stay out of the run-only whitelist: a whitelist
    # entry protects the children of a path too, which would keep a kept child.
    local kept_ancestors="" path ancestor
    for ((idx = 0; idx < record_count; idx++)); do
        [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "P" && "$selected" == *"$rs${CLEAN_PLAN_R_ID[$idx]}$rs"* ]] || continue
        ancestor=$(_clean_plan_normalize_path "${CLEAN_PLAN_R_TARGET[$idx]}")
        while [[ "$ancestor" == /?*/* ]]; do
            ancestor="${ancestor%/*}"
            kept_ancestors+="$rs$ancestor$rs"
        done
    done

    local approved
    approved=$(create_temp_file) || return 1
    CLEAN_APPLY_DESELECTED_PATHS=()
    {
        for ((idx = 0; idx < record_count; idx++)); do
            if [[ "$selected" == *"$rs${CLEAN_PLAN_R_ID[$idx]}$rs"* ]]; then
                if [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "P" ]]; then
                    printf 'P\0%s\0%s\0\0' "$(_clean_plan_normalize_path "${CLEAN_PLAN_R_TARGET[$idx]}")" \
                        "${CLEAN_PLAN_R_DEVINO[$idx]}"
                else
                    printf 'C\0%s\0%s\0%s\0' "${CLEAN_PLAN_R_SECTION[$idx]}" "${CLEAN_PLAN_R_TARGET[$idx]}" \
                        "${CLEAN_PLAN_R_EXTRA[$idx]}"
                fi
            elif [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "P" ]]; then
                # The sinks refuse an unticked path, anything under it that no
                # kept item covers, and any kept path that holds it.
                path=$(_clean_plan_normalize_path "${CLEAN_PLAN_R_TARGET[$idx]}")
                printf 'D\0%s\0\0\0' "$path"
                [[ "$kept_ancestors" == *"$rs$path$rs"* ]] || CLEAN_APPLY_DESELECTED_PATHS+=("$path")
            fi
        done
        printf 'END\0'
    } > "$approved"

    CLEAN_PLAN_ID="$plan_id"
    CLEAN_APPLY_KEPT_COUNT=$kept
    CLEAN_APPLY_ITEM_COUNT=$record_count
    MOLE_APPLY_PLAN="$approved"
    export MOLE_APPLY_PLAN
    _mole_apply_plan_load || {
        _clean_plan_refuse "the approved items of plan $plan_id could not be staged." "$rerun"
        return 1
    }
}
