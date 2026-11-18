#!/usr/bin/env bash

# This sourced contract deliberately replaces functions and assigns globals
# consumed indirectly by either command under test.
# shellcheck disable=SC2034,SC2329

verify_progress_contract() {
    local test_dir=$1
    local expected_date=$2
    local progress_pid
    local progress_launch_definition

    command -v progress_elapsed_suffix >/dev/null
    command -v progress_duration_suffix >/dev/null
    [[ -z $(progress_elapsed_suffix 49) ]]
    [[ $(progress_elapsed_suffix 50) == ' — elapsed 5s' ]]
    [[ $(progress_elapsed_suffix 99) == ' — elapsed 9s' ]]
    [[ -z $(progress_duration_suffix 99) ]]
    [[ $(progress_duration_suffix 100) == ' (took 10.0s)' ]]
    [[ $(progress_duration_suffix 123) == ' (took 12.3s)' ]]

    # Force the interactive path while controlling both clocks. The wall clock
    # moves backward, while the monotonic duration remains 12.3 seconds.
    progress_stderr_is_interactive() { return 0; }
    PROGRESS_TEST_WALL_CALL=0
    progress_capture_wall_time() {
        ((PROGRESS_TEST_WALL_CALL += 1))
        if (( PROGRESS_TEST_WALL_CALL == 1 )); then
            PROGRESS_CAPTURED_WALL_TIME='14:07:03'
        else
            PROGRESS_CAPTURED_WALL_TIME='13:59:59'
        fi
    }
    PROGRESS_TEST_MONOTONIC_CALL=0
    progress_capture_monotonic_tenths() {
        ((PROGRESS_TEST_MONOTONIC_CALL += 1))
        if (( PROGRESS_TEST_MONOTONIC_CALL == 1 )); then
            PROGRESS_CAPTURED_TENTHS=100
        else
            PROGRESS_CAPTURED_TENTHS=223
        fi
    }
    PROGRESS_UPDATE_INTERVAL=0.2
    progress_launch_definition=$(declare -f progress_launch_updater)
    progress_launch_updater() { PROGRESS_UPDATER_PID=''; }
    reset_operational_output
    PROGRESS_ACTIVE=0
    PROGRESS_UPDATER_PID=''
    {
        progress_start 'optimizing document'
        progress_finish
    } 2>"$test_dir/progress.err"
    {
        printf '[%s]\n' "$expected_date"
        printf '\r\033[2K[14:07:03] | optimizing document'
        printf '\r\033[2K[13:59:59] optimizing document (took 12.3s)\n'
    } >"$test_dir/progress.expected"
    cmp "$test_dir/progress.expected" "$test_dir/progress.err"
    eval "$progress_launch_definition"

    # Verbose output keeps its ordinary diagnostics and does not animate.
    reset_operational_output
    VERBOSE=1
    progress_start 'must remain hidden' 2>"$test_dir/progress-verbose.err"
    progress_finish 2>>"$test_dir/progress-verbose.err"
    [[ ! -s $test_dir/progress-verbose.err ]]

    # Redirection disables progress without emitting carriage returns or ANSI.
    progress_stderr_is_interactive() { [[ -t 2 ]]; }
    reset_operational_output
    progress_start 'must remain redirected' 2>"$test_dir/progress-redirected.err"
    progress_finish 2>>"$test_dir/progress-redirected.err"
    [[ ! -s $test_dir/progress-redirected.err ]]

    # Canceling an active stage terminates its updater and clears the live line.
    progress_stderr_is_interactive() { return 0; }
    PROGRESS_TEST_WALL_CALL=0
    PROGRESS_TEST_MONOTONIC_CALL=0
    reset_operational_output
    PROGRESS_ACTIVE=0
    PROGRESS_UPDATER_PID=''
    progress_start 'interrupted stage' 2>"$test_dir/progress-cancel.err"
    progress_pid=$PROGRESS_UPDATER_PID
    [[ -n $progress_pid ]]
    kill -0 "$progress_pid" 2>/dev/null
    progress_cancel 2>>"$test_dir/progress-cancel.err"
    if kill -0 "$progress_pid" 2>/dev/null; then
        printf '%s\n' 'progress updater remained alive after cancellation' >&2
        return 1
    fi
    [[ $PROGRESS_ACTIVE -eq 0 && -z $PROGRESS_UPDATER_PID ]]
}
