#!/bin/bash
# Stand-in for `mo` used by MoleReviewChecks and for exercising the app's apply path.
# FAKE_MO_ARGV_FILE: record argv (one per line); FAKE_MO_STDOUT_FILE: printed on stdout;
# FAKE_MO_STDERR: text for stderr; FAKE_MO_EXIT: exit code.
# `--slow`: spawn a background grandchild `sleep` (pid written to FAKE_MO_PIDFILE), then wait.
# `history --json`: prints FAKE_MO_HISTORY_FILE with RUNID replaced by FAKE_MO_RUN_ID, and
#   OPLOG replaced by FAKE_MO_OPLOG (the `logs.operations` path).
# FAKE_MO_PRINT_RUN_ID: set, `--apply` prints `Run id: <FAKE_MO_RUN_ID>` on stdout like a current mo.
# FAKE_MO_PROGRESS_FILE: `--apply` prints it on stdout after the run id, line by line with a short
#   pause between lines, the way a real apply prints its progress.
# FAKE_MO_STATE: `<command> --apply` records its start and end time here (history's STARTED/ENDED).
# `<command> --apply` (clean, purge or installer alike): appends FAKE_MO_OPLOG_ROWS (real
#   operations.log row formats, RUNID replaced, NOW by the current time) to FAKE_MO_OPLOG, as a
#   real apply run does.
if [[ -n "${FAKE_MO_ARGV_FILE:-}" && "${1:-}" != "history" ]]; then
    printf '%s\n' "$@" > "$FAKE_MO_ARGV_FILE"
fi
[[ "${1:-}" == "--version" ]] && {
    echo "Mole fake 0.0.0"
    exit 0
}
if [[ "${1:-}" == "history" ]]; then
    started="" ended=""
    [[ -f "${FAKE_MO_STATE:-/nonexistent}" ]] && {
        started=$(sed -n 1p "$FAKE_MO_STATE")
        ended=$(sed -n 2p "$FAKE_MO_STATE")
    }
    sed -e "s|RUNID|${FAKE_MO_RUN_ID:-}|g" -e "s|OPLOG|${FAKE_MO_OPLOG:-}|g" \
        -e "s|STARTED|$started|g" -e "s|ENDED|$ended|g" "${FAKE_MO_HISTORY_FILE:-/dev/null}"
    exit 0
fi
[[ "$*" == *"--apply"* && -n "${FAKE_MO_STATE:-}" ]] && date '+%Y-%m-%d %H:%M:%S' > "$FAKE_MO_STATE"
if [[ "$*" == *"--apply"* && -n "${FAKE_MO_OPLOG:-}" && -n "${FAKE_MO_OPLOG_ROWS:-}" ]]; then
    sed -e "s|RUNID|${FAKE_MO_RUN_ID:-}|g" -e "s|NOW|$(date '+%Y-%m-%d %H:%M:%S')|g" "$FAKE_MO_OPLOG_ROWS" >> "$FAKE_MO_OPLOG"
fi
[[ "$*" == *"--apply"* && -n "${FAKE_MO_PRINT_RUN_ID:-}" ]] && echo "Run id: ${FAKE_MO_RUN_ID:-}"
if [[ "$*" == *"--apply"* && -n "${FAKE_MO_PROGRESS_FILE:-}" ]]; then
    while IFS= read -r progress_line || [[ -n "$progress_line" ]]; do
        printf '%s\n' "$progress_line"
        sleep 0.02
    done < "$FAKE_MO_PROGRESS_FILE"
fi
[[ -n "${FAKE_MO_STDERR:-}" ]] && printf '%s\n' "$FAKE_MO_STDERR" >&2
[[ -n "${FAKE_MO_STDOUT_FILE:-}" ]] && cat "$FAKE_MO_STDOUT_FILE"
for a in "$@"; do
    if [[ "$a" == "--slow" ]]; then
        sleep 30 &
        [[ -n "${FAKE_MO_PIDFILE:-}" ]] && echo $! > "$FAKE_MO_PIDFILE"
        wait
        exit 0
    fi
done
[[ "$*" == *"--apply"* && -n "${FAKE_MO_STATE:-}" ]] && date '+%Y-%m-%d %H:%M:%S' >> "$FAKE_MO_STATE"
exit "${FAKE_MO_EXIT:-0}"
