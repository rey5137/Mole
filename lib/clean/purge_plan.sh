#!/bin/bash
# Mole - Reviewable purge plans.
# `mo purge --dry-run --json` runs the same discovery, protection filters,
# activity and size probes as `mo purge --dry-run`, then saves one record per
# artifact folder as a plan through lib/clean/plan.sh and prints its JSON
# instead of opening the menu. `mo purge --apply <plan_id> --select <file>`
# removes only the kept artifacts, through the same rechecks and final sink
# the menu run uses (_purge_remove_selected_items in lib/clean/project.sh).

set -euo pipefail

# An A record (one whole artifact folder) carries these purge fields after the
# nine shared ones, in this order: activity state, default selection, cloud
# flag, age label, the folder's physical parent and its dev:inode, then the
# scan root's lexical and physical identities (path, parent, parent dev:inode,
# dev:inode each). The folder's own dev:inode is the shared devino field. A
# later kind (a Rust `target` trim) adds its own letter and fields.
readonly PURGE_PLAN_AUX_FIELDS=14

# Called by clean_project_artifacts in place of the menu: append each review
# row to PURGE_PLAN_RECORDS_FILE in menu order. Reads the caller's item_* and
# scan_root* arrays through dynamic scope.
# shellcheck disable=SC2154  # Those arrays are locals of clean_project_artifacts.
purge_plan_record_items() {
    local file="${PURGE_PLAN_RECORDS_FILE:-}"
    [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
    local i root section default_selected
    {
        for ((i = 0; i < ${#item_paths[@]}; i++)); do
            root="${item_scan_root_indexes[i]}"
            section="${item_project_paths[i]}"
            section="${section#"[cloud] "}"
            default_selected=true
            [[ "${item_recent_flags[i]}" != "true" ]] || default_selected=false
            local size_known=true
            [[ "${item_size_unknown_flags[i]:-false}" != "true" ]] || size_known=false
            printf '%s\0' "$section" "${item_paths[i]}" "${item_expected_target_ids[i]}" "${item_sizes[i]}" \
                "$size_known" "${menu_options[i]}" \
                "${item_activity_states[i]:-uncertain}" "$default_selected" "${item_cloud_flags[i]:-false}" \
                "${item_age_labels[i]:-unknown}" "${item_expected_parents[i]}" "${item_expected_parent_ids[i]}" \
                "${scan_roots[$root]}" "${scan_root_parents[$root]}" "${scan_root_parent_ids[$root]}" \
                "${scan_root_target_ids[$root]}" "${scan_root_physical_paths[$root]}" \
                "${scan_root_physical_parents[$root]}" "${scan_root_physical_parent_ids[$root]}" \
                "${scan_root_physical_target_ids[$root]}"
        done
    } >> "$file"
}

# Save the recorded rows as a purge plan. Prints the plan file path.
purge_plan_save() {
    _clean_plan_save_begin || return 1
    local body_file
    body_file=$(create_temp_file) || return 1

    local index=0 section path devino size_kb known artifact field k
    local -a aux=()
    {
        while IFS= read -r -d '' section &&
            IFS= read -r -d '' path &&
            IFS= read -r -d '' devino &&
            IFS= read -r -d '' size_kb &&
            IFS= read -r -d '' known &&
            IFS= read -r -d '' artifact; do
            aux=()
            for ((k = 0; k < PURGE_PLAN_AUX_FIELDS; k++)); do
                IFS= read -r -d '' field || return 1
                aux+=("$field")
            done
            index=$((index + 1))
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            printf 'A\0i%s\0%s\0%s\0%s\0%s\0%s\0%s\0\0%s\0%s\0' \
                "$index" "$section" "$path" "$devino" "$size_kb" 1 "$known" "$artifact" "$PURGE_PLAN_AUX_FIELDS"
            printf '%s\0' "${aux[@]}"
        done < "$PURGE_PLAN_RECORDS_FILE"
    } > "$body_file"

    _clean_plan_save_finish "$body_file"
}

# Print the rest of one purge item of the JSON plan, after its id. The fields
# a clean item has come first, so one decoder reads both plans.
purge_plan_render_item() {
    local idx="$1"
    local at="${CLEAN_PLAN_R_AUX_AT[$idx]}"
    local kind_json
    case "${CLEAN_PLAN_R_KIND[$idx]}" in
        A) kind_json="path" ;;
        *) return 1 ;;
    esac
    local size_kb="${CLEAN_PLAN_R_SIZE[$idx]}"
    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
    local size_known=false default_selected=false cloud=false
    [[ "${CLEAN_PLAN_R_KNOWN[$idx]}" != "true" ]] || size_known=true
    [[ "${CLEAN_PLAN_R_AUX[$((at + 1))]}" != "true" ]] || default_selected=true
    [[ "${CLEAN_PLAN_R_AUX[$((at + 2))]}" != "true" ]] || cloud=true

    printf '"kind": "%s", "path": ' "$kind_json"
    history_json_string "${CLEAN_PLAN_R_TARGET[$idx]}"
    printf ', "bytes": %s, "size_known": %s, "count": 1, "covered_by": null, "default_selected": %s' \
        "$((size_kb * 1024))" "$size_known" "$default_selected"
    printf ', "artifact": '
    history_json_string "${CLEAN_PLAN_R_EXTRA[$idx]}"
    printf ', "age": '
    history_json_string "${CLEAN_PLAN_R_AUX[$((at + 3))]}"
    printf ', "cloud": %s}' "$cloud"
}

# After a `--dry-run --json` scan: print the plan, or return 1 so the EXIT trap
# prints the error document. A scan root that did not finish stops the plan,
# as it fails the text preview; an artifact that could not be inspected or
# measured is a skipped row of the plan.
purge_plan_finish_json() {
    local outcome="$1"
    if [[ "$outcome" == "scan_failed" || "${PURGE_PLAN_SCAN_INCOMPLETE:-false}" == "true" ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} The project scan did not complete, so no plan was saved." >&2
        echo -e "${GRAY}Re-run 'mo purge --dry-run --json' once the scan can finish; 'mo purge --debug' names the slow root.${NC}" >&2
        return 1
    fi
    case "$outcome" in
        completed | incomplete | no_candidates) ;;
        *) return 1 ;;
    esac
    clean_plan_emit_json || return 1
    print_summary_block "Dry run complete - no changes made" \
        "The review plan was printed as JSON; it expires in one hour."
    printf '\n'
}

# The scan root a plan recorded is still one of PURGE_SEARCH_PATHS, the
# purge paths this run loaded.
_purge_plan_root_configured() {
    local root="$1" search_path
    [[ -n "$root" ]] || return 1
    for search_path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
        [[ "$search_path" != "$root" ]] || return 0
    done
    return 1
}

# Apply a reviewed plan that clean_plan_load_selection accepted: build the
# menu run's arrays from the kept records only, narrow every sink to them
# (MOLE_APPLY_PLAN), and remove them through _purge_remove_selected_items.
# Sets PURGE_RUN_OUTCOME.
purge_plan_apply() {
    local rs=$'\x1f'
    local selected="$CLEAN_PLAN_SELECTED_IDS"
    local -a selected_indices=() item_paths=() item_display_paths=() item_sizes=() item_size_unknown_flags=()
    local -a item_activity_states=() item_expected_parents=() item_expected_parent_ids=() item_expected_target_ids=()
    local -a item_scan_root_indexes=()
    local -a scan_roots=() scan_root_parents=() scan_root_parent_ids=() scan_root_target_ids=()
    local -a scan_root_physical_paths=() scan_root_physical_parents=() scan_root_physical_parent_ids=()
    local -a scan_root_physical_target_ids=()
    local -a whitelisted_paths=() unconfigured_paths=()
    local idx at path display count=0
    local record_count=${#CLEAN_PLAN_R_ID[@]}

    PURGE_RUN_OUTCOME="completed"
    PURGE_UNKNOWN_SIZE_COUNT=0
    PURGE_APPLY_SKIPPED=""

    for ((idx = 0; idx < record_count; idx++)); do
        [[ "$selected" == *"$rs${CLEAN_PLAN_R_ID[$idx]}$rs"* ]] || continue
        path="${CLEAN_PLAN_R_TARGET[$idx]}"
        # Discovery leaves whitelisted folders out; a whitelist entry added
        # since the review, on the folder or on its SwiftPM scratch root,
        # keeps it.
        if is_path_whitelisted "$path"; then
            whitelisted_paths+=("$path")
            continue
        fi
        if is_swiftpm_build_output_artifact "$path"; then
            local swiftpm_scratch="${path%/*}"
            if is_path_whitelisted "$swiftpm_scratch" ||
                { [[ "${swiftpm_scratch##*/}" == "index-build" ]] && is_path_whitelisted "${swiftpm_scratch%/*}"; }; then
                whitelisted_paths+=("$path")
                continue
            fi
        fi
        at="${CLEAN_PLAN_R_AUX_AT[$idx]}"
        # The reviewed scan root must still be a configured purge path: a
        # root the user removed from purge_paths since gives no authority.
        if ! _purge_plan_root_configured "${CLEAN_PLAN_R_AUX[$((at + 6))]}"; then
            unconfigured_paths+=("$path")
            continue
        fi
        display=$(format_purge_target_path "$path")
        [[ "${CLEAN_PLAN_R_AUX[$((at + 2))]}" != "true" ]] || display="[cloud] $display"
        local size_kb="${CLEAN_PLAN_R_SIZE[$idx]}"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        local size_unknown=false
        [[ "${CLEAN_PLAN_R_KNOWN[$idx]}" == "true" ]] || size_unknown=true

        item_paths+=("$path")
        item_display_paths+=("$display")
        item_sizes+=("$size_kb")
        item_size_unknown_flags+=("$size_unknown")
        item_activity_states+=("${CLEAN_PLAN_R_AUX[$at]}")
        item_expected_parents+=("${CLEAN_PLAN_R_AUX[$((at + 4))]}")
        item_expected_parent_ids+=("${CLEAN_PLAN_R_AUX[$((at + 5))]}")
        item_expected_target_ids+=("${CLEAN_PLAN_R_DEVINO[$idx]}")
        scan_roots+=("${CLEAN_PLAN_R_AUX[$((at + 6))]}")
        scan_root_parents+=("${CLEAN_PLAN_R_AUX[$((at + 7))]}")
        scan_root_parent_ids+=("${CLEAN_PLAN_R_AUX[$((at + 8))]}")
        scan_root_target_ids+=("${CLEAN_PLAN_R_AUX[$((at + 9))]}")
        scan_root_physical_paths+=("${CLEAN_PLAN_R_AUX[$((at + 10))]}")
        scan_root_physical_parents+=("${CLEAN_PLAN_R_AUX[$((at + 11))]}")
        scan_root_physical_parent_ids+=("${CLEAN_PLAN_R_AUX[$((at + 12))]}")
        scan_root_physical_target_ids+=("${CLEAN_PLAN_R_AUX[$((at + 13))]}")
        item_scan_root_indexes+=("$count")
        selected_indices+=("$count")
        count=$((count + 1))
    done

    # Every sink also asks the plan: only a kept folder whose dev:inode is
    # still the reviewed one may go, and never an unticked one.
    local approved
    approved=$(create_temp_file) || return 1
    {
        for ((idx = 0; idx < record_count; idx++)); do
            path=$(_clean_plan_normalize_path "${CLEAN_PLAN_R_TARGET[$idx]}")
            if [[ "$selected" == *"$rs${CLEAN_PLAN_R_ID[$idx]}$rs"* ]]; then
                printf 'P\0%s\0%s\0\0' "$path" "${CLEAN_PLAN_R_DEVINO[$idx]}"
            else
                printf 'D\0%s\0\0\0' "$path"
            fi
        done
        printf 'END\0'
    } > "$approved"
    MOLE_APPLY_PLAN="$approved"
    export MOLE_APPLY_PLAN
    if ! _mole_apply_plan_load; then
        _clean_plan_refuse "the approved items of plan $CLEAN_PLAN_ID could not be staged ($_MOLE_APPLY_PLAN_LOAD_ERROR)." \
            "Run 'mo purge --dry-run --json' to create a new plan, then apply its plan_id."
        PURGE_RUN_OUTCOME="scan_failed"
        return 0
    fi

    for path in "${unconfigured_paths[@]+"${unconfigured_paths[@]}"}"; do
        echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $(format_purge_target_path "$path") (its scan folder is no longer a purge path; run mo purge --dry-run --json again)"
        _purge_note_review_skip "$path" "outside purge paths"
        PURGE_RUN_OUTCOME="incomplete"
    done
    for path in "${whitelisted_paths[@]+"${whitelisted_paths[@]}"}"; do
        echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $(format_purge_target_path "$path") (whitelisted)"
        _purge_note_review_skip "$path" "whitelist"
        PURGE_RUN_OUTCOME="incomplete"
    done
    [[ ${#selected_indices[@]} -gt 0 ]] || return 0
    _purge_remove_selected_items
}
