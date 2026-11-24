#!/bin/bash
# Mole - Purge command.
# Cleans heavy project build artifacts.
# Interactive selection by project.

set -euo pipefail

# User state and installed tools must never run with inherited root privileges.
# Individual maintenance operations request administrator access themselves.
if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'Run Mole without sudo; it requests administrator access when needed.' >&2
    exit 1
fi

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

# Restores cursor and clears temp files even when set -e aborts (#915).
cleanup() {
    local exit_code="${1:-$?}"
    # A JSON preview that stops or is cancelled still prints one document.
    if [[ "$exit_code" != "0" && "${CLEAN_PLAN_JSON_PENDING:-false}" == "true" ]]; then
        clean_plan_emit_json_error "$exit_code"
    fi
    show_cursor 2> /dev/null || true
    cleanup_temp_files
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup 130; exit 130' INT TERM
source "$SCRIPT_DIR/../lib/core/log.sh"
source "$SCRIPT_DIR/../lib/clean/project.sh"
source "$SCRIPT_DIR/../lib/core/history.sh"
source "$SCRIPT_DIR/../lib/clean/plan.sh"
source "$SCRIPT_DIR/../lib/clean/purge_plan.sh"
CLEAN_PLAN_COMMAND="purge"

# Purge ends at safe_remove just like clean, so initialize the invoking user's
# whitelist before project discovery or the interactive selection begins.
load_mole_whitelist || exit 1

# Configuration
CURRENT_SECTION=""

# IMPORTANT: This file overrides start_section / end_section / note_activity
# from lib/core/base.sh by virtue of being sourced after it. The purge variant
# uses a blue ━━━ box header, has no fallback "Nothing to ..." message, and
# writes every note_activity call straight to EXPORT_LIST_FILE (purge always
# wants the export list, not just under DRY_RUN). See the cross-reference in
# lib/core/base.sh and the clean variant in bin/clean.sh before changing any
# of these three.
start_section() {
    local section_name="$1"
    CURRENT_SECTION="$section_name"
    printf '\n'
    echo -e "${BLUE}━━━ ${section_name} ━━━${NC}"
}

end_section() {
    CURRENT_SECTION=""
}

note_activity() {
    if [[ -n "$CURRENT_SECTION" ]]; then
        printf '%s\n' "$CURRENT_SECTION" >> "$EXPORT_LIST_FILE"
    fi
}

# Keep the most specific tail of a long purge path visible on the live scan line.
compact_purge_scan_path() {
    local path="$1"
    local max_path_len="${2:-0}"

    if ! [[ "$max_path_len" =~ ^[0-9]+$ ]] || [[ "$max_path_len" -lt 4 ]]; then
        max_path_len=4
    fi

    if [[ ${#path} -le $max_path_len ]]; then
        echo "$path"
        return
    fi

    local suffix_len=$((max_path_len - 3))
    local suffix="${path: -$suffix_len}"
    local path_tail=""
    local remainder="$path"

    while [[ "$remainder" == */* ]]; do
        local segment="/${remainder##*/}"
        remainder="${remainder%/*}"

        if [[ -z "$path_tail" ]]; then
            if [[ ${#segment} -le $suffix_len ]]; then
                path_tail="$segment"
            else
                break
            fi
            continue
        fi

        if [[ $((${#segment} + ${#path_tail})) -le $suffix_len ]]; then
            path_tail="${segment}${path_tail}"
        else
            break
        fi
    done

    if [[ -n "$path_tail" ]]; then
        echo "...${path_tail}"
        return
    fi

    echo "...$suffix"
}

# Main purge function
start_purge() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="purge"
    log_operation_session_start "purge"

    # Clear screen for better UX
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi

    # Initialize stats file in user cache directory
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    ensure_user_dir "$stats_dir"
    ensure_user_file "$stats_dir/purge_stats"
    ensure_user_file "$stats_dir/purge_count"
    ensure_user_file "$stats_dir/purge_scanning"
    echo "0" > "$stats_dir/purge_stats"
    echo "0" > "$stats_dir/purge_count"
    echo "" > "$stats_dir/purge_scanning"
}

# Perform the purge
perform_purge() {
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    local monitor_pid=""

    # Cleanup function - use flag to prevent duplicate execution
    _cleanup_done=false
    cleanup_monitor() {
        # Prevent multiple cleanup executions from trap conflicts
        [[ "$_cleanup_done" == "true" ]] && return
        _cleanup_done=true

        # Remove scanning file to stop monitor
        rm -f "$stats_dir/purge_scanning" 2> /dev/null || true

        if [[ -n "$monitor_pid" ]]; then
            kill "$monitor_pid" 2> /dev/null || true
            wait "$monitor_pid" 2> /dev/null || true
        fi
        if [[ -t 1 ]]; then
            printf '\r\033[2K\n' > /dev/tty 2> /dev/null || true
        fi
    }

    # Ensure Ctrl-C/TERM always stops spinner(s) and exits immediately.
    handle_interrupt() {
        cleanup_monitor
        stop_inline_spinner 2> /dev/null || true
        show_cursor 2> /dev/null || true
        printf '\n' >&2
        exit 130
    }

    # Set up trap for cleanup + abort
    trap handle_interrupt INT TERM

    # Show scanning with spinner below the title line
    if [[ -t 1 ]]; then
        # Print title ONCE with newline; spinner occupies the line below
        printf '%s\n' "${PURPLE_BOLD}Purge Project Artifacts${NC}"

        # Capture terminal width in parent (most reliable before forking)
        local _parent_cols=80
        local _stty_out
        if _stty_out=$(stty size < /dev/tty 2> /dev/null); then
            _parent_cols="${_stty_out##* }" # "rows cols" -> take cols
        else
            _parent_cols=$(tput cols 2> /dev/null || echo 80)
        fi
        [[ "$_parent_cols" =~ ^[0-9]+$ && $_parent_cols -gt 0 ]] || _parent_cols=80

        # Start background monitor: writes directly to /dev/tty to avoid stdout state issues
        (
            mo_load_spinner_frames
            local spinner_idx=0
            local last_path=""
            # Use parent-captured width; never refresh inside the loop (avoids unreliable tput in bg)
            local term_cols="$_parent_cols"
            # Visible prefix "| Scanning " = 11 chars; reserve 25 total for safety margin
            local max_path_len=$((term_cols - 25))
            ((max_path_len < 5)) && max_path_len=5

            # Set up trap to exit cleanly (erase the spinner line via /dev/tty)
            trap 'printf "\r\033[2K" >/dev/tty 2>/dev/null; exit 0' INT TERM

            local _parent_pid=$$
            while [[ -f "$stats_dir/purge_scanning" ]]; do
                # Exit if parent process died (prevents orphaned spinner)
                if ! kill -0 "$_parent_pid" 2> /dev/null; then
                    break
                fi
                local current_path
                current_path=$(cat "$stats_dir/purge_scanning" 2> /dev/null || echo "")

                if [[ -n "$current_path" ]]; then
                    local display_path
                    display_path=$(mole_tilde_path "$current_path")
                    display_path=$(compact_purge_scan_path "$display_path" "$max_path_len")
                    last_path="$display_path"
                fi

                local spin_char="${MO_SPINNER_FRAMES[$spinner_idx]}"
                spinner_idx=$(((spinner_idx + 1) % ${#MO_SPINNER_FRAMES[@]}))

                # Write directly to /dev/tty: \033[2K clears entire current line, \r goes to start
                if [[ -n "$last_path" ]]; then
                    printf '\r\033[2K%s %sScanning %s%s' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}" "$last_path" "${NC}" > /dev/tty 2> /dev/null
                else
                    printf '\r\033[2K%s %sScanning...%s' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}" "${NC}" > /dev/tty 2> /dev/null
                fi

                sleep 0.05
            done
            printf '\r\033[2K' > /dev/tty 2> /dev/null
            exit 0
        ) &
        monitor_pid=$!
    else
        echo -e "${PURPLE_BOLD}Purge Project Artifacts${NC}"
    fi

    clean_project_artifacts
    local purge_outcome="${PURGE_RUN_OUTCOME:-scan_failed}"

    # Clean up
    trap - INT TERM
    cleanup_monitor

    if [[ -n "$PURGE_PLAN_RECORDS_FILE" ]]; then
        log_operation_session_end "purge" 0 0
        purge_plan_finish_json "$purge_outcome"
        return $?
    fi
    finish_purge_run "$purge_outcome"
}

# Apply a reviewed plan (`mo purge --apply <plan_id> --select <file>`): no
# scan and no menu; only the kept artifacts are rechecked and removed.
perform_purge_apply() {
    echo -e "${PURPLE_BOLD}Purge Project Artifacts${NC}"
    local plan_note="Reviewed plan $CLEAN_PLAN_ID · $CLEAN_APPLY_KEPT_COUNT of $CLEAN_APPLY_ITEM_COUNT items kept"
    [[ "${MOLE_CLEAN_TRASH:-0}" == "1" ]] && plan_note+=" · to Trash"
    echo -e "${BLUE}${ICON_ADMIN}${NC} $plan_note"
    echo ""
    purge_plan_apply
    finish_purge_run "${PURGE_RUN_OUTCOME:-scan_failed}"
}

# Log the session end and print the summary of a finished purge run.
finish_purge_run() {
    local purge_outcome="$1"
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"

    case "$purge_outcome" in
        no_candidates | cancelled | scan_failed)
            # start_purge already wrote the start marker; without the end
            # marker mo history lists this finished run as never ended.
            log_operation_session_end "purge" 0 0
            [[ "$purge_outcome" != "scan_failed" ]] || return 1
            return 0
            ;;
        completed | incomplete) ;;
        *)
            log_error "Unknown purge outcome: $purge_outcome"
            return 1
            ;;
    esac

    # Final summary (matching clean.sh format)
    echo ""

    local summary_heading="Purge complete"
    local -a summary_details=()
    local total_size_cleaned=0
    local total_items_cleaned=0

    if [[ -f "$stats_dir/purge_stats" ]]; then
        total_size_cleaned=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
        rm -f "$stats_dir/purge_stats"
    fi

    if [[ -f "$stats_dir/purge_count" ]]; then
        total_items_cleaned=$(cat "$stats_dir/purge_count" 2> /dev/null || echo "0")
        rm -f "$stats_dir/purge_count"
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        summary_heading="Dry run complete - no changes made"
    fi
    if [[ "$purge_outcome" == "incomplete" ]]; then
        summary_heading="Purge incomplete"
        [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && summary_heading="Dry run incomplete - no changes made"
    fi

    if [[ $total_items_cleaned -gt 0 ]]; then
        local freed_size_human
        freed_size_human=$(bytes_to_human_kb "$total_size_cleaned")

        local summary_line="Estimated space freed: ${GREEN}${freed_size_human}${NC}"
        if [[ "${MOLE_CLEAN_TRASH:-0}" == "1" ]]; then
            summary_line="Moved to Trash: ${GREEN}${freed_size_human}${NC}"
        fi
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            summary_line="Would free approximately: ${GREEN}${freed_size_human}${NC}"
        fi
        if [[ ${PURGE_UNKNOWN_SIZE_COUNT:-0} -gt 0 ]]; then
            summary_line+=" + ${PURGE_UNKNOWN_SIZE_COUNT} unmeasured"
        fi
        [[ $total_items_cleaned -gt 0 ]] && summary_line+=" | Items: $total_items_cleaned"
        summary_line+=" | Free: $(get_free_space)"
        summary_details+=("$summary_line")
    else
        summary_details+=("No artifacts were removed.")
        summary_details+=("Free space: $(get_free_space)")
    fi
    if [[ "$purge_outcome" == "incomplete" ]]; then
        summary_details+=("Some artifacts were skipped or could not be processed.")
    fi
    if [[ -n "$PURGE_APPLY_SKIPPED" ]]; then
        summary_details+=("Kept · $(mole_count_label "$(printf '%s\n' "$PURGE_APPLY_SKIPPED" | grep -c .)" item): $(format_clean_summary_list "$PURGE_APPLY_SKIPPED")")
    fi

    # Log session end
    log_operation_session_end "purge" "${total_items_cleaned:-0}" "${total_size_cleaned:-0}"

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
    [[ "$purge_outcome" == "completed" ]]
}

# Show help message
show_help() {
    echo -e "${PURPLE_BOLD}Mole Purge${NC}, Clean old project build artifacts"
    echo ""
    echo -e "${YELLOW}Usage:${NC} mo purge [options]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --paths         Edit custom scan directories"
    echo "  --dry-run       Preview purge actions without making changes"
    echo "  --include-empty Show zero-size project artifact directories"
    echo "  --yes           Confirm unattended cleanup of eligible artifacts"
    echo "  --json          With --dry-run, print the preview as a JSON plan"
    echo "  --apply ID --select FILE  Purge only the item ids FILE lists, from plan ID"
    echo "  --trash         Move purged artifacts to the Trash instead of deleting them"
    echo "  --debug         Enable debug logging"
    echo "  -h, --help      Show this help message"
    echo ""
    echo -e "${YELLOW}Default Paths:${NC}"
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        echo "  * $path"
    done
}

# Main entry point
main() {
    local purge_json=false
    local purge_trash=false
    local purge_apply_arg=""
    local purge_select_file=""
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--paths")
                source "$SCRIPT_DIR/../lib/manage/purge_paths.sh"
                manage_purge_paths
                exit 0
                ;;
            "--help" | "-h")
                show_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                export MOLE_DRY_RUN=1
                ;;
            "--yes")
                export MOLE_PURGE_YES=1
                ;;
            "--include-empty")
                export MOLE_PURGE_INCLUDE_EMPTY=1
                ;;
            "--json")
                purge_json=true
                ;;
            "--apply")
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "Missing plan id for --apply" >&2
                    echo "Run 'mo purge --dry-run --json' and pass its plan_id." >&2
                    exit 1
                fi
                purge_apply_arg="$1"
                ;;
            "--select")
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "Missing file for --select" >&2
                    echo "Use 'mo purge --apply <plan_id> --select <file>', the file listing the kept item ids." >&2
                    exit 1
                fi
                purge_select_file="$1"
                ;;
            "--trash")
                purge_trash=true
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Use 'mo purge --help' for usage information" >&2
                exit 1
                ;;
        esac
        shift
    done

    validate_purge_mode_flags "$purge_json" "$purge_trash" "$purge_apply_arg" "$purge_select_file" || exit 1

    # MOLE_APPLY_PLAN and MOLE_CLEAN_TRASH come only from this run's flags.
    unset MOLE_APPLY_PLAN
    MOLE_CLEAN_TRASH=0
    [[ "$purge_trash" == "true" ]] && MOLE_CLEAN_TRASH=1
    export MOLE_CLEAN_TRASH
    if [[ -n "$purge_apply_arg" ]]; then
        clean_plan_load_selection "$purge_apply_arg" "$purge_select_file" || exit 1
        PURGE_APPLY_PLAN_ID="$CLEAN_PLAN_ID"
    fi
    # The JSON document is the only thing on stdout; every other line of the
    # preview goes to stderr.
    if [[ "$purge_json" == "true" ]]; then
        exec 7>&1 1>&2
        CLEAN_PLAN_JSON_PENDING=true
        PURGE_PLAN_RECORDS_FILE=$(create_temp_file) || exit 1
    fi

    start_purge
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No project artifacts will be removed"
        printf '\n'
    fi
    hide_cursor
    if [[ -n "$PURGE_APPLY_PLAN_ID" ]]; then
        perform_purge_apply
    else
        perform_purge
    fi
}

# Each refusal names the conflict and the command to run instead.
validate_purge_mode_flags() {
    local json="$1" trash="$2" apply_arg="$3" select_file="$4"
    if [[ "$json" == "true" && "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        echo "mo purge --json prints a preview plan and needs --dry-run." >&2
        echo "Run 'mo purge --dry-run --json'." >&2
        return 1
    fi
    if [[ -n "$select_file" && -z "$apply_arg" ]]; then
        echo "mo purge --select needs --apply <plan_id>; the plain purge has no selection list." >&2
        echo "Run 'mo purge --dry-run --json', then 'mo purge --apply <plan_id> --select <file>'." >&2
        return 1
    fi
    if [[ -n "$apply_arg" && -z "$select_file" ]]; then
        echo "mo purge --apply needs --select <file> listing the item ids to purge." >&2
        echo "Run 'mo purge --apply $apply_arg --select <file>'." >&2
        return 1
    fi
    if [[ -n "$apply_arg" && "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo "mo purge --apply runs a reviewed plan and cannot be combined with --dry-run." >&2
        echo "Run 'mo purge --dry-run --json' to preview, then --apply without --dry-run." >&2
        return 1
    fi
    if [[ "$trash" == "true" && "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo "mo purge --trash changes where a real purge sends artifacts; a dry run removes nothing." >&2
        echo "Run 'mo purge --dry-run' to preview, then 'mo purge --trash'." >&2
        return 1
    fi
    return 0
}

if [[ "${MOLE_SKIP_MAIN:-0}" == "1" ]]; then
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 0
    else
        exit 0
    fi
fi

main "$@"
