#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

ws_value() {
    sed -n "s/^$2=//p" "$WS_ROOT/$1/.ws"
}

slot_of() {
    jq -r --arg s "$1" '.[$s].slot // empty' "$HOME/.dockyard/slots.json" 2>/dev/null
}

containers_of() {
    jq -r --arg p "dockyard-$1" '[.[] | select(.Labels["com.docker.compose.project"] == $p)] | length' "$FX/docker.json"
}

volumes_of() {
    grep -c "^dockyard-$1_" "$FX/volumes.txt" 2>/dev/null
}

dockyard_calls() {
    cut -f2 "$FX/dockyard.log" 2>/dev/null | grep -cx -- "$1"
}

has_session() {
    tmux has-session -t "=$1:" 2>/dev/null
}

ls_row() {
    ws ls | grep "^$1 "
}

pane_shows() {
    local i
    for ((i = 0; i < 300; i++)); do
        tmux capture-pane -p -S - -t "=$1:$2" 2>/dev/null | grep -qF -- "$3" && return 0
        sleep 0.05
    done
    return 1
}

pane_runs() {
    local i
    for ((i = 0; i < 100; i++)); do
        [[ $(tmux display-message -p -t "=$1:$2" '#{pane_current_command}' 2>/dev/null) == "$3" ]] && return 0
        sleep 0.05
    done
    return 1
}

answer() {
    printf '%s\n' "${@:2}" >"$FX/http/$1"
}

alive() {
    kill -0 "$1" 2>/dev/null
}

shell_ready() {
    pane_runs "$1" env "${SHELL##*/}" || abort "the env window of $1 runs no shell"
}

pane_of() {
    tmux display-message -p -t "=$1:env" '#{pane_id} #{pane_pid}'
}

child_of() {
    local i kid
    for ((i = 0; i < 100; i++)); do
        kid=$(ps -o pid= --ppid "$1" | head -n 1)
        if [[ -n $kid ]]; then
            echo "${kid// /}"
            return 0
        fi
        sleep 0.05
    done
    return 1
}

in_env_window() {
    local i
    cat >"$FX/ws-here" <<EOF
#!/usr/bin/env bash
for p in "\$HOME" "\$WS_ROOT" "\$WS_PROJECTS" "\$XDG_DATA_HOME"; do
    [[ \$(realpath -m -- "\$p") == $(printf %q "$_sandbox")/* ]] || { echo "ws refused: \$p" >&2; exit 99; }
done
for c in claude tmux dockyard doppler curl docker; do
    p=\$(type -P "\$c") && [[ \$(realpath -m -- "\$p") == $(printf %q "$_sandbox")/* ]] ||
        { echo "ws refused: \$c" >&2; exit 99; }
done
unset TMUX_PANE
bash $(printf %q "$WS_TESTS/../../dotfiles/bin/ws") "\$@" >$(printf %q "$FX/here.out") 2>&1
echo \$? >$(printf %q "$FX/here.rc")
EOF
    rm -f "$FX/here.rc"
    tmux send-keys -t "=$1:env" "bash $(printf %q "$FX/ws-here") ${*:2}" Enter
    for ((i = 0; i < 200; i++)); do
        [[ ! -s $FX/here.rc ]] || return 0
        sleep 0.05
    done
    return 1
}

claude_md_of_2_0_72() {
    cat <<EOF
# Ticket $1

ws wrote this file. It imports no other file. \`ws new $1\` writes it again until you edit it.

- Each repo directory here is a git worktree on branch \`$2\`.
  - \`$3/\` belongs to \`~/projects/$3\`.
- \`.ws\` holds the ticket state, and only ws writes it. Run \`ws stage <stage>\` here to move the ticket on.
- Log progress with \`~/vault/bin/vault-log $1 "<what changed>"\`.
EOF
}

test_up() {
    local out rc real
    new_fixture_no_ticket
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    shell_ready t1
    real=$(realpath -e "$WS_ROOT/t1")
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up exits 0" 0 "$rc"
    assert_eq "up runs dockyard up on the ticket branch with the ticket as its workspace" "$real"$'\t'"up feat/x" \
        "$(cat "$FX/dockyard.log")"
    assert "up shows what dockyard prints" grep -qF "Allocated slot 1" <<<"$out"
    assert_eq ".ws holds the slot" 1 "$(ws_value t1 WS_SLOT)"
    assert_eq ".ws holds each URL that dockyard printed" '"web-ui=http://localhost:4100 api-gateway=http://localhost:8100"' \
        "$(ws_value t1 WS_URLS)"
    # shellcheck disable=SC2016
    assert_eq "a shell that sources .ws reads the slot and URLs" "1|web-ui=http://localhost:4100 api-gateway=http://localhost:8100" \
        "$(env -i bash -c 'source "$1" && echo "$WS_SLOT|$WS_URLS"' _ "$WS_ROOT/t1/.ws")"
    assert_eq "the stack runs" 3 "$(containers_of feat-x)"
    assert "CLAUDE.md names the slot" grep -qF "The dockyard env runs on slot 1." "$WS_ROOT/t1/CLAUDE.md"
    assert "CLAUDE.md lists the web-ui URL" grep -qxF -- "- web-ui: http://localhost:4100" "$WS_ROOT/t1/CLAUDE.md"
    assert "CLAUDE.md lists the gateway URL" grep -qxF -- "- api-gateway: http://localhost:8100" "$WS_ROOT/t1/CLAUDE.md"
    assert "ls shows env:up" grep -q " env:up " <<<"$(ls_row t1)"
    assert "the env window tails the logs of the stack" pane_shows t1 env "dockyard-feat-x | fixture log line"
    assert_eq "the session keeps its windows" "claude shell env" \
        "$(tmux list-windows -t "=t1:" -F '#{window_name}' | paste -sd ' ')"

    sed -i 's/^WS_URLS=.*/WS_URLS=/' "$WS_ROOT/t1/.ws"
    ws up t1 >/dev/null 2>&1
    assert_eq "up of a running stack whose .ws lost its URLs runs dockyard up again" 2 "$(dockyard_calls "up feat/x")"
    assert "it records the URLs" grep -qF "web-ui=http://localhost:4100" <<<"$(ws_value t1 WS_URLS)"

    jq '."feat-x".slot = 3' "$HOME/.dockyard/slots.json" >"$FX/slots.new" && mv "$FX/slots.new" "$HOME/.dockyard/slots.json"
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up of a stack that dockyard moved to another slot runs dockyard up again" 3 "$(dockyard_calls "up feat/x")"
    refute "it does not call it already up" grep -qF "already up" <<<"$out"
    assert_eq ".ws holds the new slot" 3 "$(ws_value t1 WS_SLOT)"
    assert "and its URLs" grep -qF "web-ui=http://localhost:4300" <<<"$(ws_value t1 WS_URLS)"
}

test_up_passes_the_profiles_of_the_ticket_repos() {
    local out rc real
    new_fixture_no_ticket
    add_repo gamma
    ws_config 'WS_DEFAULT_REPOS=alpha' 'WS_UP_PROFILES="beta:worker gamma:portal gamma:worker"'
    ws new t1 feat/x beta gamma >/dev/null 2>&1
    real=$(realpath -e "$WS_ROOT/t1")
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up exits 0" 0 "$rc"
    assert_eq "up passes each profile of the ticket repos once, in repo order" \
        "$real"$'\tup feat/x --profile worker,portal' "$(cat "$FX/dockyard.log")"
    refute "it names no repo, since each is a default or has a profile" grep -qF "no dockyard service" <<<"$out"
    assert_eq ".ws holds the slot" 1 "$(ws_value t1 WS_SLOT)"

    ws down t1 >/dev/null 2>&1
    WS_UP_PROFILES=beta:aws ws up t1 >/dev/null 2>&1
    assert_eq "WS_UP_PROFILES in the environment wins over the config" 1 "$(dockyard_calls "up feat/x --profile aws")"
}

test_up_names_the_repos_without_a_service() {
    local out rc
    new_fixture_no_ticket
    add_repo gamma
    add_repo delta
    ws_config 'WS_DEFAULT_REPOS=alpha' 'WS_UP_PROFILES=gamma:portal'
    ws new --only t1 feat/x delta beta >/dev/null 2>&1
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up of a ticket with no default or mapped repo exits 0" 0 "$rc"
    assert_eq "it runs dockyard up as before, so the core stack starts" 1 "$(dockyard_calls "up feat/x")"
    assert_eq "it names each repo that is neither a default nor mapped, one line each" \
        $'delta has no dockyard service, so ws up does not start it\nbeta has no dockyard service, so ws up does not start it' \
        "$(grep -F "no dockyard service" <<<"$out")"

    rm "$XDG_CONFIG_HOME/ws/config"
    ws new t2 feat/y beta >/dev/null 2>&1
    out=$(ws up t2 2>&1) && rc=0 || rc=$?
    refute "without either setting, up names no repo" grep -qF "no dockyard service" <<<"$out"
    assert_eq "and runs dockyard up as before" 1 "$(dockyard_calls "up feat/y")"
}

test_up_refuses_a_bad_profile_pair() {
    local out rc
    new_fixture_no_ticket
    ws_config 'WS_UP_PROFILES="beta:portal gamma"'
    ws new t1 feat/x alpha >/dev/null 2>&1
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up exits 1 on a WS_UP_PROFILES word that is not repo:profile" 1 "$rc"
    assert_eq "it names the word and the config" \
        "ws: WS_UP_PROFILES in ~/.config/ws/config holds 'gamma', which is not <repo>:<profile>" "$out"
    refute "it runs no dockyard call" test -e "$FX/dockyard.log"
}

test_up_twice() {
    local out rc pane
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    shell_ready t1
    ws up t1 >/dev/null 2>&1
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "a second up exits 0" 0 "$rc"
    assert "it says the env is already up" grep -qxF "The env of t1 is already up on slot 1." <<<"$out"
    assert "it lists the URLs" grep -qxF "  web-ui http://localhost:4100" <<<"$out"
    refute "it reports no write error for a CLAUDE.md that needs no change" grep -qF "cannot write" <<<"$out"
    assert_eq "it runs dockyard up once in all" 1 "$(dockyard_calls "up feat/x")"
    assert "the env window tails the logs again" pane_shows t1 env "dockyard-feat-x | fixture log line"

    echo '[]' >"$FX/docker.json"
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up of a stack whose containers stopped exits 0" 0 "$rc"
    assert_eq "it runs dockyard up again" 2 "$(dockyard_calls "up feat/x")"
    assert "dockyard restarts the registered stack" grep -qF "Stack already registered (slot 1)" <<<"$out"
    assert_eq "the stack runs again" 2 "$(containers_of feat-x)"

    tmux kill-window -t "=t1:env"
    ws up t1 >/dev/null 2>&1
    assert "up puts back a missing env window and tails the logs" pane_shows t1 env "dockyard-feat-x | fixture log line"

    pane=$(tmux display-message -p -t "=t1:env" '#{pane_id} #{pane_pid}')
    out=$(TMUX_PANE=${pane% *} ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up run in the env window exits 0" 0 "$rc"
    assert "it says how to tail the logs" \
        grep -qF "Tail the logs with: docker compose -p dockyard-feat-x logs --follow --tail 50" <<<"$out"
    assert_eq "it leaves the pane it runs in" "$pane" "$(tmux display-message -p -t "=t1:env" '#{pane_id} #{pane_pid}')"

    tmux respawn-window -k -t "=t1:env" "sleep 300"
    pane_runs t1 env sleep || abort "the env window does not run sleep"
    pane=$(tmux display-message -p -t "=t1:env" '#{pane_id} #{pane_pid}')
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up while the env window runs another program exits 0" 0 "$rc"
    assert "it says it leaves that program" grep -qF "The env window of t1 is in use, so ws leaves it." <<<"$out"
    assert_eq "it does not kill that program" "$pane" "$(tmux display-message -p -t "=t1:env" '#{pane_id} #{pane_pid}')"

    tmux kill-session -t "=t1:"
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up without the tmux session exits 0" 0 "$rc"
    refute "it makes no tmux session" has_session t1
}

test_down() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    out=$(ws down t1 2>&1) && rc=0 || rc=$?
    assert_eq "down exits 0" 0 "$rc"
    assert_eq "down runs dockyard down on the ticket branch" 1 "$(dockyard_calls "down feat/x")"
    assert_eq "the containers stop" 0 "$(containers_of feat-x)"
    assert_eq "the slot stays in slots.json" 1 "$(slot_of feat-x)"
    assert_eq "the volumes stay" 2 "$(volumes_of feat-x)"
    assert_eq ".ws keeps the slot" 1 "$(ws_value t1 WS_SLOT)"
    assert_eq ".ws has no URLs" "" "$(ws_value t1 WS_URLS)"
    assert "down says the slot stays" grep -qxF "The env of t1 is down and keeps slot 1." <<<"$out"
    assert "CLAUDE.md says the env is down" grep -qF "The dockyard env is down and keeps slot 1." "$WS_ROOT/t1/CLAUDE.md"
    refute "CLAUDE.md lists no URL" grep -qF "http://localhost" "$WS_ROOT/t1/CLAUDE.md"
    assert "ls shows env:down" grep -q " env:down " <<<"$(ls_row t1)"

    ws up t1 >/dev/null 2>&1
    assert_eq "up after down keeps the slot" 1 "$(ws_value t1 WS_SLOT)"
    assert "up after down records the URLs again" grep -qF "web-ui=http://localhost:4100" <<<"$(ws_value t1 WS_URLS)"

    out=$(cd "$WS_ROOT/t1/alpha" && ws down 2>&1) && rc=0 || rc=$?
    assert_eq "down inside the ticket takes no id" 0 "$rc"
    assert_eq "it stops the stack" 0 "$(containers_of feat-x)"

    ws up t1 >/dev/null 2>&1
    touch "$FX/dockyard.down-fail"
    out=$(ws down t1 2>&1) && rc=0 || rc=$?
    assert_eq "down exits with dockyard's status when dockyard down fails and the stack runs" 1 "$rc"
    assert "it names the failed command" grep -qxF "ws: dockyard down feat/x failed with status 1" <<<"$out"
    assert "it keeps the URLs" grep -qF "web-ui=" <<<"$(ws_value t1 WS_URLS)"
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm refuses while dockyard down fails and the stack runs" 1 "$rc"
    assert "rm says it kept the ticket" grep -qxF "ws: kept t1" <<<"$out"
    assert "the ticket stays" test -f "$WS_ROOT/t1/.ws"

    echo '[]' >"$FX/docker.json"
    out=$(ws down t1 2>&1) && rc=0 || rc=$?
    assert_eq "down exits 0 when dockyard down fails and no container runs" 0 "$rc"
    assert "it says no container runs" grep -qF "and no container of the stack runs" <<<"$out"
    assert_eq "it clears the URLs" "" "$(ws_value t1 WS_URLS)"
    rm "$FX/dockyard.down-fail"

    ws new t2 feat/y beta >/dev/null 2>&1
    out=$(ws down t2 2>&1) && rc=0 || rc=$?
    assert_eq "down of a ticket without an env exits 0" 0 "$rc"
    assert "it says the ticket has no env" grep -qxF "t2 has no env." <<<"$out"
    assert_eq "it runs no dockyard down" 0 "$(dockyard_calls "down feat/y")"
}

test_up_fails() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    touch "$FX/dockyard.lock"
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up exits with dockyard's status 2 on a lock problem" 2 "$rc"
    assert "it names the failed command" grep -qxF "ws: dockyard up feat/x failed with status 2" <<<"$out"
    assert_eq ".ws has no slot" "" "$(ws_value t1 WS_SLOT)"
    refute "ls shows no env" grep -qF "env:" <<<"$(ls_row t1)"
    rm "$FX/dockyard.lock"

    touch "$FX/dockyard.build"
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up exits with dockyard's status 1 when the build fails" 1 "$rc"
    assert_eq "only dockyard's own hint names nuke" 1 "$(grep -c nuke <<<"$out")"
    assert_eq ".ws keeps the slot that dockyard recorded" 1 "$(ws_value t1 WS_SLOT)"
    assert_eq ".ws has no URLs" "" "$(ws_value t1 WS_URLS)"
    assert "ls shows env:down" grep -q " env:down " <<<"$(ls_row t1)"
    assert "CLAUDE.md says the env is down" grep -qF "is down and keeps slot 1." "$WS_ROOT/t1/CLAUDE.md"
    rm "$FX/dockyard.build"

    echo x- >"$FX/dockyard.prefix"
    ws new t2 feat/y beta >/dev/null 2>&1
    out=$(ws up t2 2>&1) && rc=0 || rc=$?
    assert_eq "up exits 1 when dockyard names the stack another way" 1 "$rc"
    assert "it names both stack names" grep -qxF "ws: dockyard named the stack 'x-feat-y', not feat-y" <<<"$out"
    assert_eq "it records no slot" "" "$(ws_value t2 WS_SLOT)"
    rm "$FX/dockyard.prefix"

    ws up t1 >/dev/null 2>&1
    touch "$FX/dockyard.build"
    echo '[]' >"$FX/docker.json"
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "a failed restart exits 1" 1 "$rc"
    assert_eq "it prints no nuke hint" 0 "$(grep -c nuke <<<"$out")"
    assert_eq "with no container left, .ws has no URLs" "" "$(ws_value t1 WS_URLS)"
    assert_eq "and keeps the slot" 1 "$(ws_value t1 WS_SLOT)"
}

test_up_wait() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    answer 4100 000 200
    answer 8100 404
    out=$(WS_UP_TIMEOUT=10 ws up t1 --wait 2>&1) && rc=0 || rc=$?
    assert_eq "up <id> --wait exits 0 once every URL answers" 0 "$rc"
    assert "a 404 counts as an answer" grep -qxF "api-gateway http://localhost:8100 ready" <<<"$out"
    assert "it ends with web-ui ready after web-ui answers 200" \
        test "$(tail -n 1 <<<"$out")" = "web-ui http://localhost:4100 ready"
    assert_eq "it asks web-ui until it answers" 2 "$(grep -cxF http://localhost:4100 "$FX/http/calls")"

    answer 4100 200
    answer 8100 503
    : >"$FX/http/calls"
    out=$(WS_UP_TIMEOUT=1 ws up --wait t1 2>&1) && rc=0 || rc=$?
    assert_eq "up --wait of an env that is up exits 1 on a URL that stays 503" 1 "$rc"
    assert "it says the env was up" grep -qxF "The env of t1 is already up on slot 1." <<<"$out"
    assert "it names the URL that timed out" \
        grep -qxF "ws: api-gateway http://localhost:8100 gave no HTTP answer below 500 in 1 seconds" <<<"$out"
    refute "it names no URL that answered" grep -qF "web-ui http://localhost:4100 gave" <<<"$out"

    rm "$FX/http/8100"
    out=$(WS_UP_TIMEOUT=0 ws up --wait t1 2>&1) && rc=0 || rc=$?
    assert_eq "a closed port times out" 1 "$rc"
    assert "it names the closed URL" grep -qF "ws: api-gateway http://localhost:8100 gave no HTTP answer" <<<"$out"

    out=$(WS_UP_TIMEOUT=soon ws up --wait t1 2>&1) && rc=0 || rc=$?
    assert_eq "WS_UP_TIMEOUT must be a number" 1 "$rc"
    out=$(WS_UP_TIMEOUT=08 ws up --wait t1 2>&1) && rc=0 || rc=$?
    assert "WS_UP_TIMEOUT with a leading zero is refused before anything runs" \
        grep -qxF "ws: WS_UP_TIMEOUT must be a number of seconds" <<<"$out"
    out=$(WS_UP_TIMEOUT=soon ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up without --wait ignores WS_UP_TIMEOUT" 0 "$rc"
}

test_up_needs_a_ticket() {
    local out rc
    new_fixture_no_ticket
    out=$(cd "$WS_PROJECTS/alpha" && ws up 2>&1) && rc=0 || rc=$?
    assert_eq "up outside a ticket exits 1" 1 "$rc"
    assert "it says to name the ticket" grep -qF "is not inside a ticket in ~/work; run ws up <id>" <<<"$out"
    out=$(ws up nosuch 2>&1) && rc=0 || rc=$?
    assert_eq "up of a missing ticket exits 1" 1 "$rc"
    assert "it names the missing ticket" grep -qxF "ws: no ticket ~/work/nosuch" <<<"$out"
    out=$(ws down --bogus 2>&1) && rc=0 || rc=$?
    assert_eq "down refuses an unknown flag" 1 "$rc"
    out=$(cd "$WS_ROOT" && ws up "" 2>&1) && rc=0 || rc=$?
    assert_eq "up refuses an empty id" 1 "$rc"
    refute "no call reached dockyard" test -e "$FX/dockyard.log"
}

test_rm_stops_the_env_first() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm of a ticket whose env runs exits 0" 0 "$rc"
    assert_eq "rm runs dockyard down" 1 "$(dockyard_calls "down feat/x")"
    refute "rm moves the ticket out" test -e "$WS_ROOT/t1"
    assert_eq "rm keeps the slot" 1 "$(slot_of feat-x)"
    assert_eq "rm keeps the volumes" 2 "$(volumes_of feat-x)"
    assert_eq "rm runs no nuke" 0 "$(grep -c nuke "$FX/dockyard.log")"

    ws prune --restore t1 >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    assert_eq "a restored ticket comes up on its old slot" 1 "$(ws_value t1 WS_SLOT)"

    echo new >"$WS_ROOT/t1/alpha/new.txt"
    out=$(ws rm --purge t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm --purge refuses a dirty worktree" 1 "$rc"
    assert "it stops the env first all the same" test "$(containers_of feat-x)" = 0
    assert_eq "it purges nothing" 2 "$(volumes_of feat-x)"
    assert_eq "it keeps the slot" 1 "$(slot_of feat-x)"
    assert_eq "it runs no nuke" 0 "$(grep -c nuke "$FX/dockyard.log")"
}

test_rm_purge() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    ws new t2 feat/y beta >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    ws up t2 >/dev/null 2>&1
    assert_eq "the second ticket gets slot 2" 2 "$(ws_value t2 WS_SLOT)"
    out=$(ws rm --purge t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm --purge exits 0" 0 "$rc"
    assert "it runs nuke once the ticket is in the trash" grep -qxF "nuke feat-x: workspace gone" "$FX/dockyard.log"
    assert_eq "the purged ticket's volumes are gone" 0 "$(volumes_of feat-x)"
    assert_eq "the purged ticket's slot is free" "" "$(slot_of feat-x)"
    assert_eq "the other ticket's volumes stay" 2 "$(volumes_of feat-y)"
    assert_eq "the other ticket's containers run" 2 "$(containers_of feat-y)"
    assert_eq "the other ticket keeps its slot" 2 "$(slot_of feat-y)"
    assert "the trashed .ws of the purged ticket holds no slot" grep -qx "WS_SLOT=" "$(trash_dir)"/*-t1/.ws
    ws prune --restore t1 >/dev/null 2>&1
    assert "the worktrees of a purged ticket come back from the trash" is_worktree "$WS_ROOT/t1/alpha"
    assert_eq "its .ws holds no slot" "" "$(ws_value t1 WS_SLOT)"
    assert "its CLAUDE.md says no env runs" grep -qF "No dockyard env runs for this ticket." "$WS_ROOT/t1/CLAUDE.md"
    refute "ls shows no env for it" grep -qF "env:" <<<"$(ls_row t1)"

    touch "$FX/dockyard.nuke-fail"
    out=$(ws rm --purge t2 2>&1) && rc=0 || rc=$?
    assert_eq "rm --purge exits with dockyard's status when nuke fails" 1 "$rc"
    assert "it says the volumes and slot stay" \
        grep -qxF "ws: dockyard nuke feat/y failed with status 1, so the env's volumes and slot stay" <<<"$out"
    assert_eq "they stay" 2 "$(volumes_of feat-y)"
    assert "the trashed .ws keeps the slot" grep -qx "WS_SLOT=2" "$(trash_dir)"/*-t2/.ws
    ws prune --restore t2 >/dev/null 2>&1
    assert_eq "the restored ticket keeps its slot" 2 "$(ws_value t2 WS_SLOT)"
    assert "ls shows env:down for it" grep -q " env:down " <<<"$(ls_row t2)"
    rm "$FX/dockyard.nuke-fail"
    out=$(ws rm --purge t2 2>&1) && rc=0 || rc=$?
    assert_eq "a second rm --purge exits 0" 0 "$rc"
    assert_eq "it frees the slot" "" "$(slot_of feat-y)"
    assert_eq "it removes the volumes" 0 "$(volumes_of feat-y)"
    assert "the trashed .ws holds no slot" grep -qx "WS_SLOT=" "$(trash_dir)"/*-t2/.ws
}

test_purge_checks_the_record_again() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    mkdir "$FX/elsewhere"
    echo "$FX/elsewhere" >"$FX/dockyard.steal"
    out=$(ws rm --purge t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm --purge exits 1 when the record names another workspace by the time it would nuke" 1 "$rc"
    assert "it says it purges nothing" \
        grep -qxF "ws: the record of dockyard stack feat-x no longer names ~/work/t1, so ws purges nothing" <<<"$out"
    assert_eq "it runs no nuke" 0 "$(grep -c nuke "$FX/dockyard.log")"
    assert_eq "the volumes stay" 2 "$(volumes_of feat-x)"
    refute "the ticket still moves to the trash" test -e "$WS_ROOT/t1"
}

test_another_tickets_stack() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/a-b alpha >/dev/null 2>&1
    ws new t2 feature/feat-a-b beta >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    out=$(ws up t2 2>&1) && rc=0 || rc=$?
    assert_eq "up of a branch whose stack another ticket holds exits 1" 1 "$rc"
    assert "it names the holder" grep -qxF \
        "ws: dockyard stack feat-a-b is registered with ticket t1 in ~/work/t1, so ws up starts nothing" <<<"$out"
    assert_eq "it runs no dockyard up, whose hint would say to nuke the holder" 0 "$(dockyard_calls "up feature/feat-a-b")"
    assert_eq ".ws of the second ticket has no slot" "" "$(ws_value t2 WS_SLOT)"

    out=$(ws down t2 2>&1) && rc=0 || rc=$?
    assert_eq "down of that ticket exits 0" 0 "$rc"
    assert "it says whose stack it leaves" \
        grep -qxF "ws: dockyard stack feat-a-b is registered with ticket t1 in ~/work/t1, so ws leaves it" <<<"$out"
    assert_eq "it runs no dockyard down" 0 "$(dockyard_calls "down feature/feat-a-b")"
    assert_eq "the holder's stack runs" 2 "$(containers_of feat-a-b)"

    out=$(ws rm --purge t2 2>&1) && rc=0 || rc=$?
    assert_eq "rm --purge of that ticket exits 0" 0 "$rc"
    assert "it says --purge leaves the stack" grep -qF "so --purge leaves it" <<<"$out"
    assert_eq "it runs no nuke" 0 "$(grep -c nuke "$FX/dockyard.log")"
    assert_eq "the holder keeps its volumes" 2 "$(volumes_of feat-a-b)"

    dockyard up feat/z >/dev/null 2>&1
    ws new t3 feat/z alpha >/dev/null 2>&1
    out=$(ws down t3 2>&1) && rc=0 || rc=$?
    assert "down leaves a stack that has no workspace" \
        grep -qxF "ws: dockyard stack feat-z is registered with no workspace, so ws leaves it" <<<"$out"
    assert_eq "that stack still runs" 1 "$(containers_of feat-z)"
    out=$(ws up t3 2>&1) && rc=0 || rc=$?
    assert_eq "up of that ticket exits 1" 1 "$rc"
    assert_eq "it runs no dockyard up for it" 1 "$(dockyard_calls "up feat/z")"
}

test_stack_name_follows_dockyard() {
    local out rc
    new_fixture_no_ticket
    ws new t1 fix/Alpha_Beta.2 alpha >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    assert_eq "up finds the record that dockyard names alpha-beta-2" 1 "$(ws_value t1 WS_SLOT)"
    out=$(ws down t1 2>&1) && rc=0 || rc=$?
    assert_eq "down finds it too" 1 "$(dockyard_calls "down fix/Alpha_Beta.2")"
    assert_eq "and stops it" 0 "$(containers_of alpha-beta-2)"

    ws new t2 feat/A_-b_ beta >/dev/null 2>&1
    ws up t2 >/dev/null 2>&1
    assert_eq "up finds the record of a branch whose name squeezes to feat-a-b" 2 "$(ws_value t2 WS_SLOT)"

    ln -s "$WS_ROOT/t2" "$FX/t2-link"
    jq --arg w "$FX/t2-link" '."feat-a-b".workspace = $w' "$HOME/.dockyard/slots.json" >"$FX/slots.new" &&
        mv "$FX/slots.new" "$HOME/.dockyard/slots.json"
    ws down t2 >/dev/null 2>&1
    assert_eq "a record that names the ticket through a symlink is still the ticket's" 1 "$(dockyard_calls "down feat/A_-b_")"
}

test_claude_md_env_block() {
    local before
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    assert "a new ticket's CLAUDE.md says no env runs" \
        grep -qxF "No dockyard env runs for this ticket. \`ws up\` starts one." "$WS_ROOT/t1/CLAUDE.md"
    echo "my notes" >>"$WS_ROOT/t1/CLAUDE.md"
    ws up t1 >/dev/null 2>&1
    assert "up keeps notes after the env block" grep -qx "my notes" "$WS_ROOT/t1/CLAUDE.md"
    assert "up writes the URLs into the env block of an edited file" \
        grep -qxF -- "- web-ui: http://localhost:4100" "$WS_ROOT/t1/CLAUDE.md"
    ws down t1 >/dev/null 2>&1
    refute "down takes the URLs out" grep -qF "http://localhost" "$WS_ROOT/t1/CLAUDE.md"
    assert "down keeps the notes" grep -qx "my notes" "$WS_ROOT/t1/CLAUDE.md"

    ws new t2 feat/y alpha >/dev/null 2>&1
    ws up t2 >/dev/null 2>&1
    ws new t2 feat/y alpha beta >/dev/null 2>&1
    assert "new rewrites an unedited file that holds URLs with the new repo" \
        grep -qF "\`beta/\` belongs to \`~/projects/beta\`" "$WS_ROOT/t2/CLAUDE.md"
    assert "and keeps the URLs" grep -qxF -- "- web-ui: http://localhost:4200" "$WS_ROOT/t2/CLAUDE.md"

    ws new t3 feat/z alpha >/dev/null 2>&1
    claude_md_of_2_0_72 t3 feat/z alpha >"$WS_ROOT/t3/CLAUDE.md"
    ws up t3 >/dev/null 2>&1
    assert "up rewrites an unedited file that ws 2.0.72 wrote" \
        grep -qxF -- "- web-ui: http://localhost:4300" "$WS_ROOT/t3/CLAUDE.md"

    ws new t4 feat/w alpha >/dev/null 2>&1
    { claude_md_of_2_0_72 t4 feat/w alpha && echo "my notes"; } >"$WS_ROOT/t4/CLAUDE.md"
    before=$(cat "$WS_ROOT/t4/CLAUDE.md")
    ws up t4 >/dev/null 2>&1
    assert_eq "up leaves an edited file without an env block as it was" "$before" "$(cat "$WS_ROOT/t4/CLAUDE.md")"

    ws new t5 feat/v alpha >/dev/null 2>&1
    grep -vxF '<!-- /ws env -->' "$WS_ROOT/t5/CLAUDE.md" >"$FX/t5.md" && echo "my notes" >>"$FX/t5.md"
    cp "$FX/t5.md" "$WS_ROOT/t5/CLAUDE.md"
    ws up t5 >/dev/null 2>&1
    assert_eq "up leaves a file whose env block has no end marker as it was" "$(cat "$FX/t5.md")" \
        "$(cat "$WS_ROOT/t5/CLAUDE.md")"
}

test_env_window_keeps_user_programs() {
    local out rc pane kid cmd
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    shell_ready t1
    mkdir "$FX/userbin"
    printf '#!/usr/bin/env bash\nsleep 1002\n' >"$FX/userbin/migrate.sh"
    chmod +x "$FX/userbin/migrate.sh"
    ln -s "$(PATH=$_base_path command -v sleep)" "$FX/userbin/docker"
    pane=$(pane_of t1)
    ws up t1 >/dev/null 2>&1
    assert "up turns an idle shell in the env window into the log tail" pane_shows t1 env "dockyard-feat-x | fixture log line"
    refute "it starts a new process there" test "$(pane_of t1)" = "$pane"

    for cmd in "sleep 1001 &" "$FX/userbin/migrate.sh" "$FX/userbin/docker 1003"; do
        tmux respawn-window -k -t "=t1:env" bash
        pane=$(pane_of t1)
        tmux send-keys -t "=t1:env" "$cmd" Enter
        kid=$(child_of "${pane#* }") || abort "the env window does not run '$cmd'"
        out=$(ws up t1 2>&1) && rc=0 || rc=$?
        assert_eq "up while the env window shell runs '$cmd' exits 0" 0 "$rc"
        assert "it says it leaves the window" grep -qxF \
            "The env window of t1 is in use, so ws leaves it. Tail the logs with: docker compose -p dockyard-feat-x logs --follow --tail 50" \
            <<<"$out"
        assert_eq "it keeps the pane" "$pane" "$(pane_of t1)"
        assert "'$cmd' still runs" alive "$kid"
    done

    tmux respawn-window -k -t "=t1:env" bash
    pane=$(pane_of t1)
    in_env_window t1 up t1 || abort "ws up in the env window did not finish"
    assert_eq "up run in the env window without TMUX_PANE exits 0" 0 "$(<"$FX/here.rc")"
    assert "it says it leaves the window it runs in" grep -qF "ws runs in the env window, so it leaves the window." "$FX/here.out"
    assert_eq "it keeps that pane" "$pane" "$(pane_of t1)"

    ws up t1 >/dev/null 2>&1
    pane=$(pane_of t1)
    ws up t1 >/dev/null 2>&1
    refute "up starts the log tail of an earlier up again" test "$(pane_of t1)" = "$pane"
    assert "it tails the logs" pane_shows t1 env "dockyard-feat-x | fixture log line"

    tmux split-window -d -t "=t1:env"
    pane=$(pane_of t1)
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert "up leaves an env window with two panes" grep -qF "The env window of t1 is in use, so ws leaves it." <<<"$out"
    assert_eq "it keeps its panes" "2 $pane" "$(tmux display-message -p -t "=t1:env" '#{window_panes}') $(pane_of t1)"
}

test_env_window_after_the_tail() {
    local out pane orphan i
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    shell_ready t1
    touch "$FX/docker.logs-exit"
    ws up t1 >/dev/null 2>&1
    for ((i = 0; i < 100; i++)); do
        [[ $(tmux display-message -p -t "=t1:env" '#{pane_dead}') != 1 ]] || break
        sleep 0.05
    done
    assert "the env window keeps the logs after the tail ends" pane_shows t1 env "dockyard-feat-x | fixture log line"
    assert_eq "the session keeps its env window" "claude shell env" \
        "$(tmux list-windows -t "=t1:" -F '#{window_name}' | paste -sd ' ')"
    pane=$(pane_of t1)
    ws up t1 >/dev/null 2>&1
    refute "up starts an ended tail again" test "$(pane_of t1)" = "$pane"
    rm "$FX/docker.logs-exit"

    ws up t1 >/dev/null 2>&1
    pane=$(pane_of t1)
    tmux copy-mode -t "=t1:env"
    out=$(ws up t1 2>&1)
    assert "up leaves a tail that the user scrolls in copy mode" grep -qF "The env window of t1 is in use" <<<"$out"
    assert_eq "it keeps that pane" "$pane" "$(pane_of t1)"

    tmux respawn-window -k -t "=t1:env" bash
    pane=$(pane_of t1)
    tmux send-keys -t "=t1:env" "( sleep 1004 & echo \$! >$(printf %q "$FX/orphan.pid") )" Enter
    for ((i = 0; i < 100; i++)); do
        [[ ! -s $FX/orphan.pid ]] || break
        sleep 0.05
    done
    orphan=$(<"$FX/orphan.pid")
    out=$(ws up t1 2>&1)
    assert "up leaves a shell whose terminal still runs a process it left behind" \
        grep -qF "The env window of t1 is in use" <<<"$out"
    assert "that process still runs" alive "$orphan"
    [[ -z $orphan ]] || kill "$orphan" 2>/dev/null
    wait_exit "$orphan"
    refute "the test leaves no process behind" alive "$orphan"

    tmux kill-window -t "=t1:env"
    tmux new-window -d -t "=t1:" -n "my env" bash
    tmux new-window -d -t "=t1:" -n envoy bash
    pane=$(tmux display-message -p -t "=t1:envoy" '#{pane_id} #{pane_pid}')
    ws up t1 >/dev/null 2>&1
    assert "up opens a window named env when none has that exact name" pane_shows t1 env "dockyard-feat-x | fixture log line"
    assert_eq "it leaves a window whose name starts with env" "$pane" \
        "$(tmux display-message -p -t "=t1:envoy" '#{pane_id} #{pane_pid}')"
}

test_up_urls_that_do_not_fit() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    ws up t1 >/dev/null 2>&1
    echo '[]' >"$FX/docker.json"
    echo "http://localhost:4100/\$(id)" >"$FX/dockyard.web-url"
    out=$(ws up t1 2>&1) && rc=0 || rc=$?
    assert_eq "up exits 1 when .ws cannot hold a URL that dockyard printed" 1 "$rc"
    assert "it says .ws records the slot alone" grep -qxF "ws: .ws records slot 1 without the URLs" <<<"$out"
    assert_eq ".ws keeps the slot" 1 "$(ws_value t1 WS_SLOT)"
    assert_eq ".ws holds no URLs of the earlier up" "" "$(ws_value t1 WS_URLS)"
    assert "ls shows env:down" grep -q " env:down " <<<"$(ls_row t1)"

    ws new t2 feat/y beta >/dev/null 2>&1
    ws up t2 >/dev/null 2>&1
    assert_eq "a first up records the slot alone" 2 "$(ws_value t2 WS_SLOT)"
}

test_up_names_the_ticket_that_holds_the_stack() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feature/c-d alpha >/dev/null 2>&1
    ws new t2 c/d beta >/dev/null 2>&1
    realpath -e "$WS_ROOT/t1" >"$FX/dockyard.claim"
    out=$(ws up t2 2>&1) && rc=0 || rc=$?
    assert_eq "up exits 1 when another up claims the stack first" 1 "$rc"
    assert "dockyard says to run nuke first" grep -qF "run nuke first" <<<"$out"
    assert "ws names the ticket that holds the stack" grep -qxF \
        "ws: dockyard stack c-d is registered with ticket t1 in ~/work/t1, so its nuke would remove that env" <<<"$out"
    assert_eq ".ws of the ticket that lost has no slot" "" "$(ws_value t2 WS_SLOT)"
}

test_claude_md_markers() {
    local out
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    {
        echo "# My notes"
        echo '```'
        echo "<!-- ws env: ws up and ws down rewrite the lines up to the end marker -->"
        echo '```'
        echo "KEEP-ME-1"
        cat "$WS_ROOT/t1/CLAUDE.md"
        echo "KEEP-ME-2"
    } >"$FX/t1.md"
    cp "$FX/t1.md" "$WS_ROOT/t1/CLAUDE.md"
    out=$(ws up t1 2>&1)
    assert_eq "up leaves a file that quotes the start marker as it was" "$(cat "$FX/t1.md")" "$(cat "$WS_ROOT/t1/CLAUDE.md")"
    assert "it says why" grep -qxF \
        "ws: ~/work/t1/CLAUDE.md does not hold exactly one env block, so ws leaves it as it is" <<<"$out"
    ws down t1 >/dev/null 2>&1
    assert_eq "down leaves it too" "$(cat "$FX/t1.md")" "$(cat "$WS_ROOT/t1/CLAUDE.md")"

    ws new t2 feat/y alpha >/dev/null 2>&1
    { echo "<!-- /ws env -->" && cat "$WS_ROOT/t2/CLAUDE.md"; } >"$FX/t2.md"
    cp "$FX/t2.md" "$WS_ROOT/t2/CLAUDE.md"
    ws up t2 >/dev/null 2>&1
    assert_eq "up leaves a file with a second end marker as it was" "$(cat "$FX/t2.md")" "$(cat "$WS_ROOT/t2/CLAUDE.md")"

    ws new t3 feat/z alpha >/dev/null 2>&1
    grep -vxF "<!-- /ws env -->" "$WS_ROOT/t3/CLAUDE.md" >"$FX/t3.md"
    sed -i '1i <!-- /ws env -->' "$FX/t3.md"
    cp "$FX/t3.md" "$WS_ROOT/t3/CLAUDE.md"
    ws up t3 >/dev/null 2>&1
    assert_eq "up leaves a file whose end marker comes before the start marker as it was" "$(cat "$FX/t3.md")" \
        "$(cat "$WS_ROOT/t3/CLAUDE.md")"
}

test_claude_md_keeps_the_file() {
    local f
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    f=$WS_ROOT/t1/CLAUDE.md
    printf 'my notes\n\n\n' >>"$f"
    chmod 640 "$f"
    ln "$f" "$FX/t1-link"
    ws up t1 >/dev/null 2>&1
    assert "up writes the URLs" grep -qxF -- "- web-ui: http://localhost:4100" "$f"
    assert_eq "up keeps the file mode" 640 "$(stat -c %a "$f")"
    assert "up keeps a hard link to the file" test "$f" -ef "$FX/t1-link"
    assert_eq "up keeps the blank lines at the end" "73 0a 0a 0a" "$(tail -c 4 "$f" | od -An -tx1 | xargs)"
    refute "up leaves no temp file" compgen -G "$WS_ROOT/t1/.CLAUDE.md.*"
    ws down t1 >/dev/null 2>&1
    assert "down writes through the same link" grep -qF "is down and keeps slot 1." "$FX/t1-link"

    ws new t2 feat/y alpha >/dev/null 2>&1
    chmod 444 "$WS_ROOT/t2/CLAUDE.md"
    cp "$WS_ROOT/t2/CLAUDE.md" "$FX/t2.md"
    ws up t2 >/dev/null 2>&1
    assert_eq "up leaves a read-only file as it was" "$(cat "$FX/t2.md")" "$(cat "$WS_ROOT/t2/CLAUDE.md")"
    refute "and leaves no temp file" compgen -G "$WS_ROOT/t2/.CLAUDE.md.*"
}

test_drop_fixtures_waits_for_the_panes() {
    local pid sandbox
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    tmux respawn-window -k -t "=t1:env" bash -c "trap 'sleep 1; : >\"\$HOME/late\"' HUP; sleep infinity & wait"
    pid=$(tmux display-message -p -t "=t1:env" '#{pane_pid}')
    child_of "$pid" >/dev/null || abort "the env window does not run its sleep"
    sandbox=$_sandbox
    drop_fixtures
    refute "drop_fixtures returns once the processes of the panes end" alive "$pid"
    refute "it leaves nothing of the sandbox" test -e "$sandbox"
}

run_test test_up
run_test test_up_passes_the_profiles_of_the_ticket_repos
run_test test_up_names_the_repos_without_a_service
run_test test_up_refuses_a_bad_profile_pair
run_test test_up_twice
run_test test_down
run_test test_up_fails
run_test test_up_wait
run_test test_up_needs_a_ticket
run_test test_rm_stops_the_env_first
run_test test_rm_purge
run_test test_purge_checks_the_record_again
run_test test_another_tickets_stack
run_test test_stack_name_follows_dockyard
run_test test_claude_md_env_block
run_test test_env_window_keeps_user_programs
run_test test_env_window_after_the_tail
run_test test_up_urls_that_do_not_fit
run_test test_up_names_the_ticket_that_holds_the_stack
run_test test_claude_md_markers
run_test test_claude_md_keeps_the_file
run_test test_drop_fixtures_waits_for_the_panes
finish
