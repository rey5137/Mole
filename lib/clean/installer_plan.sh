#!/bin/bash
# Mole - Reviewable installer plans.
# `mo installer --dry-run --json` runs the same scan as `mo installer
# --dry-run` (collect_installers in bin/installer.sh), reads each file's
# identity the way the menu run does at confirmation
# (build_installer_delete_plan), then saves one record per installer file as a
# plan through lib/clean/plan.sh and prints its JSON instead of opening the
# menu. `mo installer --apply <plan_id> --select <file>` removes only the kept
# files, bound to the identity and size the plan recorded, through the menu
# run's own final checks and sink (execute_installer_delete_plan).

set -euo pipefail

# An I record (one installer file) carries these installer fields after the
# nine shared ones, in this order: exact size in bytes, the file's dev:inode:
# mtime identity, the first scan folder that reached it (for the record; apply
# asks the folders installer scans then), its physical parent
# folder and that folder's dev:inode, and the display name the menu shows.
# The shared fields hold the source as section, the file's dev:inode as
# devino, its size rounded up to KB and its type (dmg, pkg, ...) as extra.
readonly INSTALLER_PLAN_AUX_FIELDS=6

# Per-file plan data, parallel to INSTALLER_PLAN_INDEXES (indexes into
# INSTALLER_PATHS), set by installer_plan_collect.
declare -a INSTALLER_PLAN_INDEXES=()
declare -a INSTALLER_PLAN_IDENTITIES=()
declare -a INSTALLER_PLAN_ROOTS=()
declare -a INSTALLER_PLAN_PARENTS=()
declare -a INSTALLER_PLAN_PARENT_IDS=()

# Set by bin/installer.sh for a reviewed `--apply`.
INSTALLER_APPLY_PLAN_ID=""
INSTALLER_ALREADY_REMOVED=0

# $1 lies under the scan folder $2 no deeper than the scan reaches now.
_installer_plan_path_within_root() {
    local path="$1" root="$2"
    local max_depth="${MOLE_INSTALLER_SCAN_MAX_DEPTH:-$INSTALLER_SCAN_MAX_DEPTH_DEFAULT}"
    [[ -n "$root" && "$path" == "$root"/?* && "$max_depth" =~ ^[0-9]+$ ]] || return 1
    local rel="${path#"$root"/}"
    local slashes="${rel//[!\/]/}"
    [[ $((${#slashes} + 1)) -le $max_depth ]]
}

# Print the first scan folder that reaches $1.
installer_plan_scan_root() {
    local path="$1" root
    for root in "${INSTALLER_SCAN_PATHS[@]}"; do
        if _installer_plan_path_within_root "$path" "$root"; then
            printf '%s\n' "$root"
            return 0
        fi
    done
    return 1
}

# After collect_installers published INSTALLER_PATHS: read each file's
# identity as the menu run does before its confirmation, and the physical
# parent it sits in. A file whose identity cannot be read is a skipped row of
# the plan; a timeout or signal stops the plan with that status.
installer_plan_collect() {
    INSTALLER_PLAN_INDEXES=()
    INSTALLER_PLAN_IDENTITIES=()
    INSTALLER_PLAN_ROOTS=()
    INSTALLER_PLAN_PARENTS=()
    INSTALLER_PLAN_PARENT_IDS=()
    local -a all_indexes=()
    local i
    for ((i = 0; i < ${#INSTALLER_PATHS[@]}; i++)); do
        all_indexes+=("$i")
    done
    [[ ${#all_indexes[@]} -gt 0 ]] || return 0

    local build_rc=0
    build_installer_delete_plan "${all_indexes[@]}" || build_rc=$?
    if mole_rc_timeout_or_signal "$build_rc"; then
        return "$build_rc"
    fi
    reset_installer_delete_results

    # INSTALLER_DELETE_PATHS keeps INSTALLER_PATHS order, minus the files
    # whose identity could not be read.
    local planned=0 path identity root
    for ((i = 0; i < ${#INSTALLER_PATHS[@]}; i++)); do
        path="${INSTALLER_PATHS[$i]}"
        if [[ $planned -ge ${#INSTALLER_DELETE_PATHS[@]} || "${INSTALLER_DELETE_PATHS[$planned]}" != "$path" ]]; then
            clean_plan_note_skipped "$(get_source_display "$path")" "$path" "could not inspect"
            continue
        fi
        identity="${INSTALLER_DELETE_IDENTITIES[$planned]}"
        planned=$((planned + 1))
        if ! _mole_snapshot_path_identity "$path" ||
            [[ "$_MOLE_PATH_SNAPSHOT_TARGET_ID" != "${identity%:*}" ]]; then
            clean_plan_note_skipped "$(get_source_display "$path")" "$path" "could not inspect"
            continue
        fi
        if ! root=$(installer_plan_scan_root "$path"); then
            clean_plan_note_skipped "$(get_source_display "$path")" "$path" "outside installer folders"
            continue
        fi
        INSTALLER_PLAN_INDEXES+=("$i")
        INSTALLER_PLAN_IDENTITIES+=("$identity")
        INSTALLER_PLAN_ROOTS+=("$root")
        INSTALLER_PLAN_PARENTS+=("$_MOLE_PATH_SNAPSHOT_PARENT")
        INSTALLER_PLAN_PARENT_IDS+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
    done
    reset_installer_delete_plan
}

# Save the collected files as an installer plan. Prints the plan file path.
installer_plan_save() {
    _clean_plan_save_begin || return 1
    local body_file
    body_file=$(create_temp_file) || return 1

    local k i path bytes size_kb identity type source
    {
        for ((k = 0; k < ${#INSTALLER_PLAN_INDEXES[@]}; k++)); do
            i="${INSTALLER_PLAN_INDEXES[$k]}"
            path="${INSTALLER_PATHS[$i]}"
            bytes="${INSTALLER_SIZES[$i]:-0}"
            [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
            size_kb=$(((bytes + 1023) / 1024))
            identity="${INSTALLER_PLAN_IDENTITIES[$k]}"
            source="${INSTALLER_SOURCES[$i]:-$(get_source_display "$path")}"
            type=$(printf '%s' "${path##*.}" | /usr/bin/tr '[:upper:]' '[:lower:]')
            printf 'I\0i%s\0%s\0%s\0%s\0%s\0%s\0%s\0\0%s\0%s\0' \
                "$((k + 1))" "$source" "$path" "${identity%:*}" "$size_kb" 1 true "$type" "$INSTALLER_PLAN_AUX_FIELDS"
            printf '%s\0' "$bytes" "$identity" "${INSTALLER_PLAN_ROOTS[$k]}" "${INSTALLER_PLAN_PARENTS[$k]}" \
                "${INSTALLER_PLAN_PARENT_IDS[$k]}" "$(installer_display_name "$path" "$source")"
        done
    } > "$body_file"

    _clean_plan_save_finish "$body_file"
}

# The exact size of one installer item, for the JSON totals.
installer_plan_item_bytes() {
    local bytes="${CLEAN_PLAN_R_AUX[${CLEAN_PLAN_R_AUX_AT[$1]}]:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    CLEAN_PLAN_ITEM_BYTES="$bytes"
}

# Print the rest of one installer item of the JSON plan, after its id. The
# fields a clean item has come first, so one decoder reads every plan. The
# menu starts with nothing ticked, so no item is selected by default.
installer_plan_render_item() {
    local idx="$1"
    local at="${CLEAN_PLAN_R_AUX_AT[$idx]}"
    [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "I" ]] || return 1
    installer_plan_item_bytes "$idx"
    printf '"kind": "path", "path": '
    history_json_string "${CLEAN_PLAN_R_TARGET[$idx]}"
    printf ', "bytes": %s, "size_known": true, "count": 1, "covered_by": null, "default_selected": false' \
        "$CLEAN_PLAN_ITEM_BYTES"
    printf ', "type": '
    history_json_string "${CLEAN_PLAN_R_EXTRA[$idx]}"
    printf ', "name": '
    history_json_string "${CLEAN_PLAN_R_AUX[$((at + 5))]}"
    printf '}'
}

# A reviewed `--apply` logs each refusal as a SKIPPED row with a fixed reason
# (unless the sink already logged it, $3) and prints its cause with the next
# step. Called by record_installer_delete_failure.
installer_plan_note_refusal() {
    local path="$1" reason="$2"
    [[ "${3:-}" == "logged" ]] || log_operation "installer" "SKIPPED" "$path" "$reason"
    local detail
    case "$reason" in
        "outside installer folders")
            detail="its folder is no longer one mo installer scans; run mo installer --dry-run --json again"
            ;;
        trash-failed)
            detail="could not move to Trash; run without --trash, or give your terminal Full Disk Access"
            ;;
        "move to Trash timed out")
            detail="the move to the Trash timed out; run the same mo installer --apply again, or run it without --trash"
            ;;
        "already in Trash")
            detail="already in the Trash; empty the Trash to free it"
            ;;
        *)
            detail="$reason; run mo installer --dry-run --json again to review it"
            ;;
    esac
    echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $(installer_display_text "$(mole_tilde_path "$path")") ($detail)"
}

# Apply a reviewed plan that clean_plan_load_selection accepted: narrow every
# sink to the kept files (MOLE_APPLY_PLAN), refuse a kept file that no scan
# folder reaches now or that was replaced since review, then hand the
# rest to execute_installer_delete_plan with the size and identity the plan
# recorded, never ones read now. Returns that function's status, or
# INSTALLER_EXIT_SCAN_FAILED when the selection cannot be staged.
installer_plan_apply() {
    local rs=$'\x1f'
    local selected="$CLEAN_PLAN_SELECTED_IDS"
    local record_count=${#CLEAN_PLAN_R_ID[@]}
    local idx at path bytes parent parent_id

    reset_installer_delete_results
    reset_installer_delete_plan
    INSTALLER_ALREADY_REMOVED=0

    if ! clean_plan_stage_path_selection; then
        _clean_plan_refuse "the approved items of plan $CLEAN_PLAN_ID could not be staged ($_MOLE_APPLY_PLAN_LOAD_ERROR)." \
            "Run 'mo installer --dry-run --json' to create a new plan, then apply its plan_id."
        return "$INSTALLER_EXIT_SCAN_FAILED"
    fi

    for ((idx = 0; idx < record_count; idx++)); do
        [[ "$selected" == *"$rs${CLEAN_PLAN_R_ID[$idx]}$rs"* ]] || continue
        path="${CLEAN_PLAN_R_TARGET[$idx]}"
        at="${CLEAN_PLAN_R_AUX_AT[$idx]}"
        bytes="${CLEAN_PLAN_R_AUX[$at]}"
        parent="${CLEAN_PLAN_R_AUX[$((at + 3))]}"
        parent_id="${CLEAN_PLAN_R_AUX[$((at + 4))]}"
        # Some folder installer scans now must still reach the file, at a
        # depth the scan still reaches: the plan gives no authority beyond
        # them. Any such folder counts, not only the one recorded at review,
        # since nested folders (Downloads/Telegram Desktop) overlap.
        if ! installer_plan_scan_root "$path" > /dev/null; then
            record_installer_delete_failure "$path" "outside installer folders"
            continue
        fi
        # A plan applied twice finds its file already gone. Only while the
        # reviewed parent folder is still in place: a file whose folder was
        # renamed or whose disk is gone was not removed.
        if [[ ! -e "$path" && ! -L "$path" ]] && clean_plan_parent_unchanged "$path" "$parent" "$parent_id"; then
            echo -e "${GRAY}${ICON_SUCCESS} $(installer_display_text "$(mole_tilde_path "$path")") already removed${NC}"
            INSTALLER_ALREADY_REMOVED=$((INSTALLER_ALREADY_REMOVED + 1))
            continue
        fi
        if ! _mole_path_matches_identity "$path" "$parent" "$parent_id" "${CLEAN_PLAN_R_DEVINO[$idx]}"; then
            record_installer_delete_failure "$path" "changed since review"
            continue
        fi
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        INSTALLER_DELETE_PATHS+=("$path")
        INSTALLER_DELETE_SIZES+=("$bytes")
        INSTALLER_DELETE_IDENTITIES+=("${CLEAN_PLAN_R_AUX[$((at + 1))]}")
    done

    execute_installer_delete_plan
}
