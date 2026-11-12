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
    tmux has-session -t "=$1:" 2>/dev/null
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
    assert "new says how to attach outside tmux" grep -qxF "Attach with: tmux attach -t '=t1:'" <<<"$out"
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
    assert "a rerun switches, or says how to attach" grep -qxF "Attach with: tmux attach -t '=t1:'" <<<"$out"

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
    assert "pick says how to attach outside tmux" grep -qxF "Attach with: tmux attach -t '=alpha:'" <<<"$out"
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

start_in() {
    local i
    (cd "$1" && exec "${@:2}") >/dev/null 2>&1 &
    STARTED=$!
    for ((i = 0; i < 100; i++)); do
        [[ $(readlink "/proc/$STARTED/cwd" 2>/dev/null) == "$1" && $(cat "/proc/$STARTED/comm" 2>/dev/null) == "$2" ]] &&
            return 0
        sleep 0.05
    done
    abort "process $STARTED did not start in $1"
}

stop_started() {
    local pid
    for pid; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
}

wait_for_file() {
    local i
    for ((i = 0; i < 100; i++)); do
        [[ -s $1 ]] && return 0
        sleep 0.05
    done
    abort "$1 did not appear"
}

outer_tmux() {
    "$(PATH=$_base_path type -P tmux)" -L wsfxout "$@"
}

attached_session() {
    tmux list-clients -F '#{session_name}' 2>/dev/null
}

hint_reaches_session() {
    local shell=$1 hint=$2
    mkdir -p "$FX/hint-bin"
    printf '#!/usr/bin/env bash\n[[ $1 == attach && $2 == -t ]] || exit 9\nexec %q has-session -t "$3"\n' \
        "$FX/bin/tmux" >"$FX/hint-bin/tmux"
    chmod +x "$FX/hint-bin/tmux"
    PATH=$FX/hint-bin:$PATH "$shell" -c "$hint" 2>/dev/null
}

test_dotted_id() {
    local out rc hint shell
    new_fixture_no_ticket
    fake_fzf
    out=$(ws new rel.42 feat/dot alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new takes an id with a dot" 0 "$rc"
    assert_eq "the dotted session has the windows claude, shell, and env" "claude shell env" "$(windows_of rel.42)"
    hint=$(sed -n 's/^Attach with: //p' <<<"$out")
    for shell in bash zsh; do
        if command -v "$shell" >/dev/null; then
            assert "the attach hint, typed into $shell, reaches the dotted session" hint_reaches_session "$shell" "$hint"
        else
            ok "attach hint in $shell skipped: no $shell"
        fi
    done

    out=$(ws new rel.42 feat/dot alpha 2>&1) && rc=0 || rc=$?
    assert_eq "a rerun on a dotted id exits 0" 0 "$rc"
    refute "a rerun makes no second session" grep -q 'duplicate session' <<<"$out"
    assert_eq "a rerun adds no window to the dotted session" "claude shell env" "$(windows_of rel.42)"

    tmux kill-window -t "=rel.42:env"
    WS_FZF_PICK=$WS_ROOT/rel.42 ws pick >/dev/null 2>&1 && rc=0 || rc=$?
    wait_refresh
    assert_eq "pick opens a dotted ticket" 0 "$rc"
    assert_eq "pick repairs the dotted session" "claude shell env" "$(windows_of rel.42)"

    tmux new-session -d -s other -c "$HOME"
    outer_tmux new-session -d -x 120 -y 40 "env -u TMUX $(printf %q "$FX/bin/tmux") attach-session -t '=other:'"
    for ((rc = 0; rc < 100; rc++)); do
        [[ $(attached_session) == other ]] && break
        sleep 0.05
    done
    assert_eq "a client is attached to the other session" other "$(attached_session)"
    TMUX=$TMUX_TMPDIR/tmux-$UID/wsfx,1,0 WS_FZF_PICK=$WS_ROOT/rel.42 ws pick >/dev/null 2>&1
    wait_refresh
    assert_eq "pick from inside tmux switches the client to the dotted ticket" rel.42 "$(attached_session)"
    tmux switch-client -t "=other:" 2>/dev/null
    outer_tmux kill-server 2>/dev/null

    out=$(ws rm rel.42 2>&1) && rc=0 || rc=$?
    assert_eq "rm takes a dotted id" 0 "$rc"
    refute "rm kills the dotted session" has_session rel.42
    refute "rm removes the dotted ticket" test -e "$WS_ROOT/rel.42"
}

test_names_are_ascii() {
    local out rc utf8=""
    new_fixture_no_ticket
    utf8=$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8' | head -n 1)
    [[ -n $utf8 ]] || utf8=C.UTF-8
    out=$(LC_ALL=$utf8 ws new ünï feat/u alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a non-ASCII id under $utf8" 1 "$rc"
    assert "it says the id takes ASCII only" grep -qF "ws: ticket id 'ünï' must start with an ASCII letter or digit" <<<"$out"
    out=$(LC_ALL=$utf8 ws new --topic ünï t1 feat/u alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a non-ASCII --topic under $utf8" 1 "$rc"
    assert "it says --topic takes ASCII only" grep -qF "ws: --topic takes a plain ASCII name" <<<"$out"
    out=$(LC_ALL=$utf8 ws new --ticket ünï t1 feat/u alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a non-ASCII --ticket under $utf8" 1 "$rc"
    out=$(LC_ALL=$utf8 ws new t1 feat/ünï alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new refuses a non-ASCII branch under $utf8" 1 "$rc"
    assert "it names the branch" grep -qF "ws: 'feat/ünï' is not a branch name ws takes" <<<"$out"
    out=$(LC_ALL=$utf8 ws adopt ünï "$WS_PROJECTS/alpha-open" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a non-ASCII id under $utf8" 1 "$rc"
    out=$(LC_ALL=$utf8 ws stage ünï qa 2>&1) && rc=0 || rc=$?
    assert_eq "stage refuses a non-ASCII id under $utf8" 1 "$rc"
    assert_eq "WS_ROOT stays empty" "" "$(find "$WS_ROOT" -mindepth 1 -maxdepth 1 -printf '%P\n')"
}

test_rm_refuses_a_foreign_process() {
    local out rc
    new_fixture_no_ticket
    export WS_PROC=/proc
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    agents '[{"kind":"background","id":"bg1","state":"working","cwd":"'"$WS_ROOT"'/t1","startedAt":0}]'
    start_in "$WS_ROOT/t1/alpha" sleep 300
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$STARTED"
    assert_eq "rm refuses a process outside the ticket's sessions" 1 "$rc"
    assert "it names the process" grep -qF "process $STARTED (sleep) works in ~/work/t1" <<<"$out"
    assert "it keeps the tmux session" has_session t1
    assert_eq "it stops no Claude session" 0 "$(claude_calls '^stop')"
    assert "it keeps alpha" is_worktree "$WS_ROOT/t1/alpha"
    assert "it keeps beta" is_worktree "$WS_ROOT/t1/beta"
    assert "it keeps .ws" test -f "$WS_ROOT/t1/.ws"

    start_in "$WS_ROOT/t1" sleep 300
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$STARTED"
    assert_eq "rm refuses a process in the ticket dir itself" 1 "$rc"
    assert "it keeps both worktrees" is_worktree "$WS_ROOT/t1/beta"
}

test_rm_ignores_its_own_sessions() {
    local out rc host bg2
    new_fixture_no_ticket
    export WS_PROC=/proc
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    tmux split-window -d -t "=t1:shell" -c "$WS_ROOT/t1/alpha" "sleep 300 & wait"
    start_in "$WS_ROOT/t1/beta" bash -c 'sleep 300 & echo $! >"$1"; wait' _ "$FX/bg.pid" --bg-pty-host
    host=$STARTED
    wait_for_file "$FX/bg.pid"
    start_in "$WS_ROOT/t1" sleep 300
    bg2=$STARTED
    agents '[{"kind":"background","id":"bg1","state":"working","cwd":"'"$WS_ROOT"'/t1/beta","pid":'"$(<"$FX/bg.pid")"',"startedAt":0},
        {"kind":"background","id":"bg2","state":"blocked","cwd":"'"$WS_ROOT"'/t1","pid":'"$bg2"',"startedAt":0}]'
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$host" "$(<"$FX/bg.pid")" "$bg2"
    assert_eq "rm takes a ticket whose only processes are its tmux panes and its Claude sessions" 0 "$rc"
    assert_eq "it stops the background session" 1 "$(claude_calls '^stop bg1$')"
    assert_eq "it stops the blocked background session" 1 "$(claude_calls '^stop bg2$')"
    refute "it kills the tmux session" has_session t1
    refute "it removes the ticket" test -e "$WS_ROOT/t1"
}

test_rm_moves_nothing_when_a_process_survives() {
    local out rc pid
    new_fixture_no_ticket
    export WS_PROC=/proc
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    tmux split-window -d -t "=t1:shell" -c "$WS_ROOT/t1" \
        "nohup sleep 300 >/dev/null 2>&1 & echo \$! >$(printf %q "$FX/survivor.pid"); wait"
    wait_for_file "$FX/survivor.pid"
    pid=$(<"$FX/survivor.pid")
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$pid"
    assert_eq "rm exits 1 when a process outlives the session" 1 "$rc"
    refute "it got as far as the kill" has_session t1
    assert "it names the process that outlived the session" \
        grep -qxF "ws: process $pid (sleep) still works in ~/work/t1, so ws moved nothing" <<<"$out"
    assert "it keeps alpha" is_worktree "$WS_ROOT/t1/alpha"
    assert "it keeps beta" is_worktree "$WS_ROOT/t1/beta"
    assert "it keeps .ws" test -f "$WS_ROOT/t1/.ws"
}

proc_state() {
    local stat
    { IFS= read -r stat <"/proc/$1/stat"; } 2>/dev/null || return 1
    stat=${stat##*) }
    printf '%s\n' "${stat%% *}"
}

test_rm_skips_a_process_that_exited() {
    local out rc parent zombie i
    new_fixture_no_ticket
    export WS_PROC=/proc
    ws new t1 feat/x alpha >/dev/null 2>&1
    (cd "$FX" && exec bash -c '(echo "$BASHPID" >"$1" && sleep 0.2) & exec sleep 300' _ "$FX/zombie.pid") &
    parent=$!
    wait_for_file "$FX/zombie.pid"
    zombie=$(<"$FX/zombie.pid")
    for ((i = 0; i < 100; i++)); do
        [[ $(proc_state "$zombie") == Z ]] && break
        sleep 0.05
    done
    assert_eq "a child of sleep has exited and waits for its parent" Z "$(proc_state "$zombie")"
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$parent"
    assert_eq "rm takes a ticket while a process of yours waits to be reaped" 0 "$rc"
    refute "it does not name that process" grep -qF "process $zombie " <<<"$out"
    refute "it removes the ticket" test -e "$WS_ROOT/t1"
}

start_thread_after_main_exits() {
    local i
    (cd "$1" && exec python3 -I -c 'import ctypes, threading, time
threading.Thread(target=time.sleep, args=(300,)).start()
ctypes.CDLL(None).pthread_exit(None)') >/dev/null 2>&1 &
    STARTED=$!
    for ((i = 0; i < 100; i++)); do
        [[ $(proc_state "$STARTED") == Z ]] && return 0
        sleep 0.05
    done
    abort "the main thread of process $STARTED did not exit"
}

test_rm_reads_the_threads_of_a_zombie() {
    local out rc
    if ! command -v python3 >/dev/null; then
        ok "the zombie thread check is skipped: no python3"
        return
    fi
    new_fixture_no_ticket
    export WS_PROC=/proc
    ws new t1 feat/x alpha >/dev/null 2>&1
    start_thread_after_main_exits "$WS_ROOT/t1/alpha"
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$STARTED"
    assert_eq "rm refuses a zombie whose thread still works in the ticket" 1 "$rc"
    assert "it names that process" grep -qF "process $STARTED (python3) works in ~/work/t1" <<<"$out"

    start_thread_after_main_exits "$FX"
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$STARTED"
    assert_eq "rm takes a ticket while a zombie's thread works elsewhere" 0 "$rc"
    refute "it removes the ticket" test -e "$WS_ROOT/t1"
}

test_rm_when_claude_stop_fails() {
    local out rc bg
    new_fixture_no_ticket
    export WS_PROC=/proc
    ws new t1 feat/x alpha >/dev/null 2>&1
    start_in "$WS_ROOT/t1/alpha" sleep 300
    bg=$STARTED
    agents '[{"kind":"background","id":"bgx","state":"working","cwd":"'"$WS_ROOT"'/t1/alpha","pid":'"$bg"',"startedAt":0}]'
    sed -i '/claude\.log"$/a [[ ${1-} != stop ]] || exit 1' "$FX/bin/claude"
    out=$(ws rm t1 2>&1) && rc=0 || rc=$?
    stop_started "$bg"
    assert_eq "rm exits 1 when claude stop fails and the session lives on" 1 "$rc"
    assert "it says claude stop failed" grep -qxF "ws: claude stop bgx failed" <<<"$out"
    assert "it names the session process that still works" \
        grep -qxF "ws: process $bg (sleep) still works in ~/work/t1, so ws moved nothing" <<<"$out"
    refute "it does not say the sessions ended" grep -q 'ended' <<<"$out"
    assert "it keeps alpha" is_worktree "$WS_ROOT/t1/alpha"
}

server_pid() {
    tmux display-message -p '#{pid}' 2>/dev/null
}

wait_gone() {
    local i
    [[ -n $1 ]] || abort "wait_gone needs a pid"
    for ((i = 0; i < 100; i++)); do
        [[ -e /proc/$1 ]] || return 0
        sleep 0.05
    done
    abort "process $1 did not exit"
}

attach_from() {
    local i
    outer_tmux has-session -t '=keep:' 2>/dev/null || outer_tmux new-session -d -s keep -c "$HOME"
    outer_tmux new-session -d -x 120 -y 40 -c "$1" \
        "exec env -u TMUX $(printf %q "$FX/bin/tmux") attach-session -t '=$2:'"
    for ((i = 0; i < 100; i++)); do
        CLIENT=$(tmux list-clients -t "=$2:" -F '#{client_pid}' 2>/dev/null)
        [[ -n $CLIENT ]] && return 0
        sleep 0.05
    done
    abort "no client attached to $2"
}

test_ws_starts_tmux_outside_the_ticket() {
    local out rc pid
    new_fixture_no_ticket
    export WS_PROC=/proc
    mkdir -p "$WS_ROOT/t8"
    (cd "$WS_ROOT/t8" && ws new t8 feat/t8 alpha >/dev/null 2>&1)
    pid=$(server_pid)
    assert_eq "ws new starts the tmux server in /, not in the ticket it runs from" / "$(readlink "/proc/$pid/cwd")"
    out=$(ws rm t8 2>&1) && rc=0 || rc=$?
    assert_eq "rm takes a ticket after ws started tmux from inside it" 0 "$rc"
    refute "it removes that ticket" test -e "$WS_ROOT/t8"

    new_fixture_no_ticket
    fake_fzf
    mkdir -p "$WS_ROOT/t8"
    (cd "$WS_ROOT/t8" && WS_FZF_PICK=$WS_PROJECTS/beta ws pick >/dev/null 2>&1)
    wait_refresh
    pid=$(server_pid)
    assert_eq "ws pick starts the tmux server in /, not in the ticket it runs from" / "$(readlink "/proc/$pid/cwd")"
}

test_rm_ignores_a_tmux_server_in_the_ticket() {
    local out rc pid pane
    new_fixture_no_ticket
    export WS_PROC=/proc
    mkdir -p "$WS_ROOT/t9"
    (cd "$WS_ROOT/t9" && tmux new-session -d -s main -c "$HOME")
    ws new t9 feat/t9 alpha >/dev/null 2>&1
    pid=$(server_pid)
    assert_eq "the tmux server works in the ticket" "$WS_ROOT/t9" "$(readlink "/proc/$pid/cwd")"
    pane=$(tmux new-window -d -P -F '#{pane_pid}' -t "=main:" -c "$WS_ROOT/t9/alpha" "sleep 300") ||
        abort "cannot open a window in main"
    out=$(ws rm t9 2>&1) && rc=0 || rc=$?
    assert_eq "rm refuses a pane of another session on that server" 1 "$rc"
    assert "it names the pane's process, not the server" grep -qF "process $pane (sleep) works in ~/work/t9" <<<"$out"
    stop_started "$pane"
    wait_gone "$pane"
    out=$(ws rm t9 2>&1) && rc=0 || rc=$?
    assert_eq "rm takes a ticket whose tmux server works in it" 0 "$rc"
    refute "it removes the ticket" test -e "$WS_ROOT/t9"
    assert "the server and its other session live on" has_session main
}

test_rm_ignores_a_client_of_its_own_session() {
    local out rc
    new_fixture_no_ticket
    export WS_PROC=/proc
    ws new t7 feat/t7 alpha >/dev/null 2>&1
    tmux new-session -d -s other -c "$HOME"
    attach_from "$WS_ROOT/t7/alpha" other
    out=$(ws rm t7 2>&1) && rc=0 || rc=$?
    stop_started "$CLIENT"
    wait_gone "$CLIENT"
    assert_eq "rm refuses a client of another session that works in the ticket" 1 "$rc"
    assert "it names the client" grep -qF "process $CLIENT (tmux: client) works in ~/work/t7" <<<"$out"

    attach_from "$WS_ROOT/t7/alpha" t7
    out=$(ws rm t7 2>&1) && rc=0 || rc=$?
    outer_tmux kill-server 2>/dev/null
    assert_eq "rm takes a ticket whose own session has a client that works in it" 0 "$rc"
    refute "it kills the session" has_session t7
    refute "it removes the ticket" test -e "$WS_ROOT/t7"
}

test_rm_ticket_without_worktree() {
    local out rc
    new_fixture_no_ticket
    mkdir -p "$WS_ROOT/t5"
    printf 'WS_ID=t5\nWS_BRANCH=feat/t5\n' >"$WS_ROOT/t5/.ws"
    echo notes >"$WS_ROOT/t5/notes.md"
    out=$(ws rm t5 2>&1) && rc=0 || rc=$?
    assert_eq "rm takes a ticket with no worktree" 0 "$rc"
    refute "it removes the ticket dir" test -e "$WS_ROOT/t5"
    out=$(ws prune --restore t5 2>&1) && rc=0 || rc=$?
    assert_eq "restore brings back a ticket with no worktree" 0 "$rc"
    assert_eq "restore brings back its .ws" feat/t5 "$(ws_value t5 WS_BRANCH)"
    assert_eq "restore brings back its other files" notes "$(cat "$WS_ROOT/t5/notes.md" 2>/dev/null)"
    assert "restore says what it restored" grep -qxF "Restored ~/work/t5" <<<"$out"
}

test_adopt_checks_the_session_first() {
    local out rc
    new_fixture_no_ticket
    add_worktree beta "$WS_PROJECTS/beta-six" feat/six
    tmux new-session -d -s t6 -c "$HOME"
    out=$(ws adopt t6 "$WS_PROJECTS/beta-six" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses an id whose tmux session works elsewhere" 1 "$rc"
    assert "it names the session's directory" grep -qF "tmux session t6 works in ~, not ~/work/t6" <<<"$out"
    assert "it moves nothing first" lists_worktree beta "$WS_PROJECTS/beta-six"
    refute "it makes no ticket dir" test -e "$WS_ROOT/t6"
}

test_adopt_refuses_another_tickets_worktree() {
    local out rc
    new_fixture_no_ticket
    ws new t2 feat/t2 alpha >/dev/null 2>&1
    out=$(ws adopt t7 "$WS_ROOT/t2/alpha" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a worktree of another ticket" 1 "$rc"
    assert "it names the ticket" grep -qF "~/work/t2/alpha belongs to ticket t2" <<<"$out"
    assert "the worktree stays in its ticket" lists_worktree alpha "$WS_ROOT/t2/alpha"
    refute "it makes no ticket dir" test -e "$WS_ROOT/t7"
}

test_adopt_checks_the_ticket_before_it_moves() {
    local out rc
    new_fixture_no_ticket
    add_worktree alpha "$WS_PROJECTS/alpha-d1" feat/d1
    mkdir -p "$WS_ROOT/d1"
    printf 'WS_ID=d1\nnot a pair\n' >"$WS_ROOT/d1/.ws"
    out=$(ws adopt d1 "$WS_PROJECTS/alpha-d1" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a ticket with a malformed .ws" 1 "$rc"
    assert "it says which line" grep -qF "line 2 of ~/work/d1/.ws is not KEY=value" <<<"$out"
    assert "it moves nothing first" lists_worktree alpha "$WS_PROJECTS/alpha-d1"

    add_worktree alpha "$WS_PROJECTS/alpha-d2" 'feat/a=b'
    out=$(ws adopt d2 "$WS_PROJECTS/alpha-d2" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a branch ws does not take" 1 "$rc"
    assert "it names the branch" grep -qF "'feat/a=b' is not a branch name ws takes" <<<"$out"
    assert "it moves nothing first" lists_worktree alpha "$WS_PROJECTS/alpha-d2"
    refute "it makes no ticket dir" test -e "$WS_ROOT/d2"

    add_worktree alpha "$WS_PROJECTS/alpha-d3" feat/d3
    mkdir -p "$FX/elsewhere"
    ln -s "$FX/elsewhere" "$WS_ROOT/d3"
    out=$(ws adopt d3 "$WS_PROJECTS/alpha-d3" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a ticket dir that is a symlink" 1 "$rc"
    assert "it says the ticket is no directory" grep -qF "~/work/d3 is not a directory" <<<"$out"
    assert "it moves nothing first" lists_worktree alpha "$WS_PROJECTS/alpha-d3"
    assert_eq "nothing lands where the symlink points" "" "$(ls -A "$FX/elsewhere")"

    add_worktree alpha "$WS_PROJECTS/alpha-d4" feat/d4
    mkdir -p "$WS_ROOT/d4"
    printf 'WS_ID=d4\nWS_BRANCH=feat/d4\nWS_REPOS="beta gamma"\n' >"$WS_ROOT/d4/.ws"
    out=$(ws adopt d4 "$WS_PROJECTS/alpha-d4" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a ticket whose .ws lists a repo ws cannot make" 1 "$rc"
    assert "it names the repo" grep -qF "~/projects/gamma is not a git checkout" <<<"$out"
    assert "it moves nothing first" lists_worktree alpha "$WS_PROJECTS/alpha-d4"
    refute "it makes no worktree first" test -e "$WS_ROOT/d4/beta"

    printf 'WS_ID=d4\nWS_BRANCH=feat/d4\nWS_REPOS=beta\n' >"$WS_ROOT/d4/.ws"
    out=$(ws adopt d4 "$WS_PROJECTS/alpha-d4" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt takes the ticket once its .ws lists repos ws can make" 0 "$rc"
    assert "it moves the worktree in" lists_worktree alpha "$WS_ROOT/d4/alpha"
    assert "it makes the repo .ws lists" is_worktree "$WS_ROOT/d4/beta"
}

test_adopt_names_both_branches() {
    local out rc
    new_fixture_no_ticket
    add_worktree alpha "$WS_PROJECTS/alpha-t3" feat/t3
    ws adopt t3 "$WS_PROJECTS/alpha-t3" >/dev/null 2>&1
    out=$(ws adopt t3 "$WS_ROOT/t3/alpha" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a worktree that is in the ticket already" 1 "$rc"
    assert "it names the taken path" grep -qF "~/work/t3/alpha exists" <<<"$out"
    refute "it prints no message with an empty branch name" grep -qE "''|, not $" <<<"$out"

    add_worktree beta "$WS_PROJECTS/beta-other" feat/other
    out=$(ws adopt t3 "$WS_PROJECTS/beta-other" 2>&1) && rc=0 || rc=$?
    assert_eq "adopt refuses a worktree on another branch than the ticket" 1 "$rc"
    assert "it names both branches" grep -qxF "ws: ticket t3 is on branch feat/t3, not feat/other" <<<"$out"
    assert "it moves nothing" lists_worktree beta "$WS_PROJECTS/beta-other"
}

age_pr_cache() {
    jq --argjson t "$(($(date +%s) - $1))" '.prs.time = $t' "$XDG_CACHE_HOME/ws/status.json" >"$FX/status.new" &&
        mv "$FX/status.new" "$XDG_CACHE_HOME/ws/status.json"
}

test_status_retries_a_gh_failure_soon() {
    local before
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    add_pr alpha feat/x OPEN 12 "$(head_of "$WS_ROOT/t1/alpha")"
    ws status --refresh
    age_pr_cache 61
    before=$(gh_calls)
    ws status --refresh
    assert_eq "a good PR state stays cached for WS_PR_TTL" "$before" "$(gh_calls)"

    : >"$FX/gh.fail"
    WS_PR_TTL=0 ws status --refresh 2>/dev/null
    rm "$FX/gh.fail"
    assert "a failed gh call is cached" grep -qE '^t1 +spec +pr:failed +feat/x$' <<<"$(ws ls)"
    age_pr_cache 30
    before=$(gh_calls)
    ws status --refresh
    assert_eq "a failure 30 s old stays cached" "$before" "$(gh_calls)"
    age_pr_cache 61
    ws status --refresh
    assert "a failure over 60 s old asks gh again" test "$(gh_calls)" -gt "$before"
    assert "the new state replaces the failure" grep -qE '^t1 +spec +pr:open +feat/x$' <<<"$(ws ls)"
}

most_gh_at_once() {
    awk '{ print $2, ($1 == "start" ? 1 : -1) }' "$FX/gh.times" | sort -k1,1n -k2,2n |
        awk '{ n += $2; if (n > max) max = n } END { print max + 0 }'
}

test_gh_calls_run_eight_at_a_time() {
    local n
    new_fixture_no_ticket
    for n in $(seq 12); do
        mkdir -p "$WS_ROOT/m$n"
        printf 'WS_ID=m%s\nWS_BRANCH=feat/m%s\nWS_REPOS=alpha\nWS_STAGE=spec\n' "$n" "$n" >"$WS_ROOT/m$n/.ws"
    done
    echo 0.4 >"$FX/gh.slow"
    ws status --refresh
    assert_eq "every ticket branch gets one gh call" 12 "$(grep -c '^start' "$FX/gh.times")"
    n=$(most_gh_at_once)
    assert "at most 8 gh calls run at once ($n ran)" test "$n" -le 8
    assert "gh calls still run in parallel ($n ran)" test "$n" -ge 2
}

test_claude_md_keeps_edits() {
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    assert "a rerun rewrites an unedited CLAUDE.md with the new repo" \
        grep -qF '`beta/` belongs to `~/projects/beta`' "$WS_ROOT/t1/CLAUDE.md"

    echo "my notes" >>"$WS_ROOT/t1/CLAUDE.md"
    tmux kill-window -t "=t1:env"
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    assert "new keeps an edited CLAUDE.md" grep -qx "my notes" "$WS_ROOT/t1/CLAUDE.md"
    assert "new still repairs the rest" test "$(windows_of t1)" = "claude shell env"

    add_worktree alpha "$WS_PROJECTS/alpha-t2" feat/t2
    ws new t2 feat/t2 beta >/dev/null 2>&1
    echo "t2 notes" >>"$WS_ROOT/t2/CLAUDE.md"
    ws adopt t2 "$WS_PROJECTS/alpha-t2" >/dev/null 2>&1
    assert "adopt moves the worktree in" lists_worktree alpha "$WS_ROOT/t2/alpha"
    assert "adopt keeps an edited CLAUDE.md" grep -qx "t2 notes" "$WS_ROOT/t2/CLAUDE.md"
}

claude_md_of_2_0_66() {
    local id=$1 branch=$2 repo
    shift 2
    printf '# Ticket %s\n\nws wrote this file and writes it again on each `ws new %s`. It imports no other file.\n\n' "$id" "$id"
    printf -- '- Each repo directory here is a git worktree on branch `%s`.\n' "$branch"
    for repo; do
        printf -- '  - `%s/` belongs to `~/projects/%s`.\n' "$repo" "$repo"
    done
    printf -- '- `.ws` holds the ticket state, and only ws writes it. Run `ws stage <stage>` here to move the ticket on.\n'
    printf -- '- Log progress with `~/vault/bin/vault-log %s "<what changed>"`.\n' "$id"
}

test_claude_md_of_an_older_ws_updates() {
    new_fixture_no_ticket
    ws new t4 feat/t4 alpha >/dev/null 2>&1
    claude_md_of_2_0_66 t4 feat/t4 alpha >"$WS_ROOT/t4/CLAUDE.md"
    ws new t4 feat/t4 alpha beta >/dev/null 2>&1
    assert "a rerun rewrites a CLAUDE.md that ws 2.0.66 wrote" \
        grep -qF '`beta/` belongs to `~/projects/beta`' "$WS_ROOT/t4/CLAUDE.md"
    assert "it writes the current header" grep -qF 'writes it again until you edit it.' "$WS_ROOT/t4/CLAUDE.md"

    ws new t5 feat/t5 alpha >/dev/null 2>&1
    { claude_md_of_2_0_66 t5 feat/t5 alpha && echo "my notes"; } >"$WS_ROOT/t5/CLAUDE.md"
    ws new t5 feat/t5 alpha beta >/dev/null 2>&1
    assert "a rerun keeps an edited CLAUDE.md that ws 2.0.66 wrote" grep -qx "my notes" "$WS_ROOT/t5/CLAUDE.md"
    refute "it adds no repo to it" grep -qF '`beta/`' "$WS_ROOT/t5/CLAUDE.md"
}

zsh_launch() {
    local zd=$FX/zdot
    mkdir -p "$zd"
    cp "$WS_TESTS/../../dotfiles/zsh/.zshrc" "$zd/.zshrc"
    printf 'echo ALIVE-$((6 * 7))\nexit\n' |
        env -i HOME="$FX/zhome" ZDOTDIR="$zd" TERM=dumb DISPLAY=:99 "$@" timeout 20 zsh -i 2>&1
}

test_zsh_launch_line() {
    local out rc ro
    if ! command -v zsh >/dev/null; then
        ok "zsh launch line skipped: no zsh"
        return
    fi
    new_fixture_no_ticket
    mkdir -p "$FX/zhome" "$FX/nobin" "$FX/okbin" "$FX/failbin" "$FX/realbin"
    for cmd in zsh env timeout cat; do
        ln -s "$(type -P "$cmd")" "$FX/nobin/$cmd"
    done
    printf '#!/bin/sh\necho "$@" >>%q\nexit 0\n' "$FX/tmux-ok.log" >"$FX/okbin/tmux"
    printf '#!/bin/sh\nexit 1\n' >"$FX/failbin/tmux"
    printf '#!/bin/sh\nexec %q -L wsfxz "$@"\n' "$(PATH=$_base_path type -P tmux)" >"$FX/realbin/tmux"
    chmod +x "$FX/okbin/tmux" "$FX/failbin/tmux" "$FX/realbin/tmux"

    out=$(zsh_launch PATH="$FX/nobin") && rc=0 || rc=$?
    assert "a desktop terminal without tmux gets a shell" grep -q ALIVE-42 <<<"$out"

    ro=$FX/ro-sockets
    mkdir -p "$ro"
    chmod 555 "$ro"
    out=$(zsh_launch PATH="$FX/realbin:$FX/nobin" TMUX_TMPDIR="$ro") && rc=0 || rc=$?
    chmod 755 "$ro"
    assert "tmux fails on the unwritable socket dir" grep -qF "couldn't create directory" <<<"$out"
    assert "a desktop terminal whose tmux fails gets a shell" grep -q ALIVE-42 <<<"$out"

    out=$(zsh_launch PATH="$FX/failbin:$FX/nobin") && rc=0 || rc=$?
    assert "a tmux that exits 1 leaves a shell" grep -q ALIVE-42 <<<"$out"

    out=$(zsh_launch PATH="$FX/okbin:$FX/nobin") && rc=0 || rc=$?
    assert_eq "a desktop terminal runs tmux new-session -A -s main" "new-session -A -s main" "$(cat "$FX/tmux-ok.log")"
    refute "the terminal closes when tmux exits 0" grep -q ALIVE-42 <<<"$out"
    assert_eq "and the shell exits 0" 0 "$rc"

    out=$(zsh_launch PATH="$FX/okbin:$FX/nobin" TMUX=/tmp/x,1,0) && rc=0 || rc=$?
    assert "a shell inside tmux starts no tmux" grep -q ALIVE-42 <<<"$out"
}

alacritty_shell() {
    awk '
        /^\[/ { shell = ($0 == "[terminal.shell]"); next }
        shell && sub(/^program *= *"/, "") { sub(/".*/, ""); print }
        shell && sub(/^args *= *\[/, "") {
            sub(/\].*/, "")
            n = split($0, arg, ",")
            for (i = 1; i <= n; i++) {
                gsub(/^ *"|" *$/, "", arg[i])
                print arg[i]
            }
        }' "$WS_TESTS/../../dotfiles/alacritty/alacritty.toml"
}

alacritty_launch() {
    local hide=$1 cmd tmux
    local -a shell=()
    shift
    mapfile -t shell < <(alacritty_shell)
    ((${#shell[@]})) || abort "alacritty.toml names no shell program"
    [[ $TMUX_TMPDIR == /tmp/wsx.* ]] || abort "TMUX_TMPDIR is not the fixture's"
    mkdir -p "$FX/zhome"
    cp "$WS_TESTS/../../dotfiles/zsh/.zshrc" "$WS_TESTS/../../dotfiles/zsh/.zprofile" "$FX/zhome/"
    printf -v cmd '%q ' env -i HOME="$FX/zhome" TERM=xterm-256color WAYLAND_DISPLAY=wayland-9 TMUX_TMPDIR="$TMUX_TMPDIR" "$@" "${shell[@]}"
    if [[ $hide == no-tmux ]]; then
        tmux=$(PATH=$_base_path type -P tmux)
        : >"$FX/no-tmux"
        printf -v cmd 'unshare -rm sh -c %q' "mount --bind $(printf %q "$FX/no-tmux") $(printf %q "$tmux") && exec $cmd"
    fi
    { sleep 1 && printf 'echo ALIVE-$((6 * 7))\n' && sleep 1 && printf 'exit\n' && sleep 0.5; } |
        SHELL=$(PATH=$_base_path type -P bash) timeout -k 2 20 script -qfec "$cmd" /dev/null 2>&1 | tr -d '\r'
    env -u TMUX TMUX_TMPDIR="$TMUX_TMPDIR" "$(PATH=$_base_path type -P tmux)" kill-server 2>/dev/null
}

test_alacritty_opens_a_shell_when_tmux_fails() {
    local out ro
    if ! command -v zsh >/dev/null || ! command -v script >/dev/null || ! unshare -rm true 2>/dev/null; then
        ok "alacritty launch skipped: no zsh, script, or unshare"
        return
    fi
    new_fixture_no_ticket
    mkdir -p "$FX/nobin" "$FX/okbin" "$FX/realbin"
    for cmd in zsh env cat; do
        ln -s "$(type -P "$cmd")" "$FX/nobin/$cmd"
    done
    printf '#!/bin/sh\necho "$@" >>%q\nexit 0\n' "$FX/tmux-ok.log" >"$FX/okbin/tmux"
    printf '#!/bin/sh\nexec %q -L wsfxa "$@"\n' "$(PATH=$_base_path type -P tmux)" >"$FX/realbin/tmux"
    chmod +x "$FX/okbin/tmux" "$FX/realbin/tmux"

    out=$(alacritty_launch no-tmux PATH="$FX/nobin")
    assert "a new alacritty without tmux gets a shell" grep -q ALIVE-42 <<<"$out"

    ro=$FX/ro-sockets
    mkdir -p "$ro"
    chmod 555 "$ro"
    out=$(alacritty_launch tmux PATH="$FX/realbin:$FX/nobin" TMUX_TMPDIR="$ro")
    chmod 755 "$ro"
    assert "a new alacritty whose tmux fails gets a shell" grep -q ALIVE-42 <<<"$out"

    out=$(alacritty_launch tmux PATH="$FX/okbin:$FX/nobin")
    assert_eq "a new alacritty runs tmux new-session -A -s main" "new-session -A -s main" "$(cat "$FX/tmux-ok.log" 2>/dev/null)"
    refute "it closes when tmux exits 0" grep -q ALIVE-42 <<<"$out"
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
run_test test_dotted_id
run_test test_names_are_ascii
run_test test_rm_refuses_a_foreign_process
run_test test_rm_ignores_its_own_sessions
run_test test_rm_moves_nothing_when_a_process_survives
run_test test_rm_skips_a_process_that_exited
run_test test_rm_reads_the_threads_of_a_zombie
run_test test_rm_when_claude_stop_fails
run_test test_ws_starts_tmux_outside_the_ticket
run_test test_rm_ignores_a_tmux_server_in_the_ticket
run_test test_rm_ignores_a_client_of_its_own_session
run_test test_rm_ticket_without_worktree
run_test test_adopt_checks_the_session_first
run_test test_adopt_refuses_another_tickets_worktree
run_test test_adopt_checks_the_ticket_before_it_moves
run_test test_adopt_names_both_branches
run_test test_status_retries_a_gh_failure_soon
run_test test_gh_calls_run_eight_at_a_time
run_test test_claude_md_keeps_edits
run_test test_claude_md_of_an_older_ws_updates
run_test test_zsh_launch_line
run_test test_alacritty_opens_a_shell_when_tmux_fails
finish
