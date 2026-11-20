#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

record() {
    cat "$XDG_CACHE_HOME/ws/open.tsv" 2>/dev/null
}

server_of() {
    tmux list-sessions -F '#{pid}-#{start_time}' 2>/dev/null | head -n 1
}

has_session() {
    tmux has-session -t "=$1:" 2>/dev/null
}

# Claude Code names the folder of a directory's conversations after its path, with each character but a letter or digit as -.
claude_dir() {
    local real
    real=$(realpath -m -- "$1")
    printf '%s\n' "$HOME/.claude/projects/${real//[^A-Za-z0-9]/-}"
}

converse() {
    { mkdir -p "$(claude_dir "$1")" && echo '{"type":"user"}' >"$(claude_dir "$1")/4b1f2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d.jsonl"; } ||
        abort "cannot write a conversation of $1"
}

subagents_only() {
    local d
    d=$(claude_dir "$1")
    {
        mkdir -p "$d/4b1f2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d/subagents" &&
            echo '{"type":"user"}' >"$d/4b1f2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d/subagents/agent-a1b2c3.jsonl" &&
            echo '{}' >"$d/4b1f2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d/subagents/agent-a1b2c3.meta.json" &&
            echo '{"type":"user"}' >"$d/agent-a1b2c3.jsonl"
    } || abort "cannot write the subagent transcripts of $1"
}

# The line the fake claude writes when it starts: its directory, a tab, and its arguments.
started() {
    wait_for_line "$FX/claude.started" "$(realpath -e -- "$1")"$'\t'"$2"
}

reboot() {
    local i
    tmux kill-server 2>/dev/null
    for ((i = 0; i < 100; i++)); do
        has_session "$1" || return 0
        sleep 0.05
    done
    abort "the tmux server did not stop"
}

wait_for_text() {
    local i
    for ((i = 0; i < 200; i++)); do
        grep -qF -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.05
    done
    return 1
}

test_reopen_continues_the_conversation() {
    new_fixture_no_ticket
    fake_fzf
    ws new t1 feat/x +alpha >/dev/null 2>&1
    assert "a ticket with no conversation starts claude -n t1 in the ticket" started "$WS_ROOT/t1" "-n t1"

    tmux kill-session -t "=t1:"
    converse "$WS_ROOT/t1"
    WS_FZF_PICK=$WS_ROOT/t1 ws pick >/dev/null 2>&1
    wait_refresh
    assert "pick reopens a ticket with a conversation as claude -c -n t1 in the ticket" started "$WS_ROOT/t1" "-c -n t1"
    assert_eq "the reopened session has its windows" "claude shell" "$(windows_of t1)"

    ws new t2 feat/y +alpha >/dev/null 2>&1
    tmux kill-session -t "=t2:"
    subagents_only "$WS_ROOT/t2"
    : >"$FX/claude.started"
    WS_FZF_PICK=$WS_ROOT/t2 ws pick >/dev/null 2>&1
    wait_refresh
    assert "subagent transcripts alone are no conversation: claude -n t2" started "$WS_ROOT/t2" "-n t2"
    refute "so no claude -c starts for t2" grep -q $'\t''-c ' "$FX/claude.started"

    ws new t_3 feat/z +alpha >/dev/null 2>&1
    tmux kill-session -t "=t_3:"
    converse "$WS_ROOT/t_3"
    ws new t_3 >/dev/null 2>&1
    assert "a rerun of new continues the conversation of t_3" started "$WS_ROOT/t_3" "-c -n t_3"

    tmux kill-session -t "=t1:"
    : >"$FX/claude.started"
    touch "$FX/claude.continue-fail"
    WS_FZF_PICK=$WS_ROOT/t1 ws pick >/dev/null 2>&1
    wait_refresh
    assert "when claude -c finds nothing to continue" started "$WS_ROOT/t1" "-c -n t1"
    assert "a fresh claude -n t1 starts in the window" started "$WS_ROOT/t1" "-n t1"
    assert_eq "and the window stays" "claude shell" "$(windows_of t1)"
    rm "$FX/claude.continue-fail"

    tmux kill-session -t "=t2:"
    { mkdir -p "$FX/cfg/projects" && mv "$(claude_dir "$WS_ROOT/t1")" "$FX/cfg/projects/$(basename "$(claude_dir "$WS_ROOT/t2")")"; } ||
        abort "cannot move the conversation under CLAUDE_CONFIG_DIR"
    CLAUDE_CONFIG_DIR=$FX/cfg ws new t2 >/dev/null 2>&1
    assert "a conversation under CLAUDE_CONFIG_DIR counts" started "$WS_ROOT/t2" "-c -n t2"
}

test_reopen_reads_what_claude_reads() {
    local d
    new_fixture_no_ticket
    fake_fzf
    ws new t4 feat/w +alpha >/dev/null 2>&1
    tmux kill-session -t "=t4:"
    d=$(claude_dir "$WS_ROOT/t4")
    { mkdir -p "$d" && : >"$d/4b1f2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d.jsonl"; } || abort "cannot write an empty transcript"
    : >"$FX/claude.started"
    ws new t4 >/dev/null 2>&1
    assert "an empty transcript is no conversation: claude -n t4" started "$WS_ROOT/t4" "-n t4"

    tmux kill-session -t "=t4:"
    { echo '{"type":"user"}' >"$FX/elsewhere.jsonl" &&
        ln -sf "$FX/elsewhere.jsonl" "$d/4b1f2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d.jsonl"; } || abort "cannot link a transcript"
    : >"$FX/claude.started"
    ws new t4 >/dev/null 2>&1
    assert "a linked transcript, which Claude Code skips, is no conversation: claude -n t4" started "$WS_ROOT/t4" "-n t4"

    ws new t5 feat/v +alpha >/dev/null 2>&1
    tmux kill-session -t "=t5:"
    converse "$WS_ROOT/t5"
    ln -s "$WS_ROOT" "$FX/work-link" || abort "cannot link the work dir"
    : >"$FX/claude.started"
    WS_ROOT=$FX/work-link WS_FZF_PICK=$FX/work-link/t5 ws pick >/dev/null 2>&1
    wait_refresh
    assert "through a linked WS_ROOT, the conversation of the real path counts" started "$WS_ROOT/t5" "-c -n t5"
}

test_refresh_records_open_tickets() {
    local first second i
    new_fixture_no_ticket
    ws new t1 feat/x +alpha >/dev/null 2>&1
    ws new t2 feat/y +alpha >/dev/null 2>&1
    ws status --refresh
    first=$(server_of)
    assert_eq "a refresh records each ticket whose session is open, with the tmux server that saw it" \
        "t1"$'\t'"$first"$'\t'"-"$'\n'"t2"$'\t'"$first"$'\t'"-" "$(record)"

    tmux kill-session -t "=t2:"
    ws status --refresh
    assert_eq "a session closed under the same server leaves the record" "t1"$'\t'"$first"$'\t'"-" "$(record)"

    reboot t1
    ws status --refresh
    assert_eq "with no tmux server, a refresh keeps the line of the server that stopped" \
        "t1"$'\t'"$first"$'\t'"-" "$(record)"
    ws new t3 feat/z +alpha >/dev/null 2>&1
    ws status --refresh
    second=$(server_of)
    assert_eq "the next server's refresh keeps that line and adds its own sessions" \
        "t1"$'\t'"$first"$'\t'"-"$'\n'"t3"$'\t'"$second"$'\t'"-" "$(record)"

    mv "$WS_ROOT/t1" "$FX/t1-gone"
    ws status --refresh
    assert_eq "a ticket whose directory is gone leaves the record" "t3"$'\t'"$second"$'\t'"-" "$(record)"

    for i in 1 2 3 4 5 6; do
        ws status --refresh &
    done
    ws pause >/dev/null 2>&1 &
    wait
    assert_eq "refreshes and a pause at once leave a whole record" "t3"$'\t'"$second"$'\t'"-" "$(record)"
    assert_eq "and no temp file" "" "$(find "$XDG_CACHE_HOME/ws" -name '.open.*')"
}

test_pause_marks_running_stacks() {
    local out rc server before
    new_fixture_no_ticket
    ws new t1 feat/x +alpha >/dev/null 2>&1
    ws new t2 feat/y +beta >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1 || abort "ws up t1 failed"
    out=$(ws pause 2>&1) && rc=0 || rc=$?
    server=$(server_of)
    assert_eq "pause exits 0" 0 "$rc"
    assert_eq "pause prints a line per ticket and marks the running stack" \
        $'t1 recorded, its stack runs\nt2 recorded' "$out"
    assert_eq "pause marks up the ticket whose stack runs" \
        "t1"$'\t'"$server"$'\t'"up"$'\n'"t2"$'\t'"$server"$'\t'"-" "$(record)"
    ws status --refresh
    assert_eq "a refresh keeps what pause marked" \
        "t1"$'\t'"$server"$'\t'"up"$'\n'"t2"$'\t'"$server"$'\t'"-" "$(record)"

    before=$(record)
    touch "$FX/docker.err"
    out=$(ws pause 2>&1) && rc=0 || rc=$?
    assert_eq "pause without docker exits 1" 1 "$rc"
    assert_eq "and says it records nothing" "ws: docker ps failed, so ws pause records nothing" "$out"
    assert_eq "the record stays as it was" "$before" "$(record)"
    rm "$FX/docker.err"

    ws down t1 >/dev/null 2>&1
    reboot t1
    out=$(ws pause 2>&1)
    assert_eq "pause after the env stopped, with no session open, keeps the lines unmarked" \
        $'t1 recorded, its session is not open\nt2 recorded, its session is not open' "$out"
    assert_eq "with the server that saw them" "t1"$'\t'"$server"$'\t'"-"$'\n'"t2"$'\t'"$server"$'\t'"-" "$(record)"
}

test_restore_makes_lost_sessions() {
    local out rc id
    new_fixture_no_ticket
    for id in t1 t2 t3 t4; do
        ws new "$id" "feat/$id" +alpha >/dev/null 2>&1
    done
    converse "$WS_ROOT/t1"
    ws status --refresh
    tmux kill-session -t "=t4:"
    ws status --refresh
    reboot t1
    mv "$WS_ROOT/t3" "$FX/t3-gone"
    : >"$FX/claude.started"
    out=$(ws restore 2>&1) && rc=0 || rc=$?
    assert_eq "restore exits 0" 0 "$rc"
    assert_eq "restore prints a line per recorded ticket" \
        $'t1 restored\nt2 restored\nt3 skipped (no ticket ~/work/t3)' "$out"
    assert_eq "t1 has its windows again" "claude shell" "$(windows_of t1)"
    assert_eq "t2 has its windows again" "claude shell" "$(windows_of t2)"
    assert "t1 continues its conversation" started "$WS_ROOT/t1" "-c -n t1"
    assert "t2, with none, starts claude -n t2" started "$WS_ROOT/t2" "-n t2"
    refute "a session closed on purpose stays closed" has_session t4
    refute "a ticket that is gone gets no session" has_session t3

    out=$(ws restore 2>&1) && rc=0 || rc=$?
    assert_eq "a second restore exits 0" 0 "$rc"
    assert_eq "and skips the open sessions; the first restore dropped the ticket that is gone" \
        $'t1 skipped (its session is open)\nt2 skipped (its session is open)' "$out"

    ws status --refresh
    reboot t1
    tmux new-session -d -s t2 -c "$FX" || abort "cannot make a foreign session t2"
    printf 'garbage\n' >"$WS_ROOT/t1/.ws"
    out=$(ws restore 2>&1) && rc=0 || rc=$?
    assert_eq "restore exits 1 when a ticket fails" 1 "$rc"
    assert_eq "it names why each failed" \
        $'t1 failed (line 1 of ~/work/t1/.ws is not KEY=value)\nt2 failed (tmux session t2 works in ~, not ~/work/t2)' "$out"
}

test_restore_writes_the_record() {
    local out
    new_fixture_no_ticket
    ws new t1 feat/x +alpha >/dev/null 2>&1
    ws new t2 feat/y +alpha >/dev/null 2>&1
    ws status --refresh
    reboot t1
    ws restore >/dev/null 2>&1
    assert_eq "restore records the sessions it made under the new server" \
        "t1"$'\t'"$(server_of)"$'\t'"-"$'\n'"t2"$'\t'"$(server_of)"$'\t'"-" "$(record)"
    tmux kill-session -t "=t2:"
    ws status --refresh
    reboot t1
    out=$(ws restore 2>&1)
    assert_eq "so a session closed before any refresh saw it does not come back" "t1 restored" "$out"
}

test_two_restores_at_once() {
    local id rc1 rc2 pid1 pid2
    new_fixture_no_ticket
    for id in t1 t2 t3 t4; do
        ws new "$id" "feat/$id" +alpha >/dev/null 2>&1
    done
    ws status --refresh
    reboot t1
    ws restore >"$FX/restore.1" 2>&1 &
    pid1=$!
    ws restore >"$FX/restore.2" 2>&1 &
    pid2=$!
    wait "$pid1" && rc1=0 || rc1=$?
    wait "$pid2" && rc2=0 || rc2=$?
    assert_eq "both restores exit 0" "0 0" "$rc1 $rc2"
    for id in t1 t2 t3 t4; do
        assert_eq "$id has one claude window and one shell window" "claude shell" "$(windows_of "$id")"
        assert_eq "one restore made $id and the other skipped it" \
            "$id restored|$id skipped (its session is open)" \
            "$(cat "$FX/restore.1" "$FX/restore.2" | grep "^$id " | sort | paste -sd '|')"
    done
}

test_restore_up() {
    local out rc ups
    new_fixture_no_ticket
    ws new t1 feat/x +alpha >/dev/null 2>&1
    ws new t2 feat/y +beta >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1 || abort "ws up t1 failed"
    ws pause >/dev/null 2>&1 || abort "ws pause failed"
    reboot t1
    echo '[]' >"$FX/docker.json"
    ups=$(grep -c $'\tup ' "$FX/dockyard.log")
    out=$(ws restore 2>&1) && rc=0 || rc=$?
    assert_eq "restore without --up exits 0" 0 "$rc"
    assert_eq "and only makes the sessions" $'t1 restored\nt2 restored' "$out"
    assert_eq "it starts no env" "$ups" "$(grep -c $'\tup ' "$FX/dockyard.log")"

    reboot t1
    out=$(ws restore --up 2>&1) && rc=0 || rc=$?
    assert_eq "restore --up exits 0" 0 "$rc"
    assert_eq "it starts the env that pause marked" $'t1 restored, env up\nt2 restored' "$out"
    assert_eq "with one dockyard up of t1's branch" "$((ups + 1))" "$(grep -c $'\tup feat/x$' "$FX/dockyard.log")"
    refute "and none of t2's" grep -q $'\tup feat/y' "$FX/dockyard.log"

    echo '[]' >"$FX/docker.json"
    out=$(ws restore --up 2>&1) && rc=0 || rc=$?
    assert_eq "--up starts a marked env also when its session is open" \
        $'t1 skipped (its session is open), env up\nt2 skipped (its session is open)' "$out"

    echo '[]' >"$FX/docker.json"
    touch "$FX/dockyard.build"
    out=$(ws restore --up 2>&1) && rc=0 || rc=$?
    assert_eq "restore --up exits 1 when an env fails" 1 "$rc"
    assert_eq "and names why" \
        $'t1 skipped (its session is open), env failed (dockyard up feat/x failed with status 1)\nt2 skipped (its session is open)' "$out"
}

test_restore_once() {
    local out rc log
    new_fixture_no_ticket
    log=$XDG_CACHE_HOME/ws/restore.log
    ws new t1 feat/x +alpha >/dev/null 2>&1
    ws status --refresh
    reboot t1
    out=$(ws restore --once 2>&1) && rc=0 || rc=$?
    assert_eq "the first --once exits 0 and prints nothing" "0:" "$rc:$out"
    assert "it makes the session" has_session t1
    assert "it writes its lines to the log" grep -qxF "t1 restored" "$log"
    assert "it makes the marker" test -f "$XDG_RUNTIME_DIR/ws-restore.once"

    reboot t1
    out=$(ws restore --once 2>&1) && rc=0 || rc=$?
    assert_eq "a second --once with the marker exits 0 and prints nothing" "0:" "$rc:$out"
    refute "and makes no session" has_session t1
    assert_eq "the log holds one run" 1 "$(grep -c ' ws restore --once$' "$log")"

    rm "$XDG_RUNTIME_DIR/ws-restore.once"
    ws restore --once
    assert "without the marker, as after a boot, --once runs again" has_session t1
    assert_eq "the log holds two runs" 2 "$(grep -c ' ws restore --once$' "$log")"

    reboot t1
    rm "$XDG_RUNTIME_DIR/ws-restore.once"
    out=$(XDG_RUNTIME_DIR=$FX/none ws restore --once 2>&1) && rc=0 || rc=$?
    assert_eq "--once without a runtime dir exits 1 and prints nothing" "1:" "$rc:$out"
    assert "it logs why" grep -qxF "ws: restore --once needs XDG_RUNTIME_DIR, the directory that a boot clears" "$log"
    refute "and makes no session" has_session t1

    mkdir -m 500 "$FX/run-ro" || abort "cannot make a read-only runtime dir"
    out=$(XDG_RUNTIME_DIR=$FX/run-ro ws restore --once 2>&1) && rc=0 || rc=$?
    assert_eq "--once that cannot make its marker exits 1 and prints nothing" "1:" "$rc:$out"
    assert "it logs why" grep -qxF "ws: cannot make $FX/run-ro/ws-restore.once" "$log"
    refute "and makes no session" has_session t1
}

test_restore_reads_a_broken_or_missing_record() {
    local out rc server
    new_fixture_no_ticket
    ws new t1 feat/x +alpha >/dev/null 2>&1
    out=$(ws restore 2>&1) && rc=0 || rc=$?
    assert_eq "restore with no record exits 0" 0 "$rc"
    assert_eq "and says so" "No ticket was open, so ws restore makes no session." "$out"

    reboot t1
    mkdir -p "$XDG_CACHE_HOME/ws"
    printf 'garbage\nt1\t12-34\t-\nbad id\t1-2\t-\nt1\t5-6\tup\nt9\t1-2\tmaybe\nt2\t7-8' >"$XDG_CACHE_HOME/ws/open.tsv"
    out=$(ws restore 2>&1) && rc=0 || rc=$?
    assert_eq "restore of a broken record exits 1" 1 "$rc"
    assert_eq "it names each line that is no ticket, and restores the rest" \
        "$(printf 'ws: line %s of ~/.cache/ws/open.tsv is not <id> <server> <up or ->, so ws skips it\n' 1 3 4 5 6)"$'\nt1 restored' \
        "$out"
    ws status --refresh
    server=$(server_of)
    assert_eq "the next refresh writes the record whole" "t1"$'\t'"$server"$'\t'"-" "$(record)"

    rm "$XDG_CACHE_HOME/ws/open.tsv"
    mkdir "$XDG_CACHE_HOME/ws/open.tsv"
    out=$(ws restore 2>&1) && rc=0 || rc=$?
    assert_eq "a record that is no file makes restore exit 1" 1 "$rc"
    assert_eq "and says why" "ws: ~/.cache/ws/open.tsv is not a readable file" "$out"
}

hook_runs() {
    grep -cx '0 restore --once' "$FX/ws-hook.log" 2>/dev/null
}

test_boot_hook() {
    local conf=$WS_TESTS/../../dotfiles/tmux/.tmux.conf log i
    new_fixture_no_ticket
    log=$XDG_CACHE_HOME/ws/restore.log
    # The hook's ws waits for hook.go, so the test sees tmux return first, and logs its end so the fixture outlives it.
    cat >"$FX/bin/ws" <<EOF
#!/usr/bin/env bash
for ((i = 0; i < 200; i++)); do
    [[ -e $(printf %q "$FX/hook.go") ]] && break
    sleep 0.05
done
bash $(printf %q "$WS_TESTS/../../dotfiles/bin/ws") "\$@"
printf '%s %s\n' "\$?" "\$*" >>$(printf %q "$FX/ws-hook.log")
EOF
    ws new t1 feat/x +alpha >/dev/null 2>&1
    converse "$WS_ROOT/t1"
    ws status --refresh
    reboot t1
    : >"$FX/claude.started"
    tmux -f "$conf" new-session -d -s main || abort "tmux did not start with the config"
    assert "tmux starts its first session while the hook still runs" has_session main
    refute "the hook has restored nothing yet" grep -qsF "t1 restored" "$log"
    touch "$FX/hook.go"
    assert "the first server with the config runs ws restore --once" wait_for_text "$log" "t1 restored"
    assert "which makes the session of t1" has_session t1
    assert "whose claude window continues the conversation" started "$WS_ROOT/t1" "-c -n t1"
    for ((i = 0; i < 200; i++)); do
        (($(hook_runs) >= 1)) && break
        sleep 0.05
    done
    tmux source-file "$conf" || abort "tmux cannot read the config again"
    for ((i = 0; i < 200; i++)); do
        (($(hook_runs) >= 2)) && break
        sleep 0.05
    done
    assert_eq "a reload runs the hook again, and both runs exit 0" 2 "$(hook_runs)"
    assert_eq "but only the first restored" 1 "$(grep -c ' ws restore --once$' "$log")"
}

test_help() {
    local out rc
    new_fixture_no_ticket
    out=$(ws -h)
    assert "ws -h lists pause" grep -qE '^  pause +record the open ticket sessions' <<<"$out"
    assert "ws -h lists restore" grep -qE '^  restore +make the tmux sessions of the tickets that were open' <<<"$out"
    for cmd in restore pause; do
        out=$(ws "$cmd" -h) && rc=0 || rc=$?
        assert_eq "ws $cmd -h exits 0" 0 "$rc"
        assert "ws $cmd -h shows its usage line" grep -qE "^       ws $cmd( |$)" <<<"$out"
        assert "ws $cmd -h explains it" grep -qE "^  $cmd +[a-z]" <<<"$out"
    done
    out=$(ws restore --bogus 2>&1) && rc=0 || rc=$?
    assert_eq "restore refuses an unknown flag" 1 "$rc"
    out=$(ws pause t1 2>&1) && rc=0 || rc=$?
    assert_eq "pause takes no argument" 1 "$rc"
}

run_test test_reopen_continues_the_conversation
run_test test_reopen_reads_what_claude_reads
run_test test_refresh_records_open_tickets
run_test test_pause_marks_running_stacks
run_test test_restore_makes_lost_sessions
run_test test_restore_writes_the_record
run_test test_two_restores_at_once
run_test test_restore_up
run_test test_restore_once
run_test test_restore_reads_a_broken_or_missing_record
run_test test_boot_hook
run_test test_help
finish
