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
# dev:inode each). The folder's own dev:inode is the shared devino field.
# A T record (the trim of a Rust `target`, lib/clean/project.sh) names the
# same folder with the same purge fields; its shared count is the number of
# entries the review listed and its covered_by the id of the folder's A
# record, which always comes just before it. The entries themselves are not
# saved: apply lists them again.
readonly PURGE_PLAN_AUX_FIELDS=14

# Called by clean_project_artifacts in place of the menu: append each review
# row to PURGE_PLAN_RECORDS_FILE in menu order. Reads the caller's item_* and
# scan_root* arrays through dynamic scope.
# shellcheck disable=SC2154  # Those arrays are locals of clean_project_artifacts.
purge_plan_record_items() {
    local file="${PURGE_PLAN_RECORDS_FILE:-}"
    [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
    local i root section default_selected kind covered artifact
    {
        for ((i = 0; i < ${#item_paths[@]}; i++)); do
            root="${item_scan_root_indexes[i]}"
            kind="${item_kinds[i]:-A}"
            covered="${item_covered_rows[i]:--1}"
            artifact="${menu_options[i]}"
            [[ "$kind" != "T" || $covered -lt 0 ]] || artifact="${menu_options[covered]}"
            section="${item_project_paths[i]}"
            section="${section#"[cloud] "}"
            default_selected=true
            [[ "${item_recent_flags[i]}" != "true" ]] || default_selected=false
            local size_known=true
            [[ "${item_size_unknown_flags[i]:-false}" != "true" ]] || size_known=false
            printf '%s\0' "$kind" "${item_trim_counts[i]:-1}" "$covered" \
                "$section" "${item_paths[i]}" "${item_expected_target_ids[i]}" "${item_sizes[i]}" \
                "$size_known" "$artifact" \
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

    local index=0 kind count covered covered_id section path devino size_kb known artifact field k
    local -a aux=()
    {
        while IFS= read -r -d '' kind &&
            IFS= read -r -d '' count &&
            IFS= read -r -d '' covered &&
            IFS= read -r -d '' section &&
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
            # Records keep menu order, so row N is item iN+1.
            covered_id=""
            if [[ "$kind" == "T" ]]; then
                [[ "$covered" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || return 1
                covered_id="i$((covered + 1))"
            else
                kind="A"
                count=1
            fi
            printf '%s\0i%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
                "$kind" "$index" "$section" "$path" "$devino" "$size_kb" "$count" "$known" "$covered_id" \
                "$artifact" "$PURGE_PLAN_AUX_FIELDS"
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
    local kind_json count=1 covered_json="null"
    case "${CLEAN_PLAN_R_KIND[$idx]}" in
        A) kind_json="path" ;;
        T)
            kind_json="trim"
            count="${CLEAN_PLAN_R_COUNT[$idx]}"
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
            [[ ! "${CLEAN_PLAN_R_COVERED[$idx]}" =~ ^i[0-9]+$ ]] || covered_json="\"${CLEAN_PLAN_R_COVERED[$idx]}\""
            ;;
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
    printf ', "bytes": %s, "size_known": %s, "count": %s, "covered_by": %s, "default_selected": %s' \
        "$((size_kb * 1024))" "$size_known" "$count" "$covered_json" "$default_selected"
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

# clean_plan_stage_path_selection hook: the approved-items records of a T
# record ($1, kept when $2 is true). A kept trim whose whole folder is not
# kept approves each `incremental`, `deps`, `build` and `.fingerprint` of the
# folder's profiles as it is now, so the sinks can take trim entries but never
# folder itself or a binary beside them; the folder's own unticked A
# record keeps it out. When the profiles cannot be listed in time nothing is
# approved and the record's id goes to PURGE_TRIM_STAGE_FAILED_IDS, so apply
# names that cause instead of letting every entry meet the gate. An A record
# returns 1: the shared whole-path rule stages it.
PURGE_TRIM_STAGE_FAILED_IDS=""
purge_plan_stage_record() {
    local idx="$1" kept="$2" rs=$'\x1f'
    [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "T" ]] || return 1
    [[ "$kept" == "true" ]] || return 0
    [[ "$CLEAN_PLAN_SELECTED_IDS" != *"$rs${CLEAN_PLAN_R_COVERED[$idx]}$rs"* ]] || return 0
    local target profiles profile name scope identity
    target=$(_clean_plan_normalize_path "${CLEAN_PLAN_R_TARGET[$idx]}")
    profiles=$(create_temp_file) || return 0
    if _purge_rust_trim_profiles "$target" "$profiles" "$((SECONDS + MOLE_TIMEOUT_HINT_SCAN_SEC))"; then
        while IFS= read -r -d '' profile; do
            for name in incremental "${PURGE_RUST_TRIM_AGED_DIRS[@]}"; do
                scope="$profile/$name"
                [[ -e "$scope" || -L "$scope" ]] || continue
                # A symlinked deps, build or .fingerprint is never trimmed.
                [[ "$name" == "incremental" || ! -L "$scope" ]] || continue
                identity=$("$STAT_BSD" -f '%d:%i' "$scope" 2> /dev/null) || continue
                printf 'P\0%s\0%s\0\0' "$scope" "$identity"
            done
        done < "$profiles"
    else
        PURGE_TRIM_STAGE_FAILED_IDS+="$rs${CLEAN_PLAN_R_ID[$idx]}$rs"
    fi
    rm -f "$profiles" # SAFE: this function's own registered temp file
    return 0
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
    local -a item_scan_root_indexes=() item_kinds=() item_trim_counts=() item_covered_rows=() item_record_ids=()
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
        # A trim kept together with its whole folder is dropped: the whole
        # removal wins and the trim logs nothing.
        if [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "T" &&
            "$selected" == *"$rs${CLEAN_PLAN_R_COVERED[$idx]}$rs"* ]]; then
            continue
        fi
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
        if ! clean_plan_list_has "${CLEAN_PLAN_R_AUX[$((at + 6))]}" \
            "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; then
            unconfigured_paths+=("$path")
            continue
        fi
        display=$(format_purge_target_path "$path")
        [[ "${CLEAN_PLAN_R_AUX[$((at + 2))]}" != "true" ]] || display="[cloud] $display"
        local item_kind="A" trim_count=1
        if [[ "${CLEAN_PLAN_R_KIND[$idx]}" == "T" ]]; then
            item_kind="T"
            trim_count="${CLEAN_PLAN_R_COUNT[$idx]}"
            display="$display (trim)"
        fi
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
        item_kinds+=("$item_kind")
        item_trim_counts+=("$trim_count")
        item_covered_rows+=(-1)
        item_record_ids+=("${CLEAN_PLAN_R_ID[$idx]}")
        selected_indices+=("$count")
        count=$((count + 1))
    done

    # Every sink also asks the plan: only a kept folder whose dev:inode is
    # still the reviewed one may go, and never an unticked one.
    PURGE_TRIM_STAGE_FAILED_IDS=""
    if ! clean_plan_stage_path_selection; then
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
    # A trim whose scope could not be listed while staging has nothing the
    # sinks may take; say so instead of refusing each entry at the gate.
    if [[ -n "$PURGE_TRIM_STAGE_FAILED_IDS" ]]; then
        local -a staged_indices=()
        local apply_index
        for apply_index in "${selected_indices[@]}"; do
            if [[ "$PURGE_TRIM_STAGE_FAILED_IDS" == *"$rs${item_record_ids[apply_index]}$rs"* ]]; then
                echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped ${item_display_paths[apply_index]} (its trim set could not be listed in time; run mo purge again)"
                _purge_note_review_skip "${item_paths[apply_index]}" "could not list trim"
                PURGE_RUN_OUTCOME="incomplete"
                continue
            fi
            staged_indices+=("$apply_index")
        done
        selected_indices=("${staged_indices[@]+"${staged_indices[@]}"}")
    fi
    [[ ${#selected_indices[@]} -gt 0 ]] || return 0
    _purge_remove_selected_items
}
