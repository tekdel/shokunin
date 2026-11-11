#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

ws_value() {
    sed -n "s/^$2=//p" "$WS_ROOT/$1/.ws"
}

windows_of() {
    tmux list-windows -t "=$1:" -F '#{window_name}' 2>/dev/null | paste -sd ' '
}

session_path() {
    tmux display-message -p -t "=$1:" '#{session_path}' 2>/dev/null
}

has_session() {
    tmux has-session -t "=$1" 2>/dev/null
}

lists_worktree() {
    git -C "$WS_PROJECTS/$1" worktree list --porcelain | grep -Fqx "worktree $2"
}

agents() {
    printf '%s\n' "$1" >"$FX/agents.json"
}

wait_refresh() {
    flock -w 30 "$XDG_CACHE_HOME/ws/refresh.lock" true || abort "the background refresh did not end"
}

wait_for_line() {
    local i
    for ((i = 0; i < 100; i++)); do
        grep -qx -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.05
    done
    return 1
}

claude_calls() {
    grep -c -- "$1" "$FX/claude.log"
}

gh_calls() {
    wc -l <"$FX/gh.log"
}

tmux_sessionizer_rows() {
    {
        find ~/projects -mindepth 1 -maxdepth 1 -type d 2>/dev/null
        echo "$HOME/claude-knowledge-vault"
    }
}

ticket_rows() {
    ws pick --print | cut -f1 | grep "^$WS_ROOT/" | sed "s#^$WS_ROOT/##" | paste -sd ' '
}

fake_fzf() {
    cat >"$FX/bin/fzf" <<'EOF'
#!/usr/bin/env bash
awk -F '\t' -v want="$WS_FZF_PICK" '$1 == want { print; found = 1; exit } END { exit !found }'
EOF
    chmod +x "$FX/bin/fzf"
}

test_new() {
    local out rc main
    new_fixture_no_ticket
    out=$(ws new t1 feat/x alpha beta 2>&1) && rc=0 || rc=$?
    assert_eq "new exits 0" 0 "$rc"
    assert "new makes the alpha worktree" is_worktree "$WS_ROOT/t1/alpha"
    assert "new makes the beta worktree" is_worktree "$WS_ROOT/t1/beta"
    assert_eq "alpha is on the ticket branch" refs/heads/feat/x "$(git -C "$WS_ROOT/t1/alpha" symbolic-ref HEAD)"
    assert_eq "beta is on the ticket branch" refs/heads/feat/x "$(git -C "$WS_ROOT/t1/beta" symbolic-ref HEAD)"
    main=$(git -C "$WS_PROJECTS/alpha" rev-parse origin/main)
    assert_eq "a new branch starts at origin's default branch" "$main" "$(head_of "$WS_ROOT/t1/alpha")"
    refute "a new branch has no upstream" git -C "$WS_ROOT/t1/alpha" rev-parse -q --verify '@{upstream}'
    assert_eq ".ws holds every key of the ticket layout in order" \
        "$(printf '%s\n' WS_ID=t1 WS_TICKET= WS_BRANCH=feat/x 'WS_REPOS="alpha beta"' WS_TOPIC=t1 WS_STAGE=spec \
            WS_SCENARIOS_SHA256= WS_SLOT= WS_URLS= "WS_CREATED=$(date +%F)")" "$(cat "$WS_ROOT/t1/.ws")"
    assert_eq "a shell that sources .ws reads the same values" "t1|feat/x|alpha beta|spec" \
        "$(env -i bash -c 'source "$1" && echo "$WS_ID|$WS_BRANCH|$WS_REPOS|$WS_STAGE"' _ "$WS_ROOT/t1/.ws")"
    assert "CLAUDE.md names the branch" grep -qF '`feat/x`' "$WS_ROOT/t1/CLAUDE.md"
    assert "CLAUDE.md names both repos" grep -qF '`beta/` belongs to `~/projects/beta`' "$WS_ROOT/t1/CLAUDE.md"
    refute "CLAUDE.md imports no file" grep -qE '(^|[[:space:]])@[~/.A-Za-z]' "$WS_ROOT/t1/CLAUDE.md"
    assert_eq "the session has the windows claude, shell, and env" "claude shell env" "$(windows_of t1)"
    assert_eq "the session works in the ticket" "$WS_ROOT/t1" "$(session_path t1)"
    assert "the claude window runs claude -n t1" wait_for_line "$FX/claude.log" '-n t1'
    assert "new says how to attach outside tmux" grep -qx 'Attach with: tmux attach -t t1' <<<"$out"
    ws new v1.2 feat/v alpha >/dev/null 2>&1
    assert_eq "an id with a dot gets its own session" "claude shell env" "$(windows_of v1.2)"
}

test_new_existing_branch() {
    local clone tip
    new_fixture_no_ticket
    git -C "$WS_PROJECTS/alpha" branch -q feat/local || abort "cannot make feat/local"
    tip=$(git -C "$WS_PROJECTS/alpha" rev-parse feat/local)
    ws new t1 feat/local alpha >/dev/null 2>&1
    assert_eq "new checks out an existing local branch" "$tip" "$(head_of "$WS_ROOT/t1/alpha")"

    clone=$FX/other-clone
    {
        git clone -q "$FX/origins/beta.git" "$clone" &&
            git -C "$clone" checkout -q -b feat/remote &&
            echo remote >"$clone/remote.txt" && git -C "$clone" add remote.txt &&
            git -C "$clone" commit -qm remote && git -C "$clone" push -q origin feat/remote
    } || abort "cannot push feat/remote"
    tip=$(git -C "$clone" rev-parse HEAD)
    ws new t2 feat/remote beta >/dev/null 2>&1
    assert_eq "new fetches and checks out a branch only origin has" "$tip" "$(head_of "$WS_ROOT/t2/beta")"
    assert_eq "that branch tracks origin" origin/feat/remote \
        "$(git -C "$WS_ROOT/t2/beta" rev-parse --abbrev-ref '@{upstream}')"
}

test_new_rerun() {
    local out rc before
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    ws stage t1 qa >/dev/null
    out=$(ws new t1 feat/x alpha 2>&1) && rc=0 || rc=$?
    assert_eq "a rerun exits 0" 0 "$rc"
    assert_eq "a rerun adds no window" "claude shell env" "$(windows_of t1)"
    assert "a rerun switches, or says how to attach" grep -qx 'Attach with: tmux attach -t t1' <<<"$out"

    tmux kill-window -t "=t1:env"
    tmux kill-window -t "=t1:claude"
    rm "$WS_ROOT/t1/CLAUDE.md"
    out=$(ws new t1 feat/x beta 2>&1) && rc=0 || rc=$?
    assert_eq "a repairing rerun exits 0" 0 "$rc"
    assert_eq "a rerun puts back the missing windows, claude first" "claude shell env" "$(windows_of t1)"
    assert "a rerun writes a missing CLAUDE.md" test -f "$WS_ROOT/t1/CLAUDE.md"
    assert "a rerun adds a new repo" is_worktree "$WS_ROOT/t1/beta"
    assert_eq "a rerun keeps the repos it had" "alpha beta" "$(ws_value t1 WS_REPOS | tr -d '"')"
    assert_eq "a rerun keeps the stage" qa "$(ws_value t1 WS_STAGE)"

    before=$(cat "$WS_ROOT/t1/.ws")
    out=$(ws new t1 feat/y alpha 2>&1) && rc=0 || rc=$?
    assert_eq "a rerun on another branch exits 1" 1 "$rc"
    assert "it names both branches" grep -qF "ticket t1 is on branch feat/x, not feat/y" <<<"$out"
    assert_eq "it leaves .ws alone" "$before" "$(cat "$WS_ROOT/t1/.ws")"
}

test_new_takes_a_dir_without_ws() {
    local rc
    new_fixture
    ws new t1 feat/ticket alpha beta >/dev/null 2>&1 && rc=0 || rc=$?
    assert_eq "new takes a ticket dir that has the worktrees but no .ws" 0 "$rc"
    assert_eq "it writes .ws for them" feat/ticket "$(ws_value t1 WS_BRANCH)"
}

test_new_refuses() {
    local out rc id branch
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    out=$(ws new t2 feat/x alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a branch another worktree has" 1 "$rc"
    assert "it names the directory that has the branch" grep -qF "feat/x is checked out in ~/work/t1/alpha" <<<"$out"
    refute "it makes no ticket dir" test -e "$WS_ROOT/t2"

    for id in 'a+b' '../x' '.x' 'a/b' 'a b' ''; do
        out=$(ws new "$id" feat/q alpha 2>&1) && rc=0 || rc=$?
        assert_eq "new refuses the id '$id'" 1 "$rc"
    done
    for branch in 'feat x' 'feat/$(touch pwned)' 'feat..x' '-x' 'feat/"q"'; do
        out=$(ws new t3 "$branch" alpha 2>&1) && rc=0 || rc=$?
        assert_eq "new refuses the branch '$branch'" 1 "$rc"
    done
    refute "no ticket dir appears for refused ids or branches" test -e "$WS_ROOT/t3"
    assert_eq "WS_ROOT holds only t1" t1 "$(cd "$WS_ROOT" && find . -mindepth 1 -maxdepth 1 -printf '%P\n')"
    refute "a branch name runs nothing" test -e "$FX/pwned"

    tmux new-session -d -s t9 -c "$WS_PROJECTS"
    out=$(ws new t9 feat/q alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses an id whose tmux session works elsewhere" 1 "$rc"
    assert "it names the session's directory" grep -qF "tmux session t9 works in ~/projects, not ~/work/t9" <<<"$out"
    refute "it makes nothing first" test -e "$WS_ROOT/t9"

    out=$(ws new t4 feat/q gamma 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a repo that is not in WS_PROJECTS" 1 "$rc"
    assert "it names the missing checkout" grep -qF "~/projects/gamma is not a git checkout" <<<"$out"

    mkdir -p "$WS_ROOT/t5/alpha"
    out=$(ws new t5 feat/q alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a repo path that is not its worktree" 1 "$rc"
    assert "it names the path" grep -qF "~/work/t5/alpha exists and is not a worktree of ~/projects/alpha on feat/q" <<<"$out"

    mkdir -p "$WS_ROOT/t6"
    printf 'WS_ID=t6\nnot a pair\n' >"$WS_ROOT/t6/.ws"
    out=$(ws new t6 feat/q alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a malformed .ws" 1 "$rc"
    assert "it says which line" grep -qF "line 2 of ~/work/t6/.ws is not KEY=value" <<<"$out"
    assert_eq "it leaves the malformed .ws alone" $'WS_ID=t6\nnot a pair' "$(cat "$WS_ROOT/t6/.ws")"

    mkdir -p "$WS_ROOT/t7"
    printf 'WS_ID=other\n' >"$WS_ROOT/t7/.ws"
    out=$(ws new t7 feat/q alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a .ws whose WS_ID is not its directory" 1 "$rc"
    assert "it names the mismatch" grep -qF "WS_ID in ~/work/t7/.ws is not t7" <<<"$out"

    mkdir -p "$WS_ROOT/t8"
    { echo WS_ID=t8 && printf '# %0100d\n' $(seq 700); } >"$WS_ROOT/t8/.ws"
    out=$(ws new t8 feat/q alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a .ws over 64 KB" 1 "$rc"
    assert "it says the .ws is too big" grep -qF "~/work/t8/.ws is over 64 KB" <<<"$out"
}

test_ws_file_writes() {
    local rc
    new_fixture_no_ticket
    ws new --ticket T-1 --topic topic-a t1 feat/x alpha >/dev/null 2>&1
    assert_eq "--ticket sets WS_TICKET" T-1 "$(ws_value t1 WS_TICKET)"
    assert_eq "--topic sets WS_TOPIC" topic-a "$(ws_value t1 WS_TOPIC)"
    printf 'WS_URLS="web=http://localhost:4400 api=http://localhost:4401"\nWS_EXTRA=kept\n' >>"$WS_ROOT/t1/.ws"
    ws stage t1 building >/dev/null
    assert_eq "a write keeps values with spaces quoted" '"web=http://localhost:4400 api=http://localhost:4401"' \
        "$(ws_value t1 WS_URLS)"
    assert_eq "a write keeps keys ws does not know" kept "$(ws_value t1 WS_EXTRA)"
    assert_eq "a write puts unknown keys last" WS_EXTRA=kept "$(tail -n 1 "$WS_ROOT/t1/.ws")"
    sed -i 's/$/\r/' "$WS_ROOT/t1/.ws"
    ws stage t1 verifying >/dev/null 2>&1 && rc=0 || rc=$?
    assert_eq "ws reads a .ws with CRLF line ends" 0 "$rc"
    refute "the write drops the carriage returns" grep -q $'\r' "$WS_ROOT/t1/.ws"
    printf 'WS_BAD="a$b"\n' >>"$WS_ROOT/t1/.ws"
    ws stage t1 qa >/dev/null 2>&1 && rc=0 || rc=$?
    assert_eq "ws refuses to write a value a shell would expand" 1 "$rc"
    assert_eq "the refused write leaves the stage" verifying "$(ws_value t1 WS_STAGE)"
    refute "the refused write leaves no temp file" compgen -G "$WS_ROOT/t1/.ws.*"
}

test_adopt() {
    local out rc
    new_fixture_no_ticket
    add_worktree alpha "$WS_PROJECTS/alpha-t3" feat/t3
    add_worktree beta "$WS_PROJECTS/beta-t3" feat/t3
    echo wip >"$WS_PROJECTS/alpha-t3/wip.txt"
    out=$(ws adopt t3 "$WS_PROJECTS/alpha-t3" "$WS_PROJECTS/beta-t3" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt exits 0" 0 "$rc"
    assert "alpha lists the new path" lists_worktree alpha "$WS_ROOT/t3/alpha"
    assert "beta lists the new path" lists_worktree beta "$WS_ROOT/t3/beta"
    refute "alpha no longer lists the old path" lists_worktree alpha "$WS_PROJECTS/alpha-t3"
    refute "the old directory is gone" test -e "$WS_PROJECTS/alpha-t3"
    assert "adopt keeps uncommitted files" test -f "$WS_ROOT/t3/alpha/wip.txt"
    assert_eq "adopt writes the branch to .ws" feat/t3 "$(ws_value t3 WS_BRANCH)"
    assert_eq "adopt writes the repos to .ws" '"alpha beta"' "$(ws_value t3 WS_REPOS)"
    assert_eq "adopt makes the session" "claude shell env" "$(windows_of t3)"
    assert "adopt names each move" grep -qF "Moved ~/projects/beta-t3 to ~/work/t3/beta" <<<"$out"
}

test_adopt_refuses() {
    local out rc
    new_fixture_no_ticket
    add_worktree alpha "$WS_PROJECTS/alpha-a" feat/a
    add_worktree beta "$WS_PROJECTS/beta-b" feat/b
    out=$(ws adopt t3 "$WS_PROJECTS/alpha-a" "$WS_PROJECTS/beta-b" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses worktrees on two branches" 1 "$rc"
    assert "it names both branches" grep -qF "different branches: feat/a and feat/b" <<<"$out"
    assert "it moves nothing" lists_worktree alpha "$WS_PROJECTS/alpha-a"
    refute "it makes no ticket dir" test -e "$WS_ROOT/t3"

    fake_proc 4242 1 "$WS_PROJECTS/alpha-a"
    out=$(ws adopt t3 "$WS_PROJECTS/alpha-a" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a worktree a process works in" 1 "$rc"
    assert "it says a process works in it" grep -qF "~/projects/alpha-a: a process works in it" <<<"$out"
    rm -rf "${WS_PROC:?}/4242"

    git -C "$WS_PROJECTS/alpha" worktree lock "$WS_PROJECTS/alpha-a"
    out=$(ws adopt t3 "$WS_PROJECTS/alpha-a" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a locked worktree" 1 "$rc"
    git -C "$WS_PROJECTS/alpha" worktree unlock "$WS_PROJECTS/alpha-a"

    out=$(ws adopt t3 "$WS_PROJECTS/alpha" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a main checkout" 1 "$rc"
    assert "it says it is no linked worktree" grep -qF "~/projects/alpha is not a linked worktree" <<<"$out"

    ws new t4 feat/q alpha >/dev/null 2>&1
    out=$(ws adopt t4 "$WS_PROJECTS/alpha-a" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a repo the ticket has" 1 "$rc"
    assert "it names the taken path" grep -qF "~/work/t4/alpha exists" <<<"$out"
    assert "the refused worktree stays" lists_worktree alpha "$WS_PROJECTS/alpha-a"
}

test_stage() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    out=$(ws stage t1 qa 2>&1) && rc=0 || rc=$?
    assert_eq "stage exits 0" 0 "$rc"
    assert_eq "stage writes WS_STAGE" qa "$(ws_value t1 WS_STAGE)"
    assert_eq "stage says the new stage" "t1 is at qa" "$out"
    (cd "$WS_ROOT/t1/alpha" && ws stage review >/dev/null)
    assert_eq "stage without an id takes the ticket of the current directory" review "$(ws_value t1 WS_STAGE)"
    ws stage t1 shipped >/dev/null 2>&1 && rc=0 || rc=$?
    assert_eq "stage refuses an unknown stage" 1 "$rc"
    assert_eq "an unknown stage leaves .ws alone" review "$(ws_value t1 WS_STAGE)"
    out=$(cd "$WS_PROJECTS/alpha" && ws stage qa 2>&1) && rc=0 || rc=$?
    assert_eq "stage without an id refuses outside a ticket" 1 "$rc"
    ws stage t9 qa >/dev/null 2>&1 && rc=0 || rc=$?
    assert_eq "stage refuses a ticket that does not exist" 1 "$rc"
    refute "it makes no ticket dir" test -e "$WS_ROOT/t9"
}

test_stage_limit() {
    local n out
    new_fixture_no_ticket
    for n in 1 2 3 4 5 6; do
        ws new "t$n" "feat/t$n" alpha >/dev/null 2>&1
    done
    for n in 1 2 3 4 5; do
        out=$(ws stage "t$n" building 2>&1)
        refute "building number $n prints no warning" grep -q 'tickets are in building' <<<"$out"
    done
    out=$(ws stage t6 building 2>&1)
    assert "the sixth building prints the limit warning" \
        grep -qF "ws: 6 tickets are in building, more than 5. Finish one before you start another." <<<"$out"
}

test_rm_refuses() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    agents '[{"kind":"background","id":"bg1","state":"working","cwd":"'"$WS_ROOT"'/t1","startedAt":0}]'
    echo new >"$WS_ROOT/t1/alpha/new.txt"
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm refuses a dirty worktree" 1 "$rc"
    assert "it names the dirty worktree" grep -qx "ws: ~/work/t1/alpha: dirty" <<<"$out"
    assert "the session stays" has_session t1
    assert "the worktree stays" is_worktree "$WS_ROOT/t1/alpha"
    assert_eq "it stops no Claude session" 0 "$(claude_calls '^stop')"

    rm "$WS_ROOT/t1/alpha/new.txt"
    commit_in "$WS_ROOT/t1/beta" local.txt
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm refuses an unpushed commit" 1 "$rc"
    assert "it names the unpushed worktree" grep -qx "ws: ~/work/t1/beta: unpushed" <<<"$out"

    out=$(cd "$WS_ROOT/t1/alpha" && ws rm t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm refuses from inside the ticket" 1 "$rc"
    assert "it says to leave the ticket" grep -qF "you are in ~/work/t1; cd out of it first" <<<"$out"
    assert "the ticket stays" test -f "$WS_ROOT/t1/.ws"
}

test_rm() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    agents '[{"kind":"background","id":"bg1","state":"working","cwd":"'"$WS_ROOT"'/t1/alpha","startedAt":0},
        {"kind":"background","id":"bg2","state":"working","cwd":"'"$WS_PROJECTS"'/alpha","startedAt":0},
        {"kind":"background","id":"bg3","state":"done","cwd":"'"$WS_ROOT"'/t1","startedAt":0},
        {"kind":"interactive","cwd":"'"$WS_ROOT"'/t1","pid":5,"status":"busy","startedAt":0}]'
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    assert_eq "rm exits 0" 0 "$rc"
    assert_eq "rm stops the ticket's working background session" 1 "$(claude_calls '^stop bg1$')"
    assert_eq "rm leaves sessions outside the ticket" 0 "$(claude_calls '^stop bg2$')"
    assert_eq "rm skips a session that is done" 0 "$(claude_calls '^stop bg3$')"
    refute "rm kills the tmux session" has_session t1
    refute "rm removes the ticket dir" test -e "$WS_ROOT/t1"
    refute "alpha no longer lists the ticket worktree" lists_worktree alpha "$WS_ROOT/t1/alpha"
    assert "rm says how to undo it" grep -qxF "Removed ticket t1. ws prune --restore t1 brings it back." <<<"$out"
    ws prune --restore t1 >/dev/null 2>&1
    assert "restore brings the worktree back" lists_worktree alpha "$WS_ROOT/t1/alpha"
    assert_eq "restore brings .ws back" feat/x "$(ws_value t1 WS_BRANCH)"
}

test_pick_lists_what_the_sessionizer_listed() {
    local head row missing=0
    new_fixture
    export WS_VAULT=$HOME/claude-knowledge-vault
    mkdir -p "$WS_VAULT" "$WS_PROJECTS/.hidden" "$WS_PROJECTS/dot.name"
    ln -s "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-link"
    ws new t2 feat/y beta >/dev/null 2>&1
    head=$(ws pick --print | cut -f1)
    while IFS= read -r row; do
        grep -Fqx -- "$row" <<<"$head" || {
            missing=1
            printf '      missing: %s\n' "$row"
        }
    done < <(tmux_sessionizer_rows)
    assert_eq "pick lists every row tmux-sessionizer listed" 0 "$missing"
    assert_eq "tickets come first" "$WS_ROOT/t2" "$(head -n 1 <<<"$head")"
    assert_eq "a dir in WS_ROOT without .ws comes after the tickets" "$WS_ROOT/t1" "$(sed -n 2p <<<"$head")"
    assert_eq "the vault comes last" "$WS_VAULT" "$(tail -n 1 <<<"$head")"
    assert_eq "every row prints once" "$(sort <<<"$head" | uniq | wc -l)" "$(wc -l <<<"$head")"
}

test_pick_order() {
    local rows
    new_fixture_no_ticket
    ws new a1 feat/a1 alpha >/dev/null 2>&1
    ws new b1 feat/b1 beta >/dev/null 2>&1
    ws new c1 feat/c1 alpha >/dev/null 2>&1
    ws new d1 feat/d1 beta >/dev/null 2>&1
    ws new e1 feat/e1 alpha >/dev/null 2>&1
    ws stage a1 building >/dev/null
    ws stage b1 review >/dev/null
    ws stage d1 qa >/dev/null
    ws stage e1 planned >/dev/null
    agents '[{"kind":"interactive","cwd":"'"$WS_ROOT"'/c1/alpha","pid":7,"status":"waiting","startedAt":0}]'
    ws status --refresh
    assert_eq "waiting tickets first, then the stages that wait on you, then the rest" "c1 e1 d1 b1 a1" "$(ticket_rows)"
    rows=$(ws pick --print)
    assert "the waiting ticket shows the waiting mark" grep -qE "^$WS_ROOT/c1"$'\t'"c1 +spec +1 waiting" <<<"$rows"
}

test_status() {
    local out before
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    add_pr alpha feat/x OPEN 12 "$(head_of "$WS_ROOT/t1/alpha")"
    agents '[{"kind":"interactive","cwd":"'"$WS_ROOT"'/t1/alpha","pid":7,"status":"waiting","startedAt":0},
        {"kind":"background","id":"bg1","state":"blocked","cwd":"'"$WS_PROJECTS"'/beta","startedAt":0},
        {"kind":"background","id":"bg2","state":"working","cwd":"'"$WS_ROOT"'/t1","startedAt":0},
        {"kind":"interactive","cwd":"'"$WS_ROOT"'/t1","pid":8,"status":"idle","startedAt":0}]'
    out=$(ws status --waiting)
    assert_eq "--waiting prints nothing before the first refresh" "" "$out"
    wait_refresh
    assert_eq "--waiting counts every session that waits on you" "2 waiting" "$(ws status --waiting)"
    wait_refresh
    out=$(ws ls)
    assert "ls shows the waiting session of the ticket" grep -qE '^t1 +spec +1 waiting +pr:open +feat/x$' <<<"$out"
    out=$(ws pick --print)
    assert "pick shows the waiting session in a project" grep -qE $'\t''~/projects/beta  1 waiting$' <<<"$out"

    before=$(gh_calls)
    ws status --refresh
    assert_eq "a refresh within WS_PR_TTL asks gh nothing" "$before" "$(gh_calls)"
    WS_PR_TTL=0 ws status --refresh
    assert "a refresh past WS_PR_TTL asks gh again" test "$(gh_calls)" -gt "$before"
    ws new t2 feat/z beta >/dev/null 2>&1
    add_pr beta feat/z MERGED 3 "$(head_of "$WS_ROOT/t2/beta")"
    ws status --refresh
    assert "a refresh within WS_PR_TTL asks gh for a ticket the cache lacks" \
        grep -qE '^t2 +spec +pr:merged +feat/z$' <<<"$(ws ls)"

    agents 'not json'
    ws status --refresh
    assert_eq "--waiting prints nothing when claude agents gives no list" "" "$(ws status --waiting)"
    wait_refresh

    sed -i 's/^WS_SLOT=$/WS_SLOT=3/' "$WS_ROOT/t1/.ws"
    assert "ls shows env:down when only WS_SLOT is set" grep -qE ' env:down +feat/x$' <<<"$(ws ls)"
    sed -i 's#^WS_URLS=$#WS_URLS=web=http://localhost:4400#' "$WS_ROOT/t1/.ws"
    assert "ls shows env:up when WS_URLS is set" grep -qE ' env:up +feat/x$' <<<"$(ws ls)"
    printf 'garbage' >"$WS_ROOT/t1/.ws"
    assert "ls marks a malformed .ws" grep -qE '^t1 +malformed .ws: line 1 of ~/work/t1/.ws is not KEY=value$' <<<"$(ws ls)"
}

test_pick_opens() {
    local out pane i
    new_fixture_no_ticket
    fake_fzf
    out=$(WS_FZF_PICK=$WS_PROJECTS/alpha ws pick 2>&1)
    assert "pick makes a session for a project" has_session alpha
    assert_eq "that session works in the project" "$WS_PROJECTS/alpha" "$(session_path alpha)"
    assert "pick says how to attach outside tmux" grep -qx 'Attach with: tmux attach -t alpha' <<<"$out"
    wait_refresh

    echo 'echo hydrated' >"$WS_PROJECTS/beta/.tmux-ready"
    WS_FZF_PICK=$WS_PROJECTS/beta ws pick >/dev/null 2>&1
    wait_refresh
    for ((i = 0; i < 50; i++)); do
        pane=$(tmux capture-pane -p -t "=beta:")
        grep -q '^hydrated' <<<"$pane" && break
        sleep 0.1
    done
    assert "pick sources the .tmux-ready of a new session" grep -q '^hydrated' <<<"$pane"

    ws new t1 feat/x alpha >/dev/null 2>&1
    tmux kill-session -t "=t1"
    WS_FZF_PICK=$WS_ROOT/t1 ws pick >/dev/null 2>&1
    wait_refresh
    assert_eq "pick remakes a ticket session with its windows" "claude shell env" "$(windows_of t1)"

    mkdir "$WS_PROJECTS/dot.name"
    WS_FZF_PICK=$WS_PROJECTS/dot.name ws pick >/dev/null 2>&1
    wait_refresh
    assert "a dot in a directory name becomes an underscore" has_session dot_name
}

commit_in() {
    { echo "$2" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$2"; } || abort "cannot commit in $1"
}

run_test test_new
run_test test_new_existing_branch
run_test test_new_rerun
run_test test_new_takes_a_dir_without_ws
run_test test_new_refuses
run_test test_ws_file_writes
run_test test_adopt
run_test test_adopt_refuses
run_test test_stage
run_test test_stage_limit
run_test test_rm_refuses
run_test test_rm
run_test test_pick_lists_what_the_sessionizer_listed
run_test test_pick_order
run_test test_status
run_test test_pick_opens
finish
