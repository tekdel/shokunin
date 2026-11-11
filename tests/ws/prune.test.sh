#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

WS_BIN=$WS_TESTS/../../dotfiles/bin/ws

gh_calls() {
    local line pattern n=0
    while IFS= read -r line; do
        for pattern; do
            if [[ $pattern == !* ]]; then
                [[ " $line " != *" ${pattern#!} "* ]] || continue 2
            else
                [[ " $line " == *" $pattern "* ]] || continue 2
            fi
        done
        n=$((n + 1))
    done <"$FX/gh.log"
    echo "$n"
}

wait_for() {
    local i
    for ((i = 0; i < 200; i++)); do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 0.05
    done
    return 1
}

commit_file() {
    { echo "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$3"; } || abort "cannot commit $2 in $1"
}

rows() {
    awk -F '  +' 'NF >= 5 && $1 ~ /^(REMOVE|KEEP)/' <<<"$1" | wc -l
}

merged_worktree() {
    add_worktree alpha "$1" "$2"
    add_pr alpha "$2" MERGED "$3" "$(head_of "$1")"
}

answer_yes_at_prompt() {
    local fn=$1 pid answer
    shift
    rm -f "$FX/answer"
    mkfifo "$FX/answer"
    ws "$@" <"$FX/answer" >"$FX/out" 2>"$FX/err" &
    pid=$!
    exec {answer}>"$FX/answer"
    wait_for "$FX/out" '\[y/N\]'
    "$fn"
    # ws may have exited already; a write to the closed fifo must not kill the suite.
    trap '' PIPE
    { echo y >&"$answer"; } 2>/dev/null
    trap - PIPE
    exec {answer}>&-
    wait "$pid"
}

wrap_gh() {
    mv "$FX/bin/gh" "$FX/bin/gh-real"
    printf '#!/usr/bin/env bash\n%s\nexec %q "$@"\n' "$1" "$FX/bin/gh-real" >"$FX/bin/gh"
    chmod +x "$FX/bin/gh"
}

test_dry_run() {
    new_fixture
    local before out
    before=$(snapshot alpha beta)
    out=$(ws prune)
    assert_eq "dry run exits 0" 0 $?
    assert_eq "dry run leaves git worktree list unchanged" "$before" "$(snapshot alpha beta)"
    refute "dry run makes no trash" test -e "$(trash_dir)"
    assert_eq "summary line counts every class" \
        "REMOVE 3  KEEP 6 (open 2, no-pr 1, detached 1, dirty 1, unpushed 1)" "$(tail -n1 <<<"$out")"
    assert_eq "a merged PR outranks older and newer closed ones" "#2 merged" \
        "$(pr_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert_eq "the newest of two merged PRs shows" "#11 merged" "$(pr_of "$out" "$WS_PROJECTS/alpha-dirty")"
    assert_eq "an open PR outranks a newer merged one" "KEEP open" "$(action_of "$out" "$WS_PROJECTS/alpha-open")"
    assert_eq "the open PR shows" "#6 open" "$(pr_of "$out" "$WS_PROJECTS/alpha-open")"
}

test_help() {
    new_fixture
    local help reason
    help=$(ws prune --help)
    for reason in unreadable no-github detached open no-pr locked submodules dirty hidden-flags odd-name \
        nested-repo ignored-unique in-use unpushed head-not-in-pr cross-fs; do
        assert "help explains KEEP $reason" grep -Eq "^  $reason +[[:alpha:]]" <<<"$help"
    done
    assert "help names the trash" grep -q WS_TRASH <<<"$help"
    assert "help names the regenerable table" grep -q WS_REGENERABLE <<<"$help"
    assert "help names the processes the in-use check cannot see" grep -q "other users" <<<"$help"
    assert "help says the in-use check asks docker and podman" grep -q "docker and podman" <<<"$help"
    assert "help names what the container check cannot see" grep -q "named volumes" <<<"$help"
    assert "help says a zombie process makes rows unreadable" grep -q "zombie" <<<"$help"
    assert "help says orphans are never deleted" grep -qi "orphan" <<<"$help"
    assert "help gives how long before the removal --purge asks the engines" \
        grep -q "asks the engines about [0-9]* ms before the removal" <<<"$(tr '\n' ' ' <<<"$help" | tr -s ' ')"
    assert "help says ws takes no lock" grep -q "takes no lock" <<<"$(tr '\n' ' ' <<<"$help" | tr -s ' ')"
    assert "help says a worktree that appears in a ticket dir after the check moves with it" \
        grep -q "appears in a ticket dir after" <<<"$(tr '\n' ' ' <<<"$help" | tr -s ' ')"
}

test_gh_calls() {
    new_fixture
    GH_HOST=ghe.example.invalid ws prune >/dev/null
    local repo state
    for repo in alpha beta; do
        for state in open all; do
            assert_eq "$repo has one --state $state --limit 1000 call on github.com" 1 \
                "$(gh_calls "-R github.com/fixture/$repo" "--state $state" "--limit 1000" '!--head')"
        done
    done
    assert_eq "a branch with no PR in the lists is confirmed by --head" 1 \
        "$(gh_calls "-R github.com/fixture/alpha" "--head feat/nopr" "--state all")"
    assert_eq "branches found in the lists get no --head call" 1 "$(gh_calls --head)"
}

test_gh_parallel() {
    new_fixture
    echo 1 >"$FX/gh.slow"
    ws prune >/dev/null
    local last_start first_end
    last_start=$(awk '$1 == "start" && !/--head/ { print $2 }' "$FX/gh.times" | sort -n | tail -n1)
    first_end=$(awk '$1 == "end" && !/--head/ { print $2 }' "$FX/gh.times" | sort -n | head -n1)
    assert_eq "four list calls ran" 4 "$(awk '$1 == "start" && !/--head/' "$FX/gh.times" | wc -l)"
    assert "every list call starts before any list call ends" \
        awk -v s="$last_start" -v e="$first_end" 'BEGIN { exit !(s < e) }'
}

test_apply_yes() {
    new_fixture
    local out m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta
    out=$(ws prune --apply <<<y 2>"$FX/err")
    assert_eq "apply exits 0" 0 $?
    assert_eq "a successful apply prints nothing on stderr" "" "$(<"$FX/err")"

    assert_eq "merged clean worktree is REMOVE" REMOVE "$(action_of "$out" "$m")"
    assert "merged clean worktree moved to the trash" in_trash "$m"
    assert "the trash entry is named by a UTC stamp and the worktree name" \
        grep -Eqx "$(trash_dir)/[0-9]{8}T[0-9]{6}Z-alpha-merged" <<<"$(trash_of "$m")"
    assert "the trash entry keeps its files" test -f "$(trash_of "$m")/work.txt"
    assert "the merged branch stays until purge" has_branch alpha feat/merged
    assert "the output names the trash entry" grep -q "^Moved ~/projects/alpha-merged to ~/.local/share/ws/trash/" <<<"$out"

    assert_eq "closed clean worktree is REMOVE" REMOVE "$(action_of "$out" "$c")"
    assert "closed clean worktree moved to the trash" in_trash "$c"
    assert "closed branch is kept" has_branch alpha feat/closed

    assert_eq "merged ticket worktree under WS_ROOT is REMOVE" REMOVE "$(action_of "$out" "$b")"
    assert "merged ticket worktree moved under the ticket's trash dir" \
        grep -Eqx "$(trash_dir)/[0-9]{8}T[0-9]{6}Z-t1/beta" <<<"$(trash_of "$b")"
    assert "the ticket dir stays while it holds another repo" is_worktree "$WS_ROOT/t1/alpha"

    assert_eq "merged dirty worktree is KEEP dirty" "KEEP dirty" "$(action_of "$out" "$WS_PROJECTS/alpha-dirty")"
    assert "merged dirty worktree survives" is_worktree "$WS_PROJECTS/alpha-dirty"
    assert_eq "merged worktree with a local commit is KEEP unpushed" "KEEP unpushed" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-unpushed")"
    assert "unpushed worktree survives" is_worktree "$WS_PROJECTS/alpha-unpushed"
    assert_eq "open PR worktree is KEEP open" "KEEP open" "$(action_of "$out" "$WS_PROJECTS/alpha-open")"
    assert "open PR worktree survives" is_worktree "$WS_PROJECTS/alpha-open"
    assert_eq "same branch with an open PR in another repo is KEEP open" "KEEP open" \
        "$(action_of "$out" "$WS_ROOT/t1/alpha")"
    assert_eq "branch without a PR is KEEP no-pr" "KEEP no-pr" "$(action_of "$out" "$WS_PROJECTS/alpha-nopr")"
    assert "no-PR worktree survives" is_worktree "$WS_PROJECTS/alpha-nopr"
    assert_eq "detached worktree is KEEP detached" "KEEP detached" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-detached")"
    assert "detached worktree survives without --include-detached" is_worktree "$WS_PROJECTS/alpha-detached"
    refute "no prunable entries remain" grep -q "^prunable" <<<"$(snapshot alpha beta)"
}

test_meta_record() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged head start end time meta
    head=$(head_of "$m")
    start=$(date +%s)
    ws prune --apply <<<y >/dev/null 2>&1
    end=$(date +%s)
    meta=$(meta_of "$m")
    assert "the entry sits beside its record, named by it" is_worktree "${meta%.meta}"
    assert_eq "the record names the original path" "$m" "$(meta_get "$m" orig)"
    assert_eq "the record names the main repo" "$WS_PROJECTS/alpha/.git" "$(meta_get "$m" common)"
    assert_eq "the record names the branch" feat/merged "$(meta_get "$m" branch)"
    assert_eq "the record names HEAD" "$head" "$(meta_get "$m" head)"
    assert_eq "the record names the PR" 2 "$(meta_get "$m" pr)"
    assert_eq "the record names the PR state" merged "$(meta_get "$m" state)"
    assert_eq "the record names the merged headRefOid" "$head" "$(meta_get "$m" oid)"
    assert_eq "a worktree outside a ticket has no ticket" "" "$(meta_get "$m" ticket)"
    assert_eq "a ticket worktree's record names its ticket" "$WS_ROOT/t1" "$(meta_get "$WS_ROOT/t1/beta" ticket)"
    time=$(meta_get "$m" time)
    assert "the record holds the move time" test "$time" -ge "$start" -a "$time" -le "$end"
    refute "the record holds no trash path" grep -q '^trash=' "$meta"
    assert_eq "one record per moved worktree" 3 "$(find "$(trash_dir)" -name '*.meta' | wc -l)"
    refute "no pending record is left" test -n "$(find "$(trash_dir)" -name '*.meta.tmp')"
    refute "no shared manifest file" test -e "$(trash_dir)/manifest"
}

test_apply_no() {
    new_fixture
    local before out
    before=$(snapshot alpha beta)
    ws prune --apply <<<n >/dev/null
    assert_eq "declined apply exits 0" 0 $?
    assert_eq "declined apply moves nothing" "$before" "$(snapshot alpha beta)"
    out=$(ws prune --apply </dev/null)
    assert "end of input at the prompt ends the prompt line" grep -qx "Nothing moved." <<<"$out"
    assert_eq "end of input moves nothing" "$before" "$(snapshot alpha beta)"
}

test_include_detached() {
    new_fixture
    local out d=$WS_PROJECTS/alpha-detached
    out=$(ws prune --apply --include-detached <<<y 2>/dev/null)
    assert_eq "clean detached worktree is REMOVE with --include-detached" REMOVE "$(action_of "$out" "$d")"
    assert "clean detached worktree moved to the trash" in_trash "$d"

    new_fixture
    d=$WS_PROJECTS/alpha-detached
    echo edit >>"$d/README"
    out=$(ws prune --apply --include-detached <<<y 2>/dev/null)
    assert_eq "dirty detached worktree is KEEP dirty with --include-detached" "KEEP dirty" "$(action_of "$out" "$d")"
    assert "dirty detached worktree survives" is_worktree "$d"

    new_fixture
    local l=$WS_PROJECTS/alpha-det2 commit
    git -C "$WS_PROJECTS/alpha" worktree add -q --detach "$l"
    commit_file "$l" local.txt "local only on detached HEAD"
    commit=$(head_of "$l")
    out=$(ws prune --apply --include-detached <<<y 2>/dev/null)
    assert_eq "a detached worktree with a local commit is KEEP unpushed" "KEEP unpushed" "$(action_of "$out" "$l")"
    assert_eq "that commit survives in place" "$commit" "$(git -C "$l" rev-parse HEAD 2>&1)"
}

test_gh_failure() {
    new_fixture
    local before err code
    before=$(snapshot alpha beta)
    echo beta >"$FX/gh.fail"
    err=$(ws prune --apply <<<y 2>&1 >/dev/null)
    code=$?
    assert_eq "gh failure exits 2" 2 "$code"
    assert "gh failure names the repo" grep -q "cannot read PR state for beta" <<<"$err"
    refute "gh failure does not blame a repo that answered" grep -q "for alpha" <<<"$err"
    assert_eq "gh failure moves nothing" "$before" "$(snapshot alpha beta)"
}

test_gh_partial_failures() {
    new_fixture
    local before out
    before=$(snapshot alpha beta)
    wrap_gh '[[ " $* " != *" --head "* ]] || { echo "HTTP 502" >&2; exit 1; }'
    out=$(ws prune --apply <<<y 2>&1)
    assert_eq "a failed --head call exits 2" 2 $?
    assert "a failed --head call names the repo" grep -q "cannot read PR state for alpha" <<<"$out"
    assert_eq "a failed --head call moves nothing" "$before" "$(snapshot alpha beta)"

    new_fixture
    before=$(snapshot alpha beta)
    wrap_gh 'if [[ " $* " == *" --state open "* ]]; then echo "[]"; echo "HTTP 502" >&2; exit 1; fi'
    ws prune --apply <<<y >/dev/null 2>&1
    assert_eq "an open call that prints a list and fails exits 2" 2 $?
    assert_eq "that failure moves nothing" "$before" "$(snapshot alpha beta)"
}

test_gh_bad_output() {
    new_fixture
    local before body code
    before=$(snapshot alpha beta)
    for body in null '{}' '{"message":"API rate limit exceeded"}' '' '[{"headRefName":"feat/merged","sta' '[1]'; do
        printf '%s' "$body" >"$FX/gh.out"
        ws prune --apply <<<y >/dev/null 2>&1
        code=$?
        assert_eq "gh output '$body' exits 2" 2 "$code"
        assert_eq "gh output '$body' moves nothing" "$before" "$(snapshot alpha beta)"
    done

    rm "$FX/gh.out"
    wrap_gh '[[ " $* " != *" --state open "* ]] || exit 0'
    ws prune --apply <<<y >/dev/null 2>&1
    assert_eq "an empty answer to one of two gh calls exits 2" 2 $?
    assert_eq "that empty answer moves nothing" "$before" "$(snapshot alpha beta)"

    new_fixture
    local out
    printf 'alpha\tfeat/merged\tMERGED\t2.5\t%s\tfalse\n' "$(head_of "$WS_PROJECTS/alpha-merged")" >>"$FX/prs.tsv"
    printf 'alpha\tfeat/closed\tCLOSED\t50\tnot-an-oid\tfalse\n' >>"$FX/prs.tsv"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a PR with a bad number is KEEP unreadable" "KEEP unreadable" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert_eq "a PR with a bad headRefOid is KEEP unreadable" "KEEP unreadable" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-closed")"
    assert "those worktrees survive" is_worktree "$WS_PROJECTS/alpha-closed"
}

test_gh_timeout() {
    new_fixture
    local before err code start
    before=$(snapshot alpha beta)
    echo 30 >"$FX/gh.slow"
    start=$SECONDS
    err=$(WS_GH_TIMEOUT=1 ws prune --apply <<<y 2>&1 >/dev/null)
    code=$?
    assert_eq "a gh call past the timeout exits 2" 2 "$code"
    assert "the timeout names the repo" grep -q "cannot read PR state for alpha" <<<"$err"
    assert "the run stops at the timeout" test $((SECONDS - start)) -lt 10
    assert_eq "a gh timeout moves nothing" "$before" "$(snapshot alpha beta)"
}

test_dirty_ignores_user_config() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    git -C "$WS_PROJECTS/alpha" config status.showUntrackedFiles no
    echo draft >"$m/draft.md"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "an untracked file is dirty under status.showUntrackedFiles=no" "KEEP dirty" "$(action_of "$out" "$m")"
    assert "the untracked file survives apply" test -f "$m/draft.md"
}

test_hidden_flags() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed out
    echo local-edit >>"$m/work.txt"
    git -C "$m" update-index --skip-worktree work.txt
    echo local-edit >>"$c/work.txt"
    git -C "$c" update-index --assume-unchanged work.txt
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a skip-worktree file is KEEP hidden-flags" "KEEP hidden-flags" "$(action_of "$out" "$m")"
    assert "the skip-worktree edit survives apply" grep -q local-edit "$m/work.txt"
    assert_eq "an assume-unchanged file is KEEP hidden-flags" "KEEP hidden-flags" "$(action_of "$out" "$c")"
    assert "the assume-unchanged edit survives apply" grep -q local-edit "$c/work.txt"
}

test_ignored_files() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta
    local n=$WS_PROJECTS/alpha-nestwt nested out
    printf '.env\nnode_modules/\n.wt/\n' >>"$WS_PROJECTS/alpha/.git/info/exclude"
    echo SECRET=only-copy >"$m/.env"
    echo SHARED=1 >"$WS_PROJECTS/alpha/.env"
    cp "$WS_PROJECTS/alpha/.env" "$c/.env"
    mkdir -p "$c/node_modules/pkg"
    echo regenerable >"$c/node_modules/pkg/index.js"

    echo vendor/ >>"$WS_PROJECTS/beta/.git/info/exclude"
    git init -q "$b/vendor/lib"
    commit_file "$b/vendor/lib" b "nested only copy"
    nested=$(head_of "$b/vendor/lib")

    merged_worktree "$n" feat/nestwt 40
    git -C "$WS_PROJECTS/beta" worktree add -q -b feat/inner "$n/.wt/beta"

    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "an ignored file with no copy in the main checkout is KEEP ignored-unique" \
        "KEEP ignored-unique" "$(action_of "$out" "$m")"
    assert_eq "the table names the unique ignored file" ".env" "$(detail_of "$out" "$m")"
    assert "the unique ignored file survives apply" grep -q only-copy "$m/.env"

    assert_eq "an ignored copy of the main checkout's file and node_modules are REMOVE" REMOVE \
        "$(action_of "$out" "$c")"
    assert "that worktree moved to the trash" in_trash "$c"

    assert_eq "a repo inside an ignored dir is KEEP nested-repo" "KEEP nested-repo" "$(action_of "$out" "$b")"
    assert_eq "the table names the nested repo" "vendor/lib" "$(detail_of "$out" "$b")"
    assert "the nested repo's commit survives apply" git -C "$b/vendor/lib" cat-file -e "$nested"

    assert_eq "a linked worktree inside an ignored dir is KEEP nested-repo" "KEEP nested-repo" \
        "$(action_of "$out" "$n")"
    assert "the inner worktree survives apply" is_worktree "$n/.wt/beta"
}

test_ignored_dirs() {
    new_fixture
    local a=$WS_PROJECTS/alpha m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta
    local s=$WS_PROJECTS/alpha-sym sd=$WS_PROJECTS/alpha-symdir hg=$WS_PROJECTS/alpha-hg
    local u=$WS_PROJECTS/alpha-unread nm=$WS_PROJECTS/alpha-nmlink ur=$WS_PROJECTS/alpha-unread-regen out
    printf '.claude/\n.env\nconf/local.env\ntools/\npgdata/\nnode_modules\nnode_modules/\ndist/\n' \
        >>"$a/.git/info/exclude"
    echo .cache/ >>"$WS_PROJECTS/beta/.git/info/exclude"

    mkdir -p "$m/.claude"
    echo '{"permissions":"only-copy"}' >"$m/.claude/settings.local.json"

    mkdir -p "$c/node_modules/pkg" "$c/dist"
    echo regenerable >"$c/node_modules/pkg/index.js"
    echo built >"$c/dist/app.js"

    git init -q --bare "$b/.cache/backup.git"
    git -C "$b" push -q "$b/.cache/backup.git" HEAD:refs/heads/keep

    merged_worktree "$s" feat/sym 60
    echo SECRET=only-copy >"$s/.env"
    ln -s "$s/.env" "$a/.env"

    merged_worktree "$sd" feat/symdir 61
    mkdir -p "$sd/conf"
    echo SECRET=only >"$sd/conf/local.env"
    ln -s "$sd/conf" "$a/conf"

    merged_worktree "$hg" feat/hg 62
    mkdir -p "$hg/tools/x/.hg"
    echo history >"$hg/tools/x/.hg/store"

    merged_worktree "$u" feat/unread 63
    mkdir -p "$u/pgdata/base"
    echo row >"$u/pgdata/base/1"
    chmod 000 "$u/pgdata/base"

    merged_worktree "$ur" feat/unread-regen 66
    mkdir -p "$ur/node_modules/pkg"
    echo hidden >"$ur/node_modules/pkg/f"
    chmod 000 "$ur/node_modules/pkg"

    merged_worktree "$nm" feat/nmlink 64
    mkdir -p "$a/node_modules"
    ln -s "$a/node_modules" "$nm/node_modules"

    out=$(ws prune --apply <<<y 2>/dev/null)
    chmod 755 "$u/pgdata/base" "$ur/node_modules/pkg"
    assert_eq "a unique file in a wholly ignored dir is KEEP ignored-unique" "KEEP ignored-unique" \
        "$(action_of "$out" "$m")"
    assert_eq "the table names that file" ".claude/settings.local.json" "$(detail_of "$out" "$m")"
    assert "that file survives apply" grep -q only-copy "$m/.claude/settings.local.json"

    assert_eq "unique files in regenerable dirs are REMOVE" REMOVE "$(action_of "$out" "$c")"
    assert "that worktree moved to the trash with its build output" test -f "$(trash_of "$c")/dist/app.js"

    assert_eq "a bare repo inside a regenerable dir is KEEP nested-repo" "KEEP nested-repo" "$(action_of "$out" "$b")"
    assert_eq "the table names the bare repo" ".cache/backup.git" "$(detail_of "$out" "$b")"

    assert_eq "a main-checkout symlink into the worktree is not a copy" "KEEP ignored-unique" \
        "$(action_of "$out" "$s")"
    assert "the only real copy survives" grep -q only-copy "$s/.env"
    assert_eq "a main-checkout dir symlink into the worktree is not a copy" "KEEP ignored-unique" \
        "$(action_of "$out" "$sd")"
    assert_eq "the table names the file behind the dir symlink" "conf/local.env" "$(detail_of "$out" "$sd")"

    assert_eq "a .hg repo inside an ignored dir is KEEP nested-repo" "KEEP nested-repo" "$(action_of "$out" "$hg")"
    assert_eq "an unreadable ignored dir is KEEP unreadable" "KEEP unreadable" "$(action_of "$out" "$u")"
    assert "the unreadable dir's file survives" test -f "$u/pgdata/base/1"
    assert_eq "an unreadable dir inside a regenerable dir is KEEP unreadable" "KEEP unreadable" \
        "$(action_of "$out" "$ur")"
    assert_eq "an ignored node_modules symlink is REMOVE" REMOVE "$(action_of "$out" "$nm")"

    new_fixture
    c=$WS_PROJECTS/alpha-closed
    echo node_modules/ >>"$WS_PROJECTS/alpha/.git/info/exclude"
    mkdir -p "$c/node_modules/pkg"
    echo local-patch >"$c/node_modules/pkg/index.js"
    out=$(WS_REGENERABLE="dist" ws prune 2>/dev/null)
    assert_eq "WS_REGENERABLE overrides the table" "KEEP ignored-unique" "$(action_of "$out" "$c")"
}

test_bare_common() {
    new_fixture
    local g=$WS_PROJECTS/gamma.git w=$WS_PROJECTS/gamma-wt out
    git clone -q --bare https://github.com/fixture/alpha.git "$g"
    git -C "$g" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$g" fetch -q origin
    git -C "$g" worktree add -q -b feat/bare "$w" origin/main
    commit_file "$w" b.txt bare
    git -C "$w" push -q -u origin feat/bare
    add_pr alpha feat/bare MERGED 70 "$(head_of "$w")"
    echo .env >>"$g/info/exclude"
    echo SECRET=only-copy >"$w/.env"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "an ignored file in a worktree of a bare repo is KEEP ignored-unique" "KEEP ignored-unique" \
        "$(action_of "$out" "$w")"
    assert "that file survives" test -f "$w/.env"
}

test_records_cannot_be_forged() {
    new_fixture
    local a=$WS_PROJECTS/alpha m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta
    local t=$WS_PROJECTS/alpha-trail out code
    printf '*.env*\n*vendor/\n' >>"$a/.git/info/exclude"
    echo '*]' >>"$WS_PROJECTS/beta/.git/info/exclude"
    printf 'SECRET=only-copy\n' >"$m/"$'\n''prod.env'
    git init -q "$c/"$'\n''vendor'
    git -C "$c/"$'\n''vendor' commit -q --allow-empty -m only-copy
    echo only-copy >"$b/"$'\ndirty\tPWD[$(touch PWNED)]'
    (cd "$FX" && ws prune >/dev/null 2>&1)
    refute "a file name is never evaluated" test -e "$FX/PWNED"

    merged_worktree "$t" feat/trail 65
    printf 'X\n' >"$t/prod.env"$'\n'
    out=$(cd "$FX" && ws prune 2>&1)
    code=$?
    assert_eq "file names with tabs and newlines do not break the dry run" 0 "$code"
    assert_eq "an ignored file name with a newline is KEEP odd-name" "KEEP odd-name" "$(action_of "$out" "$m")"
    assert_eq "an ignored dir name with a newline is KEEP odd-name" "KEEP odd-name" "$(action_of "$out" "$c")"
    assert_eq "a name forging a fact is KEEP odd-name" "KEEP odd-name" "$(action_of "$out" "$b")"
    assert_eq "a name ending in a newline is KEEP odd-name" "KEEP odd-name" "$(action_of "$out" "$t")"

    (cd "$FX" && ws prune --apply <<<y >/dev/null 2>&1)
    refute "apply never evaluates a file name" test -e "$FX/PWNED"
    assert "the newline-named file survives apply" test -f "$m/"$'\n''prod.env'
    assert "the newline-named nested repo survives apply" test -d "$c/"$'\n''vendor/.git'
    assert "the forging file survives apply" test -f "$b/"$'\ndirty\tPWD[$(touch PWNED)]'
    assert "the trailing-newline file survives apply" test -f "$t/prod.env"$'\n'

    local f=$FX/forged verdict
    printf 'path=x\ncommon=x\nmain=x\ngithub=fixture/alpha\nbranch=feat/x\nhead=%s\nlocked=0\nlock-reason=\n' \
        "$(head_of "$WS_PROJECTS/alpha")" >"$f"
    printf 'submodules=0\nhidden-flags=0\ndirty=PWD[$(touch PWNED2)]\nunpushed=0\nin-use=0\ndev=1\n' >>"$f"
    printf 'pr-state=merged\npr-number=1\npr-oid=%s\nhead-in-pr=yes\n' "$(head_of "$WS_PROJECTS/alpha")" >"$f.pr"
    verdict=$(cd "$FX" && bash -c 'source "$1"; prune_classify 0 1 "$2" "$3"' _ "$WS_BIN" "$f" "$f.pr" 2>&1)
    assert_eq "a forged count is KEEP unreadable" $'action=KEEP\treason=unreadable\tdetail=bad dirty fact' "$verdict"
    refute "a forged count is never evaluated" test -e "$FX/PWNED2"
    printf '\n' >>"$f"
    verdict=$(bash -c 'source "$1"; prune_classify 0 1 "$2" "$3"' _ "$WS_BIN" "$f" "$f.pr" 2>&1)
    assert_eq "an empty fact line is KEEP unreadable" $'action=KEEP\treason=unreadable\tdetail=bad fact line' "$verdict"
}

test_pushed() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed
    local s=$WS_PROJECTS/alpha-squash o=$WS_PROJECTS/alpha-moved-on g=$WS_PROJECTS/alpha-closed-gone
    local parked bad out err
    commit_file "$m" parked "parked commit"
    git -C "$m" update-ref refs/worktree/parked HEAD
    parked=$(head_of "$m")
    git -C "$m" reset -q --hard HEAD~1

    commit_file "$c" bad "bisect bad commit"
    git -C "$c" update-ref refs/bisect/bad HEAD
    bad=$(head_of "$c")
    git -C "$c" reset -q --hard HEAD~1

    merged_worktree "$s" feat/squash 20
    merged_worktree "$o" feat/moved-on 21
    add_worktree alpha "$g" feat/closed-gone
    add_pr alpha feat/closed-gone CLOSED 22 "$(head_of "$g")"
    git -C "$WS_PROJECTS/alpha" push -q origin --delete feat/squash feat/moved-on feat/closed-gone
    git -C "$WS_PROJECTS/alpha" fetch -q --prune
    commit_file "$o" later "commit after the merge"

    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a commit held only by refs/worktree is KEEP unpushed" "KEEP unpushed" "$(action_of "$out" "$m")"
    assert_eq "the refs/worktree commit survives apply" "$parked" \
        "$(git -C "$m" rev-parse -q --verify refs/worktree/parked)"
    assert_eq "a commit held only by refs/bisect is KEEP unpushed" "KEEP unpushed" "$(action_of "$out" "$c")"
    assert_eq "the refs/bisect commit survives apply" "$bad" "$(git -C "$c" rev-parse -q --verify refs/bisect/bad)"
    assert_eq "HEAD at the merged PR's head is REMOVE after GitHub deleted the branch" REMOVE \
        "$(action_of "$out" "$s")"
    assert "that worktree moved to the trash" in_trash "$s"
    assert_eq "a commit past the merged PR's head is KEEP unpushed" "KEEP unpushed" "$(action_of "$out" "$o")"
    assert "that worktree survives" is_worktree "$o"
    assert_eq "a closed PR's head does not count as pushed" "KEEP unpushed" "$(action_of "$out" "$g")"
    assert "the closed-PR worktree survives" is_worktree "$g"

    out=$(ws prune --purge --older-than 0d <<<y 2>"$FX/err")
    refute "purge deletes a branch whose tip is the merged PR's head" has_branch alpha feat/squash
    assert_eq "deleting that branch prints nothing on stderr" "" "$(<"$FX/err")"
}

test_branch_deletion() {
    new_fixture
    local merger=$FX/merger r=$WS_PROJECTS/alpha-refused mate=$FX/mate out code tip
    git clone -q https://github.com/fixture/alpha.git "$merger"
    git -C "$merger" merge -q --no-ff -m "Merge pull request #2" origin/feat/merged
    git -C "$merger" push -q origin main
    git -C "$merger" push -q origin --delete feat/merged
    git -C "$WS_PROJECTS/alpha" fetch -q --prune

    add_worktree alpha "$r" feat/refused
    git -C "$r" push -q origin feat/refused:refs/heads/copy
    git clone -q -b feat/refused https://github.com/fixture/alpha.git "$mate"
    commit_file "$mate" mate.txt "teammate commit"
    git -C "$mate" push -q origin feat/refused
    git -C "$WS_PROJECTS/alpha" fetch -q
    tip=$(git -C "$WS_PROJECTS/alpha" rev-parse origin/feat/refused)
    add_pr alpha feat/refused MERGED 30 "$tip"
    git -C "$WS_PROJECTS/alpha" push -q origin --delete feat/refused
    git -C "$WS_PROJECTS/alpha" fetch -q --prune

    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "HEAD behind the merged PR's head is REMOVE" REMOVE "$(action_of "$out" "$r")"
    assert "it moved to the trash" in_trash "$r"

    out=$(ws prune --purge --older-than 0d <<<y 2>"$FX/err")
    code=$?
    assert_eq "kept branches do not change the purge exit code" 0 "$code"
    assert_eq "branch deletion prints nothing on stderr" "" "$(<"$FX/err")"
    refute "a merged branch GitHub deleted is deleted when its tip is the PR head" has_branch alpha feat/merged
    assert "the worktree of a branch git refuses to delete is deleted" test ! -e "$(trash_of "$r")"
    assert "a refused branch whose tip is not the PR head survives" has_branch alpha feat/refused
    assert "the output says why the branch stayed" grep -q "^Kept branch feat/refused: .*not fully merged" <<<"$out"
}

test_pr_matching() {
    new_fixture
    local a=$WS_PROJECTS/alpha x=$WS_PROJECTS/c-alpha-subx y=$WS_PROJECTS/c-sub-x out
    local fn=$WS_PROJECTS/alpha-fnull fm=$WS_PROJECTS/alpha-fmiss mine=$WS_PROJECTS/mine dev=$WS_PROJECTS/dev
    local m=$WS_PROJECTS/alpha-merged
    add_pr alpha feat/nopr MERGED 99 "$(head_of "$WS_PROJECTS/alpha-nopr")" true
    add_worktree alpha "$fn" feat/fnull
    add_pr alpha feat/fnull MERGED 97 "$(head_of "$fn")" null
    add_worktree alpha "$fm" feat/fmiss
    add_pr alpha feat/fmiss MERGED 98 "$(head_of "$fm")" missing

    git -C "$a" worktree add -q -b feat/x "$mine"
    commit_file "$mine" m.txt mine
    git -C "$mine" push -q -u origin feat/x:feat/y
    add_pr alpha feat/y OPEN 50 "$(head_of "$mine")"
    add_pr alpha feat/x MERGED 51 0123456789abcdef0123456789abcdef01234567

    commit_file "$m" b.txt "new work after merge"
    git -C "$m" push -q

    add_worktree alpha "$dev" develop
    add_pr alpha develop MERGED 70 "$(head_of "$dev")"

    git clone -q https://github.com/fixture/beta.git "$a/sub"
    echo sub/ >>"$a/.git/info/exclude"
    add_worktree alpha "$x" sub/x
    add_pr alpha sub/x OPEN 52 "$(head_of "$x")"
    add_worktree alpha/sub "$y" x
    add_pr beta x MERGED 53 "$(head_of "$y")"

    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a fork PR with the same branch name is ignored" "KEEP no-pr" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-nopr")"
    assert "the fork-named branch survives" has_branch alpha feat/nopr
    assert_eq "a PR whose isCrossRepository is null is ignored" "KEEP no-pr" "$(action_of "$out" "$fn")"
    assert_eq "a PR without isCrossRepository is ignored" "KEEP no-pr" "$(action_of "$out" "$fm")"
    assert_eq "a merged PR from the same branch name at another commit is KEEP head-not-in-pr" \
        "KEEP head-not-in-pr" "$(action_of "$out" "$mine")"
    assert "that worktree survives" is_worktree "$mine"
    assert_eq "a pushed commit after the merge is KEEP head-not-in-pr" "KEEP head-not-in-pr" "$(action_of "$out" "$m")"
    assert "the reused worktree survives" is_worktree "$m"
    assert_eq "a long-lived branch at its merged PR's head is REMOVE" REMOVE "$(action_of "$out" "$dev")"
    assert "the long-lived branch stays after the move" has_branch alpha develop
    assert_eq "an open PR in the outer repo keeps its worktree beside a nested repo" "KEEP open" \
        "$(action_of "$out" "$x")"
    assert "the outer repo's open worktree survives" is_worktree "$x"
    assert_eq "the nested repo's merged worktree is REMOVE" REMOVE "$(action_of "$out" "$y")"
}

test_pr_window() {
    new_fixture
    local o=$WS_PROJECTS/alpha-old m=$WS_PROJECTS/alpha-old-merged out n
    add_worktree alpha "$o" feat/old
    add_pr alpha feat/old OPEN 8 "$(head_of "$o")"
    merged_worktree "$m" feat/old-merged 12
    for ((n = 100; n < 1200; n++)); do
        printf 'alpha\tbulk/%s\tMERGED\t%s\t\tfalse\n' "$n" "$n"
    done >>"$FX/prs.tsv"
    add_pr alpha feat/old CLOSED 2000 "$(head_of "$o")"

    out=$(ws prune)
    assert_eq "an open PR older than the newest 1000 still keeps its worktree" "KEEP open" \
        "$(action_of "$out" "$o")"
    assert_eq "the old open PR shows" "#8 open" "$(pr_of "$out" "$o")"
    assert_eq "a merged PR older than the newest 1000 is found by --head" REMOVE "$(action_of "$out" "$m")"
    assert_eq "that branch was confirmed with --head" 1 "$(gh_calls "--head feat/old-merged")"
}

test_origins() {
    new_fixture
    local url out
    for url in git@github.com:fixture/alpha.git git@github.com:fixture/alpha \
        ssh://git@github.com/fixture/alpha.git https://github.com/fixture/alpha/ \
        https://github.com/fixture/alpha git@github.com-work:fixture/alpha.git \
        ssh://git@github.com-work/fixture/alpha; do
        git -C "$WS_PROJECTS/alpha" remote set-url origin "$url"
        out=$(ws prune)
        assert_eq "origin $url reads PRs of fixture/alpha" REMOVE "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    done
}

test_non_github_origin() {
    new_fixture
    local b=$WS_ROOT/t1/beta out code url
    : >"$FX/gh.log"
    git -C "$WS_PROJECTS/beta" remote set-url origin https://gitlab.com/fixture/beta.git
    out=$(ws prune --apply <<<y 2>/dev/null)
    code=$?
    assert_eq "a non-GitHub origin does not fail the run" 0 "$code"
    assert_eq "a non-GitHub origin is KEEP no-github" "KEEP no-github" "$(action_of "$out" "$b")"
    assert "the non-GitHub worktree survives" is_worktree "$b"
    assert_eq "no gh call names the non-GitHub repo" 0 "$(gh_calls "-R github.com/fixture/beta")"
    assert "other repos still apply" in_trash "$WS_PROJECTS/alpha-merged"

    for url in https://github.example.com/fixture/beta.git https://github.company.com/fixture/beta.git \
        git@github.com.example.net:fixture/beta.git; do
        git -C "$WS_PROJECTS/beta" remote set-url origin "$url"
        assert_eq "origin $url is KEEP no-github" "KEEP no-github" "$(action_of "$(ws prune)" "$b")"
    done
    git -C "$WS_PROJECTS/beta" remote remove origin
    out=$(ws prune)
    assert_eq "no origin exits 0" 0 $?
    assert_eq "no origin is KEEP no-github" "KEEP no-github" "$(action_of "$out" "$b")"
}

late_changes() {
    echo late-edit >>"$WS_PROJECTS/alpha-merged/work.txt"
    echo SECRET=late >"$WS_PROJECTS/alpha-closed/.env"
    commit_file "$WS_ROOT/t1/beta" parked.txt "parked at the prompt"
    git -C "$WS_ROOT/t1/beta" update-ref refs/worktree/parked HEAD
    git -C "$WS_ROOT/t1/beta" reset -q --hard HEAD~1
}

late_detached_commit() {
    commit_file "$WS_PROJECTS/alpha-detached" late.txt "commit made at the prompt"
}

test_recheck_before_move() {
    new_fixture
    local code out e=$WS_PROJECTS/alpha-extra
    echo .env >>"$WS_PROJECTS/alpha/.git/info/exclude"
    merged_worktree "$e" feat/extra 90
    answer_yes_at_prompt late_changes prune --apply
    code=$?
    out=$(<"$FX/out")
    assert_eq "skipped worktrees do not change the exit code" 0 "$code"
    assert "a tracked edit made at the prompt survives in place" grep -q late-edit "$WS_PROJECTS/alpha-merged/work.txt"
    assert "an ignored file made at the prompt survives in place" grep -q SECRET=late "$WS_PROJECTS/alpha-closed/.env"
    assert "a refs/worktree ref made at the prompt survives in place" \
        test -n "$(git -C "$WS_ROOT/t1/beta" rev-parse -q --verify refs/worktree/parked)"
    assert "the output names the changed worktree and why" grep -qx "Skipped ~/projects/alpha-merged: KEEP dirty" <<<"$out"
    assert "unchanged worktrees still move" in_trash "$e"

    new_fixture
    answer_yes_at_prompt late_detached_commit prune --apply --include-detached
    assert "a commit made at the prompt on a detached HEAD keeps the worktree in place" \
        is_worktree "$WS_PROJECTS/alpha-detached"
    assert "the output names it" grep -q "Skipped ~/projects/alpha-detached" "$FX/out"
}

test_change_after_recheck() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged code
    cat >"$FX/bin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" worktree move "*alpha-merged* ]]; then
    echo .late >>"$WS_PROJECTS/alpha/.git/info/exclude"
    echo only-copy >"$m/.late"
    echo racing-edit >>"$m/work.txt"
fi
exec $(printf %q "$(command -v git)") "\$@"
EOF
    chmod +x "$FX/bin/git"
    ws prune --apply <<<y >/dev/null 2>"$FX/err"
    code=$?
    rm "$FX/bin/git"
    assert_eq "a change after the recheck does not fail the move" 0 "$code"
    assert "an ignored file written after the recheck survives in the trash" grep -q only-copy "$(trash_of "$m")/.late"
    assert "a tracked edit written after the recheck survives in the trash" grep -q racing-edit "$(trash_of "$m")/work.txt"
}

test_locked_and_submodules() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta out code
    git -C "$WS_PROJECTS/alpha" worktree lock --reason "on removable drive" "$m"
    git -C "$WS_PROJECTS/beta" worktree lock "$b"
    git -C "$c" submodule add -q https://github.com/fixture/beta.git libbeta
    git -C "$c" commit -qm "add submodule"
    git -C "$c" push -q
    add_pr alpha feat/closed CLOSED 23 "$(head_of "$c")"
    out=$(ws prune --apply <<<y 2>"$FX/err")
    code=$?
    assert_eq "locked and submodule worktrees do not fail apply" 0 "$code"
    assert_eq "they print nothing on stderr" "" "$(<"$FX/err")"
    assert_eq "a locked worktree is KEEP locked" "KEEP locked" "$(action_of "$out" "$m")"
    assert_eq "the table shows the lock reason" "on removable drive" "$(detail_of "$out" "$m")"
    assert "the locked worktree survives" is_worktree "$m"
    assert_eq "a worktree locked without a reason is KEEP locked" "KEEP locked" "$(action_of "$out" "$b")"
    assert "that worktree survives" is_worktree "$b"
    assert_eq "a worktree with a submodule is KEEP submodules" "KEEP submodules" "$(action_of "$out" "$c")"
    assert "the submodule worktree survives" is_worktree "$c"
}

test_leaves_other_worktree_entries() {
    new_fixture
    local moved=$WS_PROJECTS/m-moved usb=$FX/usb/offline local_only offline_only
    git -C "$WS_PROJECTS/alpha" worktree add -q --detach "$WS_PROJECTS/m-old"
    commit_file "$WS_PROJECTS/m-old" c "local only commit"
    local_only=$(head_of "$WS_PROJECTS/m-old")
    mv "$WS_PROJECTS/m-old" "$moved"
    git -C "$WS_PROJECTS/alpha" worktree add -q --detach "$usb"
    commit_file "$usb" w "offline only commit"
    offline_only=$(head_of "$usb")
    mv "$FX/usb" "$FX/usb.unmounted"

    ws prune --apply <<<y >/dev/null 2>&1
    mv "$FX/usb.unmounted" "$FX/usb"
    assert_eq "a worktree moved with mv still opens after apply" "$local_only" "$(git -C "$moved" rev-parse HEAD 2>&1)"
    assert_eq "an unmounted worktree still opens after apply" "$offline_only" "$(git -C "$usb" rev-parse HEAD 2>&1)"
}

test_layout() {
    new_fixture
    local sp="$WS_PROJECTS/sp tree [1] * %41" out code
    merged_worktree "$sp" feat/space 80
    mkdir -p "$FX/elsewhere"
    merged_worktree "$FX/elsewhere/real-wt" feat/linked 83
    ln -s "$FX/elsewhere/real-wt" "$WS_PROJECTS/link-wt"
    ln -s "$WS_PROJECTS/alpha-merged" "$WS_PROJECTS/twice-link"
    ln -s "$FX/elsewhere" "$WS_ROOT/t-link"

    out=$(ws prune --apply <<<y 2>"$FX/err")
    code=$?
    assert_eq "apply with spaces and symlinks exits 0" 0 "$code"
    assert_eq "it prints nothing on stderr" "" "$(<"$FX/err")"
    assert_eq "a path with spaces, glob characters, and a percent sign is REMOVE" REMOVE \
        "$(action_of "$out" "$sp")"
    assert "that worktree moved to the trash" in_trash "$sp"
    refute "a symlink to a worktree is not listed" grep -q link-wt <<<"$out"
    assert "the worktree behind the symlink survives" is_worktree "$FX/elsewhere/real-wt"
    refute "a symlink to a listed worktree is not listed again" grep -q twice-link <<<"$out"
    assert_eq "a symlinked ticket dir adds no rows" 10 "$(rows "$out")"
    out=$(ws prune --restore "$(trash_of "$sp")")
    assert "the percent-sign path restores to its exact name" is_worktree "$sp"

    new_fixture
    out=$(WS_ROOT=$FX WS_TRASH=${FX%/*}/trash ws prune)
    assert_eq "a worktree reached through two roots is listed once" 7 "$(rows "$out")"
}

test_restore() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed head out trash
    head=$(head_of "$m")
    ws prune --apply <<<y >/dev/null 2>&1
    trash=$(trash_of "$m")
    out=$(ws prune --restore alpha-merged 2>&1)
    assert_eq "restore by name exits 0" 0 $?
    assert "restore puts the worktree back" is_worktree "$m"
    assert_eq "the restored worktree keeps its HEAD" "$head" "$(head_of "$m")"
    assert "restore empties the trash entry" test ! -e "$trash"
    refute "restore removes the entry's record" test -e "$trash.meta"
    assert "restore says where the worktree went" grep -qx "Restored ~/projects/alpha-merged" <<<"$out"

    trash=$(trash_of "$c")
    ws prune --restore "$trash" >/dev/null
    assert "restore by trash path puts the worktree back" is_worktree "$c"

    out=$(ws prune --restore nothing-like-this 2>&1)
    assert_eq "restore of an unknown name exits 1" 1 $?
    assert "it says nothing matches" grep -q "matches nothing-like-this" <<<"$out"

    ws prune --apply <<<y >/dev/null 2>&1
    trash=$(trash_of "$m")
    mkdir "$m"
    out=$(ws prune --restore alpha-merged 2>&1)
    assert_eq "restore onto an existing path exits 1" 1 $?
    assert "it names the path in the way" grep -q "alpha-merged exists" <<<"$out"
    assert "the trash entry stays" is_worktree "$trash"
    rmdir "$m"
    ln -s /nonexistent "$m"
    ws prune --restore alpha-merged >/dev/null 2>&1
    assert_eq "restore onto a dangling symlink exits 1" 1 $?
    assert "the trash entry stays after that" is_worktree "$trash"
    rm "$m"

    trash=$(trash_of "$WS_ROOT/t1/beta")
    mv "$WS_ROOT/t1" "$FX/t1.saved"
    echo file >"$WS_ROOT/t1"
    ws prune --restore "$trash" >/dev/null 2>&1
    assert_eq "restore into a ticket path that is a file exits 1" 1 $?
    assert "that trash entry stays" is_worktree "$trash"
}

test_ticket_moves_with_last_repo() {
    new_fixture
    local t=$WS_ROOT/t2 t3=$WS_ROOT/t3 out trash
    mkdir -p "$t/.claude" "$t3"
    add_worktree beta "$t/beta" feat/t2
    add_pr beta feat/t2 MERGED 5 "$(head_of "$t/beta")"
    printf 'WS_ID=t2\nWS_STAGE=merged\n' >"$t/.ws"
    echo "# t2" >"$t/CLAUDE.md"
    echo '{}' >"$t/.claude/settings.json"
    add_worktree beta "$t3/beta" feat/t3
    add_pr beta feat/t3 MERGED 6 "$(head_of "$t3/beta")"

    out=$(ws prune --apply <<<y 2>/dev/null)
    trash=$(trash_of "$t/beta")
    assert "the last repo of a ticket moves to the trash" is_worktree "$trash"
    assert "the ticket dir leaves WS_ROOT" test ! -e "$t"
    assert "its .ws moves with it" test -f "${trash%/*}/.ws"
    assert "its CLAUDE.md moves with it" test -f "${trash%/*}/CLAUDE.md"
    assert "the output says the ticket moved" grep -qx "Moved ticket ~/work/t2 with it" <<<"$out"
    assert "a ticket that keeps a repo stays" test -d "$WS_ROOT/t1/alpha"

    out=$(ws prune --restore beta 2>&1)
    assert_eq "a name entries of two tickets share is ambiguous" 1 $?
    assert "the ambiguity lists the trash paths" grep -q "matches more than one trash entry" <<<"$out"

    out=$(ws prune --restore t2 2>&1)
    assert_eq "restore by ticket name exits 0" 0 $?
    assert "restore puts the ticket's repo back" is_worktree "$t/beta"
    assert "restore puts the ticket's .ws back" test -f "$t/.ws"
    assert "restore puts the ticket's .claude back" test -f "$t/.claude/settings.json"
    assert "restore leaves no ticket dir in the trash" test ! -e "${trash%/*}"
}

test_purge() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta out code
    ws prune --apply <<<y >/dev/null 2>&1
    out=$(ws prune --purge <<<y 2>&1)
    assert_eq "purge under the age exits 0" 0 $?
    assert "purge under the age says so" grep -qx "Nothing in the trash is older than 14d." <<<"$out"
    assert "purge under the age keeps every entry" in_trash "$m"
    assert "it keeps the branch" has_branch alpha feat/merged

    ws prune --purge --older-than 0d <<<n >/dev/null 2>&1
    assert "a declined purge keeps every entry" in_trash "$m"

    echo edit-in-trash >>"$(trash_of "$c")/work.txt"
    local trash
    trash=$(trash_of "$m")
    out=$(ws prune --purge --older-than 0d <<<y 2>"$FX/err")
    code=$?
    assert_eq "purge past the age exits 0" 0 "$code"
    assert_eq "purge prints nothing on stderr" "" "$(<"$FX/err")"
    assert "purge asks once" grep -q "Delete 2 worktrees from the trash? \[y/N\]" <<<"$out"
    assert "purge deletes an entry that still classifies REMOVE" test ! -e "$trash"
    refute "purge drops that entry's record" test -e "$trash.meta"
    refute "purge leaves no renamed entry" test -e "$trash.purging"
    refute "purge deletes the merged branch" has_branch alpha feat/merged
    assert_eq "an entry changed in the trash is KEEP with its reason" "KEEP dirty" \
        "$(action_of "$out" "$(trash_of "$c")")"
    assert "that entry stays in the trash" is_worktree "$(trash_of "$c")"
    assert "the edit in the trash survives" grep -q edit-in-trash "$(trash_of "$c")/work.txt"
    refute "purge deletes a merged ticket worktree's branch" has_branch beta feat/ticket
    assert "purge deletes that worktree's trash dir" test ! -e "$(trash_dir)"/*-t1

    out=$(ws prune --purge --older-than 14 2>&1)
    assert_eq "a malformed age exits 1" 1 $?
}

test_purge_ticket() {
    new_fixture
    local t=$WS_ROOT/t2 tdir adir out
    mkdir -p "$t/.claude"
    add_worktree beta "$t/beta" feat/t2
    add_pr beta feat/t2 MERGED 5 "$(head_of "$t/beta")"
    printf 'WS_ID=t2\n' >"$t/.ws"
    echo "# t2" >"$t/CLAUDE.md"
    echo '{}' >"$t/.claude/settings.json"
    ws prune --apply <<<y >/dev/null 2>&1
    tdir=$(trash_of "$t/beta")
    if [[ -z $tdir ]]; then
        not_ok "the ticket's worktree moved to the trash"
        return
    fi
    tdir=${tdir%/*}
    echo keep >"$tdir/notes.md"
    out=$(ws prune --purge --older-than 0d <<<y 2>/dev/null)
    adir=$(trash_dir)/archive/${tdir##*/}
    assert "purge deletes the ticket's worktree" test ! -e "$tdir/beta"
    assert "purge moves the ticket's files to the archive" test -f "$adir/.ws" -a -f "$adir/CLAUDE.md" -a -f "$adir/.claude/settings.json"
    assert "purge moves a file ws did not write to the archive" test -f "$adir/notes.md"
    assert "purge leaves no ticket dir in the trash" test ! -e "$tdir"
    assert "purge says where the ticket's files went" grep -q " ~/.local/share/ws/trash/archive/${tdir##*/}" <<<"$out"
}

test_purge_archives_ticket_files() {
    new_fixture
    local t=$WS_ROOT/t2 t3=$WS_ROOT/t3 shared=$FX/shared-claude sums tdir tdir3 adir out
    mkdir -p "$t/.claude" "$t3" "$shared"
    add_worktree alpha "$t/alpha" feat/t2
    add_pr alpha feat/t2 MERGED 200 "$(head_of "$t/alpha")"
    printf '# t2\n- a note only this file holds\n' >"$t/CLAUDE.md"
    printf 'WS_ID=t2\nWS_STAGE=merged\n' >"$t/.ws"
    echo '{"permissions":{"allow":["Bash(make:*)"]}}' >"$t/.claude/settings.json"
    add_worktree beta "$t3/beta" feat/t3
    add_pr beta feat/t3 MERGED 201 "$(head_of "$t3/beta")"
    echo '{"shared":"by every project"}' >"$shared/settings.json"
    ln -s "$shared" "$t3/.claude"
    sums=$(cd "$t" && sha256sum .ws .claude/settings.json)
    ws prune --apply <<<y >/dev/null 2>&1
    tdir=$(trash_of "$t/alpha")
    tdir=${tdir%/*}
    tdir3=$(trash_of "$t3/beta")
    tdir3=${tdir3%/*}
    echo "- a note added in the trash" >>"$tdir/CLAUDE.md"
    echo "notes written in the trash" >"$tdir/notes.md"

    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    adir=$(trash_dir)/archive/${tdir##*/}
    assert "purge deletes the ticket's worktree" test ! -e "$tdir/alpha"
    assert "the ticket's CLAUDE.md keeps the note made before the move" grep -q "only this file holds" "$adir/CLAUDE.md"
    assert "it keeps the note added in the trash" grep -q "added in the trash" "$adir/CLAUDE.md"
    assert_eq "the ticket's .ws and settings keep their bytes" "$sums" "$(cd "$adir" && sha256sum .ws .claude/settings.json)"
    assert "a file written in the trash goes to the archive" grep -q "written in the trash" "$adir/notes.md"
    assert "a shared .claude behind a symlink keeps its file" grep -q "by every project" "$shared/settings.json"
    assert "the symlink itself goes to the archive" test -L "$(trash_dir)/archive/${tdir3##*/}/.claude"
    refute "nothing is left of either ticket in the trash" test -e "$tdir" -o -e "$tdir3"
}

test_cross_fs() {
    new_fixture
    local out
    if ! unshare -rm true 2>/dev/null; then
        ok "cross-fs skipped: no user namespaces"
        return
    fi
    out=$(WS_TRASH=$FX/otherfs/data/trash ws_on_other_fs prune --apply <<<y 2>/dev/null)
    assert_eq "a trash on another filesystem is KEEP cross-fs" "KEEP cross-fs" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert "that worktree stays" is_worktree "$WS_PROJECTS/alpha-merged"
    refute "no trash is made on the other filesystem" test -s "$FX/otherfs.landed"
}

test_trash_location() {
    new_fixture
    local before dir out code
    before=$(snapshot alpha beta)
    for dir in "$WS_ROOT/.trash" "$WS_ROOT/trash" "$WS_PROJECTS/trash" "$FX" "$FX/odd"$'\n'"trash"; do
        out=$(WS_TRASH=$dir ws prune --apply <<<y 2>&1)
        code=$?
        assert_eq "WS_TRASH at ${dir/#"$FX"/\~} exits 1" 1 "$code"
        assert "it says what is wrong with WS_TRASH" grep -q "^ws: WS_TRASH" <<<"$out"
    done
    WS_TRASH=$WS_ROOT/.trash ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert_eq "purge refuses a trash inside WS_ROOT" 1 $?
    assert_eq "a refused trash moves nothing" "$before" "$(snapshot alpha beta)"
    refute "a refused trash is not made" test -e "$WS_ROOT/.trash"

    mkdir -p "$(trash_dir)"
    chmod 555 "$(trash_dir)"
    ws prune --apply <<<y >/dev/null 2>&1
    chmod 755 "$(trash_dir)"
    assert_eq "a trash it cannot write to moves nothing" "$before" "$(snapshot alpha beta)"

    mkdir "$WS_ROOT/hidden"
    ln -s "$WS_ROOT/hidden" "$FX/alias"
    WS_TRASH=$FX/alias/trash ws prune --apply <<<y >/dev/null 2>&1
    assert_eq "a trash that a symlink puts inside WS_ROOT exits 1" 1 $?
    assert_eq "that trash moves nothing" "$before" "$(snapshot alpha beta)"

    ln -s loop2 "$FX/loop1"
    ln -s loop1 "$FX/loop2"
    out=$(WS_TRASH=$FX/loop1/trash ws prune --apply <<<y 2>&1)
    assert_eq "a trash behind a symlink loop exits 1" 1 $?
    assert "it names the loop" grep -q "^ws: WS_TRASH .* symlink loop" <<<"$out"

    out=$(WS_STAMP=../../projects/x ws prune --apply <<<y 2>&1)
    assert_eq "a WS_STAMP that is not a UTC stamp exits 1" 1 $?
    assert "it says what WS_STAMP must look like" grep -q "^ws: WS_STAMP" <<<"$out"
    WS_STAMP=../../../../projects/x20260101T000000Z ws prune --apply <<<y >/dev/null 2>&1
    assert_eq "a WS_STAMP that holds a UTC stamp inside a path exits 1" 1 $?
    out=$(WS_PROC=$FX/no-such-proc ws prune 2>&1)
    assert_eq "a WS_PROC that is not a directory exits 1" 1 $?
    mkdir "$FX/empty-proc"
    out=$(WS_PROC=$FX/empty-proc ws prune 2>&1)
    assert_eq "a WS_PROC with no self entry exits 1" 1 $?
    assert "it says what WS_PROC lacks" grep -q "^ws: WS_PROC .*self" <<<"$out"
    assert_eq "none of them moves anything" "$before" "$(snapshot alpha beta)"

    ln -s "$FX" "$_sandbox/home-link"
    local -a vars refused=("WS_TRASH=/" "WS_TRASH=//" "WS_TRASH=$HOME WS_ROOT=/srv/r WS_PROJECTS=/srv/p"
        "WS_TRASH=${HOME%/*} WS_ROOT=/srv/r WS_PROJECTS=/srv/p" "WS_ROOT=/" "WS_PROJECTS=/"
        "HOME=$_sandbox/home-link WS_TRASH=$HOME WS_ROOT=/srv/r WS_PROJECTS=/srv/p")
    for dir in "${refused[@]}"; do
        read -r -a vars <<<"$dir"
        env "${vars[@]}" bash -c 'source "$1"; WS_TRASH=$(realpath -m -- "$WS_TRASH"); ws_env_ok' _ "$WS_BIN" \
            >/dev/null 2>&1
        code=$?
        dir=${dir//"$_sandbox\/home-link"/a link to \~}
        dir=${dir//"$HOME"/\~}
        assert_eq "the env check refuses ${dir//"${HOME%/*}"/\~/..}" 1 "$code"
    done

    if ! unshare -rm true 2>/dev/null; then
        ok "symlinked trash skipped: no user namespaces"
        return
    fi
    ln -s "$FX/otherfs/trash" "$FX/trash-link"
    out=$(WS_TRASH=$FX/trash-link ws_on_other_fs prune --apply <<<y 2>/dev/null)
    assert_eq "a trash reached through a symlink to another filesystem is KEEP cross-fs" "KEEP cross-fs" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    refute "nothing lands on the other filesystem" test -s "$FX/otherfs.landed"
    rmdir "$(trash_dir)" "$XDG_DATA_HOME/ws"
    ln -s "$FX/otherfs/data" "$XDG_DATA_HOME/ws"
    out=$(ws_on_other_fs prune --apply <<<y 2>/dev/null)
    assert_eq "a missing trash below a symlink to another filesystem is KEEP cross-fs" "KEEP cross-fs" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert_eq "neither moves anything" "$before" "$(snapshot alpha beta)"
    refute "nothing lands on the other filesystem through that link" test -s "$FX/otherfs.landed"
}

test_symlinked_trash() {
    new_fixture
    local out
    mkdir "$FX/real-trash"
    ln -s "$FX/real-trash" "$FX/trash-link"
    WS_TRASH=$FX/trash-link ws prune --apply <<<y >/dev/null 2>&1
    refute "apply through a symlinked trash on the same filesystem moves the worktree" \
        test -e "$WS_PROJECTS/alpha-merged"
    out=$(WS_TRASH=$FX/trash-link ws prune --purge --older-than 0d <<<y 2>&1)
    refute "purge through that symlink keeps nothing it should delete" grep -q "^Kept" <<<"$out"
    refute "it deletes the entry" compgen -G "$FX/real-trash/*-alpha-merged"
}

test_forged_records() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged t=$WS_ROOT/t9 tr out head
    tr=$(trash_dir)
    head=$(head_of "$m")
    mkdir -p "$t/.claude" "$tr"
    add_worktree beta "$t/beta" feat/t9
    add_pr beta feat/t9 MERGED 90 "$(head_of "$t/beta")"
    echo "# hand-written notes" >"$t/CLAUDE.md"
    echo WS_ID=t9 >"$t/.ws"
    printf 'trash=%s\ttime=1\n' "$m" >"$tr/manifest"
    printf 'trash=%s\tticket=%s\ttime=1\n' "$t/beta" "$t" >>"$tr/manifest"
    printf 'orig=%s\ntrash=%s\ntime=1\n' "$FX/nowhere" "$m" >"$tr/20200101T000000Z-forged.meta"
    ln -s "$m" "$tr/20200101T000000Z-link"
    printf 'orig=%s\ncommon=%s\nbranch=feat/merged\nhead=%s\nticket=\npr=2\nstate=merged\noid=%s\ntime=1\n' \
        "$FX/nowhere" "$WS_PROJECTS/alpha/.git" "$head" "$head" >"$tr/20200101T000000Z-link.meta"

    out=$(ws prune --purge <<<y 2>&1)
    assert "purge never deletes a live worktree a record names" is_worktree "$m"
    assert "purge never touches a live ticket's files" test -f "$t/CLAUDE.md" -a -f "$t/.ws"
    assert "the live ticket's worktree survives" is_worktree "$t/beta"
    assert "purge lists a record with a field it does not know" \
        grep -q "^Kept ~/.local/share/ws/trash/20200101T000000Z-forged: " <<<"$out"
    assert "purge lists an entry that is a symlink" \
        grep -q "^Kept ~/.local/share/ws/trash/20200101T000000Z-link: " <<<"$out"
    ws prune --restore 20200101T000000Z-link >/dev/null 2>&1
    assert_eq "restore of a symlinked entry exits 1" 1 $?
    assert "the worktree behind the symlink stays in place" is_worktree "$m"
}

test_restore_trusts_no_ticket_field() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed out meta beta cmeta
    ws prune --apply <<<y >/dev/null 2>&1
    cmeta=$(meta_of "$c")
    sed -i "s#^orig=.*#orig=projects/alpha-closed#" "$cmeta"
    out=$(cd "$FX" && ws prune --restore "${cmeta%.meta}" 2>&1)
    assert_eq "restore of a record with a relative orig exits 1" 1 $?
    assert "it says the record is bad" grep -q "bad record" <<<"$out"
    assert "that entry stays in the trash" is_worktree "${cmeta%.meta}"
    refute "nothing appears at the relative path" test -e "$FX/projects/alpha-closed"
    mkdir -p "$FX/elsewhere"
    meta=$(meta_of "$m")
    beta=$(trash_of "$WS_ROOT/t1/beta")
    sed -i "s#^ticket=\$#ticket=$FX/elsewhere#" "$meta"
    out=$(ws prune --restore alpha-merged 2>&1)
    assert_eq "restore of a record whose ticket is not its parent exits 1" 1 $?
    assert "it says the record is bad" grep -q "bad record" <<<"$out"
    assert_eq "nothing moves to the dir the field names" "" "$(ls -A "$FX/elsewhere")"
    assert "the entry stays in the trash" is_worktree "${meta%.meta}"
    assert "another ticket's entry stays in the trash" is_worktree "$beta"
}

test_damaged_records() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta out code mm cm line
    ws prune --apply <<<y >/dev/null 2>&1
    mm=$(meta_of "$m")
    cm=$(meta_of "$c")
    printf '\0' >>"$mm"
    line=$(grep '^time=' "$cm")
    echo "$line" >>"$cm"
    out=$(ws prune --restore beta 2>&1)
    assert_eq "restore beside damaged records exits 0" 0 $?
    assert "a damaged record never blocks restoring another entry" is_worktree "$b"

    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    code=$?
    assert_eq "purge beside damaged records exits 0" 0 "$code"
    assert "purge says why it keeps a record with a NUL byte" grep -q "^Kept ~/.*-alpha-merged: bad record" <<<"$out"
    assert "purge says why it keeps a record with a key twice" grep -q "^Kept ~/.*-alpha-closed: bad record" <<<"$out"
    assert "the entry with a NUL byte stays" is_worktree "${mm%.meta}"
    assert "the entry with a key twice stays" is_worktree "${cm%.meta}"
    out=$(ws prune --restore "${cm%.meta}" 2>&1)
    assert_eq "restore of a damaged record exits 1" 1 $?
    assert "it says the record is bad" grep -q "bad record" <<<"$out"
}

test_record_age() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed out mm cm
    ws prune --apply <<<y >/dev/null 2>&1
    mm=$(meta_of "$m")
    cm=$(meta_of "$c")
    truncate -s -3 "$mm"
    sed -i 's/^time=.*/time=17/' "$cm"
    out=$(ws prune --purge <<<n 2>&1)
    refute "the default purge offers nothing minutes after the move" grep -q "Delete" <<<"$out"
    assert "it keeps a record cut inside its last line and says why" grep -q "^Kept ~/.*-alpha-merged: bad record" <<<"$out"
    assert "the cut record's entry stays" is_worktree "${mm%.meta}"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    WS_STAMP=20000101T000000Z ws prune --apply <<<y >/dev/null 2>&1
    out=$(ws prune --purge <<<y 2>&1)
    assert "an entry with an old name and a new record time is not old" \
        grep -q "^Nothing in the trash is older than 14d" <<<"$out"
    assert "that entry stays" is_worktree "$(trash_of "$m")"
}

test_restore_stops_at_a_ticket_file_in_the_way() {
    new_fixture
    local t=$WS_ROOT/t3 r out code
    mkdir -p "$t"
    for r in alpha beta; do
        add_worktree "$r" "$t/$r" feat/t3
        add_pr "$r" feat/t3 MERGED 3 "$(head_of "$t/$r")"
    done
    echo "# old notes" >"$t/CLAUDE.md"
    echo "first notes" >"$t/0-notes.md"
    ws prune --apply <<<y >/dev/null 2>&1
    mkdir -p "$t"
    echo "# new notes" >"$t/CLAUDE.md"
    out=$(ws prune --restore t3 2>&1)
    code=$?
    assert_eq "restore onto a ticket file that exists exits 1" 1 "$code"
    assert "it names the file in the way" grep -q ": ~/work/t3/CLAUDE.md exists" <<<"$out"
    assert "it names the trash copy" grep -q "trash/[^ ]*-t3/CLAUDE.md" <<<"$out"
    assert "the new file stays" grep -q "new notes" "$t/CLAUDE.md"
    assert "the old file stays in the trash" grep -q "old notes" "$(dirname "$(trash_of "$t/alpha")")/CLAUDE.md"
    refute "a restore that stops moves no ticket file" test -e "$t/0-notes.md"
    assert "the first worktree stays in the trash" in_trash "$t/alpha"
    assert "the second worktree stays in the trash" in_trash "$t/beta"
}

test_restore_checks_git_first() {
    new_fixture
    local t=$WS_ROOT/t5 tdir out
    mkdir -p "$t"
    add_worktree alpha "$t/alpha" feat/t5
    add_pr alpha feat/t5 MERGED 307 "$(head_of "$t/alpha")"
    echo notes >"$t/CLAUDE.md"
    ws prune --apply <<<y >/dev/null 2>&1
    tdir=$(trash_of "$t/alpha")
    tdir=${tdir%/*}
    mv "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-renamed"
    out=$(ws prune --restore t5 2>&1)
    assert_eq "restore of a worktree whose main repo moved exits 1" 1 $?
    assert "the ticket's files stay with the entry" test -f "$tdir/CLAUDE.md"
    refute "no half-restored ticket dir appears" test -e "$t"
}

test_concurrent_restore_and_apply() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed pid code
    ws prune --apply <<<y >/dev/null 2>&1
    ws prune --restore alpha-merged >/dev/null 2>&1
    ws prune --restore alpha-closed >/dev/null 2>&1
    mkdir -p "$FX/slow"
    printf '#!/usr/bin/env bash\nsleep 2\nexec %q "$@"\n' "$(command -v mv)" >"$FX/slow/mv"
    chmod +x "$FX/slow/mv"
    PATH=$FX/slow:$PATH ws prune --restore beta >/dev/null 2>&1 &
    pid=$!
    sleep 1
    ws prune --apply <<<y >/dev/null 2>&1
    wait "$pid"
    code=$?
    assert_eq "the restore exits 0" 0 "$code"
    assert "an apply during a restore keeps its first record" in_trash "$m"
    assert "it keeps its second record" in_trash "$c"
}

two_worktree_ticket() {
    mkdir -p "$1" || abort "cannot make $1"
    add_worktree alpha "$1/alpha" feat/t8a
    add_pr alpha feat/t8a MERGED 700 "$(head_of "$1/alpha")"
    add_worktree beta "$1/beta" feat/t8b
    add_pr beta feat/t8b MERGED 701 "$(head_of "$1/beta")"
    echo notes >"$1/CLAUDE.md" || abort "cannot write $1/CLAUDE.md"
    ws prune --apply <<<y >/dev/null 2>&1
}

test_restore_one_of_two() {
    new_fixture
    local t=$WS_ROOT/t8 tdir
    two_worktree_ticket "$t"
    tdir=$(trash_of "$t/alpha")
    tdir=${tdir%/*}
    ws prune --restore "$tdir/alpha" >/dev/null 2>&1
    assert "restore by trash path puts that worktree back" is_worktree "$t/alpha"
    assert "the ticket's files come back with it" test -f "$t/CLAUDE.md"
    assert "the other worktree stays in the trash" is_worktree "$tdir/beta"
    assert "its record stays" test -f "$tdir/beta.meta"
    refute "git lists nothing as prunable" grep -q '^prunable' <<<"$(snapshot alpha beta)"
    ws prune --restore "$tdir/beta" >/dev/null 2>&1
    assert "the other worktree restores after it" is_worktree "$t/beta"
}

test_purge_one_of_two() {
    new_fixture
    local t=$WS_ROOT/t8 tdir
    two_worktree_ticket "$t"
    tdir=$(trash_of "$t/alpha")
    tdir=${tdir%/*}
    echo dirty >"$tdir/beta/untracked.txt"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert "purge deletes the clean worktree" test ! -e "$tdir/alpha"
    assert "the ticket's files stay with the worktree left in the trash" test -f "$tdir/CLAUDE.md"
    rm "$tdir/beta/untracked.txt"
    ws prune --restore t8 >/dev/null 2>&1
    assert "restore brings the ticket's files back" test -f "$t/CLAUDE.md"
    assert "restore brings the worktree back" is_worktree "$t/beta"
}

test_trash_names() {
    new_fixture
    local stamp=20260101T000000Z tr out
    tr=$(trash_dir)
    mkdir -p "$WS_ROOT/alpha-merged" "$tr"
    add_worktree beta "$WS_ROOT/alpha-merged/beta" feat/d
    add_pr beta feat/d MERGED 304 "$(head_of "$WS_ROOT/alpha-merged/beta")"
    echo "ticket notes" >"$WS_ROOT/alpha-merged/notes.md"
    echo pending >"$tr/$stamp-alpha-closed.meta.tmp"
    mkdir "$tr/$stamp-t1.purging"
    out=$(WS_STAMP=$stamp ws prune --apply <<<y 2>&1)
    assert_eq "apply skips a name a pending record holds" "$tr/$stamp.2-alpha-closed" \
        "$(trash_of "$WS_PROJECTS/alpha-closed")"
    assert "the pending record stays as it was" grep -qx pending "$tr/$stamp-alpha-closed.meta.tmp"
    assert_eq "apply skips a name a purge holds" "$tr/$stamp.2-t1/beta" "$(trash_of "$WS_ROOT/t1/beta")"
    assert_eq "a worktree named like a ticket gets the plain name" "$tr/$stamp-alpha-merged" \
        "$(trash_of "$WS_PROJECTS/alpha-merged")"
    assert_eq "the ticket gets its own trash dir" "$tr/$stamp.2-alpha-merged/beta" \
        "$(trash_of "$WS_ROOT/alpha-merged/beta")"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "purge deletes the worktree" test ! -e "$tr/$stamp-alpha-merged"
    assert "purge deletes the ticket's worktree" test ! -e "$tr/$stamp.2-alpha-merged/beta"
    assert "the ticket's notes go to the archive" test -f "$tr/archive/$stamp.2-alpha-merged/notes.md"
}

late_trash_files() {
    echo .late >>"$WS_PROJECTS/alpha/.git/info/exclude"
    echo only-copy >"$merged/.late"
    echo draft >"$closed/draft.md"
    git -C "$beta" reset -q --hard HEAD~1
}

test_purge_rechecks_after_the_prompt() {
    new_fixture
    local merged closed beta detached
    ws prune --apply --include-detached <<<y >/dev/null 2>&1
    merged=$(trash_of "$WS_PROJECTS/alpha-merged")
    closed=$(trash_of "$WS_PROJECTS/alpha-closed")
    beta=$(trash_of "$WS_ROOT/t1/beta")
    detached=$(trash_of "$WS_PROJECTS/alpha-detached")
    answer_yes_at_prompt late_trash_files prune --purge --older-than 0d
    assert "an ignored file made at the purge prompt survives" grep -q only-copy "$merged/.late"
    assert "an untracked file made at the purge prompt survives" grep -q draft "$closed/draft.md"
    assert "the entry keeps its name" is_worktree "$merged"
    assert "the output says why" grep -q "^Kept ~/.*-alpha-merged: KEEP ignored-unique" "$FX/out"
    assert "an entry whose HEAD moved at the prompt stays, though it still classifies REMOVE" is_worktree "$beta"
    assert "the output says it changed" grep -q "^Kept ~/.*-t1/beta: it changed after the scan" "$FX/out"
    assert "the untouched entry is deleted" test ! -e "$detached"
}

test_purge_moves_the_entry_before_it_deletes() {
    new_fixture
    local entry
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(compgen -G "$(trash_dir)/*-alpha-merged")
    echo .late >>"$WS_PROJECTS/alpha/.git/info/exclude"
    fake_git "if [[ \" \$* \" == *' worktree remove '* && \${*: -1} == $(printf %q "$entry")* ]] &&
    echo only-copy 2>/dev/null >$(printf %q "$entry/.late"); then
    : >$(printf %q "$FX/late.wrote")
fi"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    assert "a file written to the entry's path while purge deletes that entry is never lost" \
        test ! -e "$FX/late.wrote" -o -f "$entry/.late"
}

test_purge_ignores_status_config() {
    new_fixture
    local entry
    git -C "$WS_PROJECTS/alpha" config status.showUntrackedFiles no
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$WS_PROJECTS/alpha-merged")
    fake_git "if [[ \" \$* \" == *' worktree remove '* && \${*: -1} == $(printf %q "$entry.purging") ]]; then
    echo draft >$(printf %q "$entry.purging/draft.md")
fi"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    assert "an untracked file made just before removal survives status.showUntrackedFiles=no" \
        test -f "$entry/draft.md"
}

test_purge_never_nests_the_entry() {
    new_fixture
    local entry out cmd
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$WS_PROJECTS/alpha-merged")
    fake_git "if [[ \" \$* \" == *' worktree remove '* && \${*: -1} == $(printf %q "$entry.purging") ]]; then
    mkdir -p $(printf %q "$entry/logs")
    echo wip >$(printf %q "$entry.purging/wip.txt")
fi"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    rm "$FX/bin/git"
    assert "an entry whose name was taken during purge stays a worktree under its .purging name" \
        is_worktree "$entry.purging"
    refute "it never moves inside the dir that took its name" test -e "$entry/${entry##*/}.purging"
    cmd=$(grep -A1 "^Orphan ~/.*-alpha-merged.purging" <<<"$out" | sed -n 2p)
    bash -c "$cmd" >/dev/null 2>&1
    assert "the printed command moves it out of the trash while that dir is taken" \
        is_worktree "$WS_PROJECTS/alpha-merged"
    assert "the untracked file is still there" test -f "$WS_PROJECTS/alpha-merged/wip.txt"
}

test_purge_saves_reflog_commits() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged lost entry bundle out
    commit_file "$m" draft.txt "draft only the reflog holds"
    lost=$(head_of "$m")
    git -C "$m" reset -q --hard HEAD~1
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    bundle=$(trash_dir)/archive/${entry##*/}.bundle
    assert "purge deletes the worktree" test ! -e "$entry"
    assert "the bundle is valid for the repo" git -C "$WS_PROJECTS/alpha" bundle verify -q "$bundle"
    assert "the bundle holds the commit only the reflog had" \
        grep -q "^$lost " <<<"$(git -C "$WS_PROJECTS/alpha" bundle list-heads "$bundle" 2>/dev/null)"
    assert "the output names the bundle" grep -q "archive/${entry##*/}.bundle" <<<"$out"
    refute "an entry with no reflog-only commit gets no bundle" compgen -G "$(trash_dir)/archive/*-alpha-closed*"
}

lost_commit() {
    { commit_file "$1" "$2.txt" "$2" && head_of "$1" && git -C "$1" reset -q --hard HEAD~1; } ||
        abort "cannot make a commit only the reflog holds"
}

reachable() {
    local oid=$1 repo bundle
    shift
    for repo in "$WS_PROJECTS"/*/.git "$@"; do
        if [[ -d $repo ]] && git --git-dir="$repo" rev-list --all --reflog 2>/dev/null | grep -x "$oid" >/dev/null; then
            return 0
        fi
    done
    while IFS= read -r -d '' bundle; do
        if git bundle list-heads "$bundle" 2>/dev/null | grep "^$oid " >/dev/null; then
            return 0
        fi
    done < <(find "$(trash_dir)/archive" -name '*.bundle' -type f -print0 2>/dev/null)
    return 1
}

head_only_commit() {
    local branch
    branch=$(git -C "$1" symbolic-ref -q --short HEAD) || abort "cannot read the branch of $1"
    git -C "$1" checkout -q --detach || abort "cannot detach $1"
    commit_file "$1" "$2.txt" "$2"
    head_of "$1"
    git -C "$1" checkout -q "$branch" || abort "cannot check out $branch in $1"
}

test_purge_keeps_entries_it_cannot_bundle() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged lost entry out
    lost=$(lost_commit "$m" draft)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    mkdir -p "$(trash_dir)/archive"
    chmod 555 "$(trash_dir)/archive"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    chmod 755 "$(trash_dir)/archive"
    assert "an entry whose bundle cannot be written stays" is_worktree "$entry"
    assert "the output says why" \
        grep -q "^Kept ~/.*-alpha-merged: the commits only its reflogs hold could not be saved" <<<"$out"
    assert "its reflog commit stays reachable" reachable "$lost"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    lost=$(lost_commit "$m" draft)
    ws prune --apply <<<y >/dev/null 2>&1
    printf '#!/usr/bin/env bash\n[[ $1 == -u && -f ${2-} ]] && exit 2\nexec %q "$@"\n' \
        "$(PATH=$_base_path command -v sort)" >"$FX/bin/sort"
    chmod +x "$FX/bin/sort"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/sort"
    assert "a failing sort never loses a commit only the reflog holds" reachable "$lost"

    new_fixture
    local base log i
    m=$WS_PROJECTS/alpha-merged
    base=$(head_of "$m")
    {
        for ((i = 1; i <= 8000; i++)); do
            printf 'commit refs/heads/huge\nmark :%d\ncommitter x <x@example.invalid> %d +0000\ndata 2\nc\n' \
                "$i" $((1700000000 + i))
            ((i > 1)) || printf 'from %s\n' "$base"
            echo
        done
    } | git -C "$m" fast-import --quiet --export-marks="$FX/marks" || abort "fast-import failed"
    git -C "$m" update-ref -d refs/heads/huge
    log=$WS_PROJECTS/alpha/.git/worktrees/alpha-merged/logs/HEAD
    awk -v base="$base" '{ printf "%s %s x <x@example.invalid> 1700000000 +0000\tcommit: c\n", base, $2 }' \
        "$FX/marks" >>"$log"
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    out=$( (ulimit -s 1024 && ws prune --purge --older-than 0d <<<y 2>&1) )
    assert "a reflog longer than the argument limit still gets its bundle" \
        grep -q "^Saved 8000 commit(s) that only its reflogs held" <<<"$out"
    assert "that entry is deleted" test ! -e "$entry"
    assert "the bundle holds the newest of those commits" reachable "$(sed -n 's/^:8000 //p' "$FX/marks")"
}

test_orphans() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out cmd entry
    fake_git 'if [[ $2 == worktree && $3 == move && $4 == */alpha-merged ]]; then "$real" "$@"; kill -KILL "$PPID"; exit; fi'
    ws prune --apply <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    entry=$(compgen -G "$(trash_dir)/*-alpha-merged")
    out=$(ws prune --restore alpha-merged 2>&1)
    assert "restore lists a worktree moved without its record as an orphan" grep -q "^Orphan ~/.*-alpha-merged" <<<"$out"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "purge lists it too" grep -q "^Orphan ~/.*-alpha-merged" <<<"$out"
    assert "purge never deletes it" is_worktree "$entry"
    cmd=$(grep -A1 "^Orphan ~/.*-alpha-merged" <<<"$out" | sed -n 2p)
    bash -c "$cmd" >/dev/null 2>&1
    assert "the listed command puts it back" is_worktree "$m"
    assert "the notes settle" follow_notes
    refute "following them leaves no unfinished record behind" compgen -G "$(trash_dir)/*.meta.tmp"
    out=$(ws prune --restore nothing-like-this 2>&1)
    refute "restore then lists nothing for that worktree" grep -q alpha-merged <<<"$out"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    fake_git "if [[ \$2 == worktree && \$3 == move && \$4 == */alpha-merged && ! -e $(printf %q "$FX/fired") ]]; then
    : >$(printf %q "$FX/fired")
    mkdir -p \"\$5\"
fi"
    out=$(ws prune --apply <<<y 2>&1)
    rm "$FX/bin/git"
    assert "apply moves a worktree back when git moved it into a dir another process made" is_worktree "$m"
    assert "apply says which path another process made" grep -q "^ws: ~/.*-alpha-merged appeared while ws moved" <<<"$out"
    refute "that worktree leaves no record in the trash" compgen -G "$(trash_dir)/*-alpha-merged.meta*"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    fake_git 'if [[ $2 == worktree && $3 == move && $5 == *-alpha-merged.purging ]]; then "$real" "$@"; kill -KILL "$PPID"; exit; fi'
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    out=$(ws prune --purge --older-than 0d <<<n 2>&1)
    assert "purge lists an entry a dead purge renamed" grep -q "^Orphan ~/.*-alpha-merged.purging" <<<"$out"
    cmd=$(grep -A1 "^Orphan ~/.*-alpha-merged.purging" <<<"$out" | sed -n 2p)
    bash -c "$cmd" >/dev/null 2>&1
    assert "the listed command moves the entry out of the trash" is_worktree "$m"
    assert "the notes settle" follow_notes
    assert "following them leaves nothing of it in the trash" nothing_in_trash alpha-merged
}

test_full_trash() {
    new_fixture
    if ! unshare -rm true 2>/dev/null; then
        ok "full trash skipped: no user namespaces"
        return
    fi
    local out
    mkdir "$FX/small"
    cat >"$FX/inner.sh" <<'EOF'
set -u
mount -t tmpfs -o size=1m tmpfs "$SM" || exit 9
export WS_ROOT=$SM/work WS_TRASH=$SM/trash
mkdir -p "$WS_ROOT/t9" "$WS_TRASH"
wt=$WS_ROOT/t9/alpha
git -C "$WS_PROJECTS/alpha" worktree add -q -b feat/small "$wt"
echo s >"$wt/s.txt"
git -C "$wt" add s.txt
git -C "$wt" commit -qm small
git -C "$wt" push -q -u origin feat/small
printf 'alpha\tfeat/small\tMERGED\t300\t%s\tfalse\n' "$(git -C "$wt" rev-parse HEAD)" >>"$FX/prs.tsv"
echo note >"$WS_ROOT/t9/CLAUDE.md"
bash "$WS_BIN" prune 2>&1 | grep -q "^REMOVE .*/t9/alpha" && echo planned
dd if=/dev/zero of="$SM/fill" bs=4k 2>/dev/null
bash "$WS_BIN" prune --apply <<<y >/dev/null 2>&1
rm "$SM/fill"
if [[ -f $wt/s.txt ]]; then
    echo stayed
elif bash "$WS_BIN" prune --restore t9 >/dev/null 2>&1 && [[ -f $wt/s.txt ]]; then
    echo restored
fi
umount "$SM"
EOF
    WS_ROOT=$FX/small/work WS_TRASH=$FX/small/trash ws_guard
    out=$(env SM="$FX/small" FX="$FX" WS_BIN="$WS_BIN" unshare -rm bash "$FX/inner.sh" 2>&1)
    assert "the worktree on the small filesystem is REMOVE before it fills" grep -qx planned <<<"$out"
    assert "a trash with no free space never strands a worktree" grep -qxE "stayed|restored" <<<"$out"
}

test_hidden_cwd() {
    new_fixture
    local entry out pid
    if command -v python3 >/dev/null; then
        python3 -I -c 'import ctypes, sys, time
ctypes.CDLL(None).prctl(4, 0, 0, 0, 0)
open(sys.argv[1], "w").write("ready")
time.sleep(30)' "$FX/hidden.ready" &
        pid=$!
        wait_for "$FX/hidden.ready" ready
        out=$(ws prune 2>/dev/null)
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        assert_eq "a real process that hides its directory does not reach a fake process tree" REMOVE \
            "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    fi

    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$WS_PROJECTS/alpha-merged")
    fake_proc 200 1
    fake_proc 201 200
    out=$(ws prune --purge --older-than 0d <<<n 2>/dev/null)
    assert_eq "a hidden process whose parent init adopted is skipped, as daemons are" REMOVE \
        "$(action_of "$out" "$entry")"

    fake_proc 240 1 "$FX"
    fake_proc 250 240
    fake_proc 300 250
    out=$(ws prune --purge --older-than 0d <<<y 2>/dev/null)
    assert_eq "an entry is KEEP unreadable while a process of ours hides its working directory" "KEEP unreadable" \
        "$(action_of "$out" "$entry")"
    assert_eq "the table names that process" "process 300 (fake300) hides its working directory" \
        "$(detail_of "$out" "$entry")"
    assert "purge keeps the entry" is_worktree "$entry"
}

test_purge_keeps_entries_git_cannot_open() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged b=$WS_ROOT/t1/beta mt bt out
    ws prune --apply <<<y >/dev/null 2>&1
    mt=$(trash_of "$m")
    bt=$(trash_of "$b")
    rm -rf "$WS_PROJECTS/alpha"
    git init -q "$FX"
    mv "$bt" "$FX/away"
    git -C "$WS_PROJECTS/beta" worktree prune
    mv "$FX/away" "$bt"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert_eq "purge with entries git cannot open exits 0" 0 $?
    assert "an entry whose main repo is gone keeps its files" test -f "$mt/work.txt"
    assert "an entry git forgot keeps its files" test -f "$bt/work.txt"
    assert "purge says why it keeps the first" grep -q "^Kept ~/.*-alpha-merged: " <<<"$out"
    assert "purge says why it keeps the second" grep -q "^Kept ~/.*-t1/beta: " <<<"$out"
}

test_in_use() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta out
    mkdir -p "$m/sub" "$c/a/b/c"
    printf 'sub/\na/\n' >>"$WS_PROJECTS/alpha/.git/info/exclude"
    ln -s "$c" "$FX/container-view"
    fake_proc 100 1 "$m/sub"
    fake_proc 101 1 "$FX/container-view/a/b/c" "mnt:[2]"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a worktree a process works in is KEEP in-use" "KEEP in-use" "$(action_of "$out" "$m")"
    assert "that worktree stays in place" is_worktree "$m"
    assert_eq "a worktree that a process in another mount namespace works in three levels down is KEEP in-use" \
        "KEEP in-use" "$(action_of "$out" "$c")"
    assert "that worktree stays in place too" is_worktree "$c"
    assert_eq "a worktree no process works in is REMOVE" REMOVE "$(action_of "$out" "$b")"
}

test_sourceable() {
    new_fixture
    local out code
    out=$(bash -c 'source "$1"; echo reached-after-source' _ "$WS_BIN" 2>&1)
    assert_eq "sourcing ws runs no command" reached-after-source "$out"

    echo beta >"$FX/gh.fail"
    out=$(bash -c 'source "$1"; printf "common=%s\tbranch=feat/merged\ncommon=%s\tbranch=feat/ticket\n" "$2" "$3" |
        ws_pr_states' _ "$WS_BIN" "$WS_PROJECTS/alpha/.git" "$WS_PROJECTS/beta/.git" 2>/dev/null)
    code=$?
    assert_eq "ws_pr_states returns 2 when one repo fails" 2 "$code"
    assert "it still reports the repo that answered" grep -q "status=ok" <<<"$(grep "alpha/.git" <<<"$out")"
    assert "it marks the repo that failed" grep -q "status=failed" <<<"$(grep -E "^repo.*beta/.git" <<<"$out")"
    assert "the answered repo keeps its PR facts" grep -Eq "branch=feat/merged.*state=merged.*number=2" <<<"$out"
    rm "$FX/gh.fail"

    : >"$FX/gh.log"
    out=$(bash -c 'source "$1"; printf "common=%s\tbranch=feat/merged\n" "$2" | ws_pr_states --head' \
        _ "$WS_BIN" "$WS_PROJECTS/alpha/.git")
    assert "--head reads the branch's PR" grep -Eq "branch=feat/merged.*state=merged" <<<"$out"
    assert_eq "--head makes one --head call and no list call" "1 0" \
        "$(gh_calls --head) $(gh_calls '!--head')"

    git -C "$WS_PROJECTS/beta" remote set-url origin https://gitlab.com/fixture/beta.git
    out=$(bash -c 'source "$1"; ws_engine_mounts; ws_wt_facts "$2" >"$3"; ws_wt_unsafe "$3"' _ "$WS_BIN" \
        "$WS_ROOT/t1/beta" "$FX/facts")
    assert_eq "ws_wt_unsafe finds a clean pushed worktree safe without PR or GitHub gates" "" "$out"
    out=$(bash -c 'source "$1"; ws_wt_facts "$2" >"$3"; ws_wt_unsafe "$3"' _ "$WS_BIN" \
        "$WS_ROOT/t1/beta" "$FX/facts")
    assert "ws_wt_facts before the engines were asked is unreadable" grep -q "^reason=unreadable" <<<"$out"
    echo edit >>"$WS_ROOT/t1/beta/work.txt"
    out=$(bash -c 'source "$1"; ws_engine_mounts; ws_wt_facts "$2" >"$3"; ws_wt_unsafe "$3"' _ "$WS_BIN" \
        "$WS_ROOT/t1/beta" "$FX/facts")
    assert_eq "ws_wt_unsafe names the first unsafe reason" $'reason=dirty\tdetail=' "$out"

    git -C "$WS_ROOT/t1/beta" checkout -q -- work.txt
    ws_guard
    out=$(bash -c 'source "$1"; ws_engine_mounts; ws_wt_facts "$2" >"$3"; ws_trash_move "$2" "$3"' _ "$WS_BIN" \
        "$WS_ROOT/t1/beta" "$FX/facts")
    assert "ws_trash_move moves a worktree whose facts still match" in_trash "$WS_ROOT/t1/beta"
}

test_fixture_isolation() {
    new_fixture
    assert "XDG_CONFIG_HOME is under the fixture" test "${XDG_CONFIG_HOME#"$FX"/}" != "$XDG_CONFIG_HOME"
    assert "XDG_DATA_HOME is under the fixture" test "${XDG_DATA_HOME#"$FX"/}" != "$XDG_DATA_HOME"
    assert "XDG_STATE_HOME is under the fixture" test "${XDG_STATE_HOME#"$FX"/}" != "$XDG_STATE_HOME"
    assert "TMUX is unset" test -z "${TMUX+set}${TMUX_PANE+set}"
    assert "the tmux socket dir has a short path" test "${#TMUX_TMPDIR}" -le 20

    local shim out code
    shim=$(mktemp -d)
    _sandboxes+=("$shim")
    printf '#!/usr/bin/env bash\n[[ " $* " != *ws-test.* ]] || exit 1\nexec /usr/bin/mktemp "$@"\n' >"$shim/mktemp"
    chmod +x "$shim/mktemp"
    out=$(PATH=$shim:$PATH bash -c 'source "$1"; new_fixture; echo ran-on; ws prune' _ "$WS_TESTS/lib.sh" 2>&1)
    code=$?
    assert_eq "a failed fixture aborts the suite" 2 "$code"
    refute "nothing runs after a failed fixture" grep -q ran-on <<<"$out"

    out=$(bash -c 'source "$1"; new_fixture; x=$(add_worktree alpha "$FX/projects/alpha/.git/HEAD/x" feat/x)
        echo ran-on' _ "$WS_TESTS/lib.sh" 2>&1)
    code=$?
    assert_eq "a fixture step that fails in a subshell aborts the suite" 2 "$code"
    refute "nothing runs after that step" grep -q ran-on <<<"$out"

    local var
    for var in HOME WS_ROOT WS_PROJECTS WS_TRASH gh docker podman; do
        out=$(bash -c 'source "$1"; new_fixture
            if [[ $2 == [a-z]* ]]; then mkdir "$FX/bin2" && ln -s "$(type -P git)" "$FX/bin2/$2" && PATH=$FX/bin2:$PATH
            else export "$2=/var/empty/ws"; fi
            ws prune; echo ran-on' _ "$WS_TESTS/lib.sh" "$var" 2>&1)
        code=$?
        assert_eq "ws refuses to run when $var lies outside the sandbox" 2 "$code"
        refute "nothing runs after that refusal" grep -q ran-on <<<"$out"
    done

    local made
    cat >"$shim/mktemp" <<EOF
#!/usr/bin/env bash
out=\$(/usr/bin/mktemp "\$@") || exit
[[ \$out != /tmp/wsx.* ]] || echo "\$out" >$(printf %q "$shim/made")
echo "\$out"
EOF
    printf '#!/usr/bin/env bash\nexit 1\n' >"$shim/git"
    chmod +x "$shim/git"
    PATH=$shim:$PATH bash "$WS_TESTS/fixture.sh" "$shim/root" >/dev/null 2>&1
    made=$(cat "$shim/made" 2>/dev/null)
    [[ -z $made ]] || _sandboxes+=("$made")
    assert "fixture.sh makes its tmux dir before git runs" test -n "$made"
    refute "a fixture.sh that fails removes its tmux dir" test -e "${made:-/nonexistent}"
}

test_killed_run_leaves_no_temp_dir() {
    local made tmux_dir dir left=0 pid i
    new_fixture
    mkdir -p "$FX/mktemp-bin"
    printf '#!/usr/bin/env bash\nout=$(%q "$@") || exit\necho "$out" >>%q\necho "$out"\n' \
        "$(PATH=$_base_path type -P mktemp)" "$FX/made" >"$FX/mktemp-bin/mktemp"
    chmod +x "$FX/mktemp-bin/mktemp"
    echo 30 >"$FX/gh.slow"
    ws_guard
    PATH=$FX/mktemp-bin:$PATH setsid bash "$WS_BIN" prune >/dev/null 2>&1 &
    pid=$!
    for ((i = 0; i < 200; i++)); do
        grep -q '^start' "$FX/gh.times" 2>/dev/null && break
        sleep 0.05
    done
    kill -TERM -- "-$pid"
    wait "$pid"
    made=$(cat "$FX/made" 2>/dev/null)
    assert "the killed run made a temp dir" test -n "$made"
    tmux_dir=$TMUX_TMPDIR
    drop_fixtures
    for dir in $made "$tmux_dir"; do
        if [[ -e $dir ]]; then
            left=1
            printf '      left: %s\n' "$dir"
        fi
    done
    assert_eq "dropping the fixture removes the temp dirs of a killed ws run and the tmux dir" 0 "$left"
}

test_unknown_command() {
    new_fixture
    local err
    err=$(ws bogus 2>&1)
    assert_eq "unknown command exits 1" 1 $?
    assert "usage lists prune" grep -q "prune" <<<"$err"
    err=$(ws prune --apply --purge 2>&1)
    assert_eq "conflicting modes exit 1" 1 $?
}

test_regenerable_only_at_the_top() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out mark
    printf '.claude/\nnode_modules/\n' >>"$WS_PROJECTS/alpha/.git/info/exclude"
    mkdir -p "$m/.claude/build"
    echo only-copy >"$m/.claude/build/settings.local.json"
    out=$(ws prune 2>/dev/null)
    assert_eq "a unique file under a regenerable name inside an ignored dir is KEEP ignored-unique" \
        "KEEP ignored-unique" "$(action_of "$out" "$m")"
    assert_eq "the table names that file" ".claude/build/settings.local.json" "$(detail_of "$out" "$m")"
    rm -r "$m/.claude"
    for mark in .svn .bzr _darcs .sl .pijul .fslckout _FOSSIL_; do
        mkdir -p "$m/node_modules/pkg"
        case $mark in
        .fslckout | _FOSSIL_) echo checkout >"$m/node_modules/pkg/$mark" ;;
        *) mkdir "$m/node_modules/pkg/$mark" ;;
        esac
        out=$(ws prune 2>/dev/null)
        assert_eq "a $mark checkout inside node_modules is KEEP nested-repo" "KEEP nested-repo" \
            "$(action_of "$out" "$m")"
        rm -r "$m/node_modules"
    done
}

test_odd_worktree_path() {
    new_fixture
    local cr=$WS_PROJECTS/cr$'\r'x out
    merged_worktree "$cr" feat/cr 90
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert "a worktree path with a carriage return is KEEP odd-name" grep -aq "^KEEP odd-name .*feat/cr" <<<"$out"
    assert "that worktree stays in place" is_worktree "$cr"
}

test_trash_leftovers_are_listed() {
    new_fixture
    local t=$WS_ROOT/t3 stamp=20260101T000000Z m=$WS_PROJECTS/alpha-merged entry out cmd
    mkdir -p "$t"
    merged_worktree "$t/alpha" feat/t3 30
    echo first >"$t/CLAUDE.md"
    WS_STAMP=$stamp ws prune --apply <<<y >/dev/null 2>&1
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    mkdir -p "$t"
    merged_worktree "$t/alpha" feat/t3b 31
    echo second >"$t/CLAUDE.md"
    WS_STAMP=$stamp ws prune --apply <<<y >/dev/null 2>&1
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert "a second archive of the same ticket and stamp gets a dir of its own" \
        grep -qx second "$(trash_dir)/archive/$stamp-t3.2/CLAUDE.md"
    refute "nothing of that ticket stays in the trash" test -e "$(trash_dir)/$stamp-t3"

    mkdir -p "$t"
    merged_worktree "$t/alpha" feat/t3c 32
    echo third >"$t/CLAUDE.md"
    WS_STAMP=$stamp ws prune --apply <<<y >/dev/null 2>&1
    chmod 555 "$(trash_dir)/archive"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    chmod 755 "$(trash_dir)/archive"
    out=$(ws prune --restore t9 2>&1)
    assert "restore lists ticket files that did not reach the archive" \
        grep -q "^Kept ~/.*/$stamp-t3: it holds no record. No repo lists a worktree in it. ws keeps what it holds.$" \
        <<<"$out"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "purge lists them too" grep -q "^Kept ~/.*/$stamp-t3: it holds no record" <<<"$out"
    refute "with no record, no note moves them" grep -q '^    ' <<<"$out"
    assert "the notes settle" settle
    assert "the files stay in the trash" grep -qx third "$(trash_dir)/$stamp-t3/CLAUDE.md"
    out=$(ws prune --restore t3 2>&1)
    assert "restore t3 brings those ticket files back" grep -qx third "$t/CLAUDE.md"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    git -C "$entry" worktree move "$entry" "$FX/away"
    out=$(ws prune --restore nothing-like-this 2>&1)
    assert "restore lists a record whose directory is missing" \
        grep -q "^Record ~/.*-alpha-merged.meta has no directory" <<<"$out"
    out=$(ws prune --purge --older-than 0d <<<n 2>&1)
    cmd=$(grep -A1 "^Record ~/.*-alpha-merged.meta has no directory" <<<"$out" | sed -n 2p)
    assert "purge lists it too, with the command that deletes the record" grep -q "^ *rm -- " <<<"$cmd"
    bash -c "$cmd" >/dev/null 2>&1
    refute "that command deletes the record" test -e "$entry.meta"
    assert "the worktree the record named is untouched" is_worktree "$FX/away"
}

test_orphan_without_a_record() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged b=$WS_ROOT/t1/beta me be bdir out cmd
    ws prune --apply <<<y >/dev/null 2>&1
    me=$(trash_of "$m")
    be=$(trash_of "$b")
    bdir=${be%/*}
    rm "$me.meta" "$be.meta"
    out=$(ws prune --restore alpha-merged 2>&1)
    refute "no recovery command holds a placeholder" grep -q "<path>" <<<"$out"
    assert "the note says where the trash name says it came from" \
        grep -q "^Orphan ~/.*-alpha-merged has no record. Its trash name says it came from ~/projects/alpha-merged" \
        <<<"$out"
    cmd=$(grep -A1 "^Orphan ~/.*-alpha-merged has no record" <<<"$out" | sed -n 2p)
    bash -c "$cmd" >/dev/null 2>&1
    assert "its command puts the worktree back" is_worktree "$m"
    assert "a ticket dir with no record names the worktree git lists in it" \
        grep -qF "Kept ~/${bdir#"$HOME/"}: it holds no record. ~/projects/beta lists a worktree in it, at ~/${be#"$HOME/"}." \
        <<<"$out"
    refute "and prints no step for it" grep -qE '^    .*-t1/beta' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the ticket worktree stays where git lists it" is_worktree "$be"
}

test_restore_keeps_the_record_when_git_fails() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged
    ws prune --apply <<<y >/dev/null 2>&1
    fake_git 'if [[ " $* " == *" worktree move "* ]]; then echo "fatal: simulated failure" >&2; exit 128; fi'
    ws prune --restore alpha-merged >/dev/null 2>&1
    rm "$FX/bin/git"
    assert "a restore that git fails keeps the record" test -n "$(meta_of "$m")"
    ws prune --restore alpha-merged >/dev/null 2>&1
    assert "the next restore puts the worktree back" is_worktree "$m"
}

test_vanished_process() {
    new_fixture
    local out
    fake_proc 240 1 "$FX"
    fake_proc 250 240
    fake_proc 300 250
    ln -s "$FX/exited" "$WS_PROC/1000"
    out=$(ws prune 2>/dev/null)
    assert_eq "a process that exits during the scan never hides a later process of ours" "KEEP unreadable" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert "the table names the process that hides its directory" \
        grep -q "process 300 " <<<"$(detail_of "$out" "$WS_PROJECTS/alpha-merged")"
}

test_process_scan_fails_closed() {
    new_fixture
    local out cmd real
    for cmd in awk find; do
        real=$(PATH=$_base_path command -v "$cmd")
        case $cmd in
        awk) printf '#!/usr/bin/env bash\n[[ " $* " != *" me="* ]] || exit 2\nexec %q "$@"\n' "$real" ;;
        find) printf '#!/usr/bin/env bash\n[[ " $* " != *"/cwd "* ]] || exit 2\nexec %q "$@"\n' "$real" ;;
        esac >"$FX/bin/$cmd"
        chmod +x "$FX/bin/$cmd"
        out=$(ws prune 2>/dev/null)
        rm "$FX/bin/$cmd"
        assert_eq "every worktree is KEEP unreadable when the process scan's $cmd fails" \
            "REMOVE 0  KEEP 9 (unreadable 9)" "$(tail -n 1 <<<"$out")"
    done
}

test_containers() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed b=$WS_ROOT/t1/beta v=$WS_PROJECTS/alpha-vol out
    merged_worktree "$v" feat/vol 40
    mkdir -p "$c/data"
    echo data/ >>"$WS_PROJECTS/alpha/.git/info/exclude"
    ln -s "$WS_PROJECTS" "$FX/projects-link"
    add_container docker web bind "$FX/projects-link/alpha-merged"
    add_container docker cache bind "$c/data"
    add_container podman pod bind "$WS_ROOT"
    add_container docker named volume "$v"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a worktree a container bind-mounts is KEEP in-use" "KEEP in-use" "$(action_of "$out" "$m")"
    assert "the row names that container" grep -q "docker container web" <<<"$(detail_of "$out" "$m")"
    assert_eq "a worktree that holds a container's bind mount is KEEP in-use" "KEEP in-use" "$(action_of "$out" "$c")"
    assert_eq "a worktree inside a podman container's bind mount is KEEP in-use" "KEEP in-use" \
        "$(action_of "$out" "$b")"
    assert "that row names the podman container" grep -q "podman container pod" <<<"$(detail_of "$out" "$b")"
    assert "the first stays in place" is_worktree "$m"
    assert "the second stays in place" is_worktree "$c"
    assert "the third stays in place" is_worktree "$b"
    assert_eq "a volume mount is not a bind mount" REMOVE "$(action_of "$out" "$v")"
}

test_engine_errors() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" \
        >"$FX/docker.err"
    echo "failed to connect to the docker API at unix:///run/user/1000/podman.sock; check if the path is correct and if the daemon is running: dial unix /run/user/1000/podman.sock: connect: no such file or directory" \
        >"$FX/podman.err"
    out=$(ws prune 2>/dev/null)
    assert_eq "an engine whose daemon does not run has no containers" REMOVE "$(action_of "$out" "$m")"

    echo "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock" >"$FX/docker.err"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "every worktree is KEEP unreadable when an engine fails another way" "REMOVE 0  KEEP 9 (unreadable 9)" \
        "$(grep '^REMOVE [0-9]' <<<"$out")"
    assert "the row names the engine error" grep -q "docker ps failed: permission denied" <<<"$(detail_of "$out" "$m")"
    assert "nothing moves" is_worktree "$m"

    rm "$FX/docker.err" "$FX/podman.err"
    add_container docker web bind "$FX/elsewhere"
    echo id-gone >"$FX/docker.gone"
    out=$(ws prune 2>/dev/null)
    assert_eq "a container that stops between ps and inspect is no error" REMOVE "$(action_of "$out" "$m")"
    echo "Error response from daemon: inspect is not allowed" >"$FX/docker.inspect.err"
    out=$(ws prune 2>/dev/null)
    assert_eq "every worktree is KEEP unreadable when inspect fails another way" "REMOVE 0  KEEP 9 (unreadable 9)" \
        "$(tail -n 1 <<<"$out")"
    assert "the row names the inspect error" grep -q "docker inspect failed: Error response" <<<"$(detail_of "$out" "$m")"
}

late_container() {
    add_container docker late bind "$LATE_SOURCE"
}

test_containers_are_checked_before_each_move() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry
    LATE_SOURCE=$m answer_yes_at_prompt late_container prune --apply
    assert "a container started at the apply prompt keeps its worktree in place" is_worktree "$m"
    assert "apply says it skipped that worktree and names the container" \
        grep -qx "Skipped ~/projects/alpha-merged: KEEP in-use (docker container late)" "$FX/out"

    echo '[]' >"$FX/docker.json"
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    LATE_SOURCE=$entry answer_yes_at_prompt late_container prune --purge --older-than 0d
    assert "a container started at the purge prompt on an entry keeps that entry" is_worktree "$entry"
    assert "purge says why it keeps it and names the container" \
        grep -q "^Kept ~/.*-alpha-merged: KEEP in-use (docker container late)$" "$FX/out"
}

branch_reflog_commit() {
    local a=$WS_PROJECTS/alpha tip c
    {
        tip=$(git -C "$a" rev-parse refs/heads/feat/merged) &&
            c=$(git -C "$a" commit-tree -p "$tip" -m "only the branch reflog holds this" "$tip^{tree}") &&
            git -C "$a" update-ref -m in refs/heads/feat/merged "$c" "$tip" &&
            git -C "$a" update-ref -m out refs/heads/feat/merged "$tip" "$c" &&
            echo "$c"
    } || abort "cannot make a commit only the branch reflog holds"
}

test_purge_survives_reflog_step_failures() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged l1 l2 entry step real
    l1=$(lost_commit "$m" l1)
    l2=$(branch_reflog_commit)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    for step in "log -g" "rev-list --ignore-missing" "rev-parse --show-object-format" "init -q --bare" \
        "--git-path objects" "update-ref --stdin" "bundle create" "bundle verify" sort mkdir cat; do
        case $step in
        sort | mkdir | cat)
            real=$(PATH=$_base_path command -v "$step")
            case $step in
            sort) printf '#!/usr/bin/env bash\n[[ $1 == -u && -f ${2-} ]] && exit 2\n' ;;
            mkdir) printf '#!/usr/bin/env bash\n[[ " $* " == *"/archive"* ]] && exit 1\n' ;;
            cat) printf '#!/usr/bin/env bash\n[[ ${*: -1} == */edges ]] && exit 1\n' ;;
            esac >"$FX/bin/$step"
            printf 'exec %q "$@"\n' "$real" >>"$FX/bin/$step"
            chmod +x "$FX/bin/$step"
            ;;
        *) fake_git "[[ \" \$* \" != *\" $step \"* ]] || exit 1" ;;
        esac
        ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
        rm -f "$FX/bin/git" "$FX/bin/sort" "$FX/bin/mkdir" "$FX/bin/cat"
        assert "a failing $step keeps the entry" is_worktree "$entry"
        assert "a failing $step never loses a commit only the HEAD reflog holds" reachable "$l1"
        assert "a failing $step never loses a commit only the branch reflog holds" reachable "$l2"
        refute "a failing $step leaves no bundle" compgen -G "$(trash_dir)/archive/*.bundle"
    done

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    l1=$(lost_commit "$m" l1)
    l2=$(branch_reflog_commit)
    ws prune --apply <<<y >/dev/null 2>&1
    fake_git '[[ " $* " != *" reflog exists "* ]] || { echo "error: cannot read the reflog" >&2; exit 1; }'
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    assert "a failing git reflog exists never loses a commit only the branch reflog holds" reachable "$l2"
    assert "it never loses a commit only the HEAD reflog holds" reachable "$l1"
}

test_purge_saves_worktree_ref_reflogs() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged tip l3 entry
    git -C "$WS_PROJECTS/alpha" config core.logAllRefUpdates always
    tip=$(head_of "$m")
    l3=$(git -C "$m" commit-tree -p "$tip" -m "only a worktree ref reflog holds this" "$tip^{tree}")
    git -C "$m" update-ref -m mark refs/worktree/mark "$l3"
    git -C "$m" update-ref -m back refs/worktree/mark "$tip"
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert "purge deletes that worktree" test ! -e "$entry"
    assert "a commit only a refs/worktree reflog holds goes to the bundle" reachable "$l3"
}

test_moves_land_where_ws_asked() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out cmd
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    fake_git "if [[ \" \$* \" == *' worktree move '* && \${*: -2:1} == $(printf %q "$entry") ]]; then
    \"\$real\" \"\$@\"
    rc=\$?
    echo wip >\"\${*: -1}/wip.txt\"
    exit \$rc
fi
if [[ \" \$* \" == *' worktree move '* && \${*: -2:1} == *.purging && ! -e $(printf %q "$FX/fired") ]]; then
    : >$(printf %q "$FX/fired")
    mkdir -p \"\${*: -1}/logs\"
fi"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    rm "$FX/bin/git"
    assert "an entry whose path another process took during the move back stays at its .purging name" \
        is_worktree "$entry.purging"
    refute "it never lands inside that dir" test -e "$entry/${entry##*/}.purging"
    assert "its untracked file is still there" test -f "$entry.purging/wip.txt"
    assert "its record stays" test -f "$entry.meta"
    assert "purge lists it as an orphan" grep -q "^Orphan ~/.*-alpha-merged.purging" <<<"$out"
    cmd=$(grep -A1 "^Orphan ~/.*-alpha-merged.purging" <<<"$out" | sed -n 2p)
    bash -c "$cmd" >/dev/null 2>&1
    assert "the listed command moves it out of the trash while that dir is taken" is_worktree "$m"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    fake_git "if [[ \" \$* \" == *' worktree move '* && \${*: -1} == $(printf %q "$m") ]]; then
    mkdir -p $(printf %q "$m/logs")
fi"
    out=$(ws prune --restore alpha-merged 2>&1)
    rm "$FX/bin/git"
    assert "a restore whose path another process took leaves the worktree in the trash" is_worktree "$entry"
    refute "it never lands inside that dir" test -e "$m/${entry##*/}"
    assert "its record stays" test -f "$entry.meta"
    rm -r "$m"
    ws prune --restore alpha-merged >/dev/null 2>&1
    assert "the next restore puts it back" is_worktree "$m"
}

test_partial_remove() {
    local variant m entry out lost
    for variant in ignored git-first root; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        lost=$(lost_commit "$m" draft)
        if [[ $variant != root ]]; then
            echo node_modules >>"$WS_PROJECTS/alpha/.git/info/exclude"
            mkdir -p "$m/node_modules/pkg"
            echo x >"$m/node_modules/pkg/index.js"
        fi
        ws prune --apply <<<y >/dev/null 2>&1
        entry=$(trash_of "$m")
        case $variant in
        ignored) chmod 555 "$entry/node_modules/pkg" ;;
        git-first)
            cp -p "$entry/.git" "$entry/.git.new" && mv -T "$entry/.git.new" "$entry/.git"
            chmod 555 "$entry/node_modules/pkg"
            ;;
        root) chmod 555 "$entry" ;;
        esac
        out=$(ws prune --purge --older-than 0d <<<y 2>&1)
        refute "purge never tries to move back a worktree git no longer knows" grep -q "is not a working tree" <<<"$out"
        out=$(ws prune --restore nothing-like-this 2>&1)
        assert "after a $variant partial remove, restore lists what is left" grep -q "alpha-merged.purging" <<<"$out"
        refute "it prints no step that moves or deletes what is left" grep -q '^    .*alpha-merged' <<<"$out"
        assert "the notes settle" settle
        assert "what git could not delete stays in the trash" compgen -G "$(trash_dir)/*-alpha-merged.purging/*"
        assert "its reflog commit is in a bundle" reachable "$lost"
    done
}

test_apply_keeps_the_record_when_git_fails_after_its_move() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry
    fake_git "if [[ \$2 == worktree && \$3 == move && \$4 == $(printf %q "$m") ]]; then
    \"\$real\" \"\$@\"
    echo $(printf %q "$m/.git") >$(printf %q "$WS_PROJECTS/alpha/.git/worktrees/alpha-merged/gitdir")
    exit 1
fi"
    ws prune --apply <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    entry=$(compgen -G "$(trash_dir)/*-alpha-merged")
    assert "a worktree git moved before it failed keeps its unfinished record" test -f "$entry.meta.tmp"
}

test_leftover_records() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed entry out cmd
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$c")
    git -C "$entry" worktree move "$entry" "$FX/away"
    mv "$entry.meta" "$entry.meta.tmp"
    out=$(ws prune --restore nothing-like-this 2>&1)
    assert "restore lists an unfinished record whose directory is gone" \
        grep -q "^Unfinished record ~/.*-alpha-closed.meta.tmp has no directory" <<<"$out"
    out=$(ws prune --purge --older-than 0d <<<n 2>&1)
    assert "purge lists it" grep -q "^Unfinished record ~/.*-alpha-closed.meta.tmp" <<<"$out"
    refute "it prints no command that deletes an unfinished record whose worktree ws cannot find" \
        destructive_note "$out"
    follow_notes
    assert "following the notes keeps it" test -f "$entry.meta.tmp"

    entry=$(trash_of "$m")
    echo junk >>"$entry.meta"
    out=$(ws prune --purge --older-than 0d <<<n 2>&1)
    assert "purge says why it keeps an entry with a bad record" grep -q "^Kept ~/.*-alpha-merged: bad record" <<<"$out"
    cmd=$(grep -A1 "^Kept ~/.*-alpha-merged: bad record" <<<"$out" | sed -n 2p)
    bash -c "$cmd" >/dev/null 2>&1
    assert "the next step it prints puts the worktree back" is_worktree "$m"
    assert "that step keeps the record ws cannot read" test -e "$entry.meta"
}

test_orphan_name_with_a_counter() {
    new_fixture
    local a=$WS_ROOT/t1/alpha b=$WS_ROOT/t1/beta entry out cmd
    merged_worktree "$WS_PROJECTS/t1" feat/t1p 50
    sed -i '/^alpha\tfeat\/ticket\tOPEN/d' "$FX/prs.tsv"
    add_pr alpha feat/ticket MERGED 70 "$(head_of "$a")"
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$b")
    assert "a ticket named like a worktree gets a counter in the stamp of its trash dir" \
        grep -Eq '/[0-9]{8}T[0-9]{6}Z\.2-t1/beta$' <<<"$entry"
    rm "$entry.meta"
    out=$(ws prune --restore beta 2>&1)
    assert "its orphan note names the ticket path it came from" grep -q "came from ~/work/t1/beta\." <<<"$out"
    cmd=$(grep -A1 "^Orphan ~/.*/beta has no record" <<<"$out" | sed -n 2p)
    bash -c "$cmd" >/dev/null 2>&1
    assert "its command puts it back in its ticket" is_worktree "$b"
}

notes() {
    { ws prune --restore nothing-like-this && ws prune --purge --older-than 99999d <<<n; } 2>&1 | awk '!seen[$0]++'
}

follow_notes() {
    local round line ran
    for ((round = 0; round < 6; round++)); do
        ran=0
        while IFS= read -r line; do
            [[ $line =~ ^\ {4}(git\ -C|chmod|mkdir|rm|rmdir|mv)\  ]] || continue
            bash -c "$line" >/dev/null 2>&1
            ran=1
        done < <(notes)
        ((ran)) || return 0
    done
    return 1
}

destructive_note() {
    grep -Eq '^ {4}.*(rm |mv -T|mv -nT)' <<<"$1"
}

# rev-list --reflog still walks a stale worktree's reflogs until git worktree prune drops them.
settle() {
    local repo
    follow_notes || return 1
    for repo in "$WS_PROJECTS"/*/.git "$@"; do
        [[ ! -d $repo ]] || git --git-dir="$repo" worktree prune || return 1
    done
}

nothing_in_trash() {
    [[ -z $(find "$(trash_dir)" -path "$(trash_dir)/archive" -prune -o -name "*$1*" -print) ]]
}

test_engine_down_needs_every_line() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    add_container podman devbox bind "$m"
    printf '%s\n' "WARN[0000] Failed to add pause process to systemd sandbox cgroup: dial unix /run/user/1000/bus: connect: no such file or directory" \
        "Error: acquiring lock 3 for container 4f2a: file exists" >"$FX/podman.err"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "an engine error with one line that looks like a stopped daemon is still an error" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
    assert "the row names that error" grep -q "podman ps failed: WARN" <<<"$(detail_of "$out" "$m")"
    assert "the worktree stays in place" is_worktree "$m"

    printf '%s\n' "permission denied while trying to connect: dial unix /var/run/docker.sock: connect: permission denied" \
        "dial tcp: connect: connection refused" >"$FX/docker.err"
    rm "$FX/podman.err"
    out=$(ws prune 2>/dev/null)
    assert_eq "a permission error next to a refused connection is an error" "KEEP unreadable" "$(action_of "$out" "$m")"

    rm "$FX/docker.err"
    mkdir "$FX/wrap"
    printf '#!/usr/bin/env bash\nif [[ $1 == ps ]]; then echo "WARN[0000] dial unix /run/user/1000/bus: connect: no such file or directory" >&2; exit 124; fi\nexec %q "$@"\n' \
        "$FX/bin/podman" >"$FX/wrap/podman"
    chmod +x "$FX/wrap/podman"
    out=$(PATH=$FX/wrap:$PATH ws prune 2>/dev/null)
    assert_eq "an engine that exits 124 is an error, whatever it printed" "KEEP unreadable" "$(action_of "$out" "$m")"
    assert "the row names what it printed" grep -q "podman ps failed: WARN" <<<"$(detail_of "$out" "$m")"
}

test_engine_down_with_running_containers() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" \
        >"$FX/docker.err"
    fake_proc 600 1 "" "" containerd-shim-runc-v2
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a stopped daemon with a container runtime still running makes every worktree KEEP unreadable" \
        "REMOVE 0  KEEP 9 (unreadable 9)" "$(grep '^REMOVE [0-9]' <<<"$out")"
    assert "the row says containers may still run" grep -q "containers may still run: process 600" \
        <<<"$(detail_of "$out" "$m")"
    assert "nothing moves" is_worktree "$m"
    rm -r "$WS_PROC/600"
    fake_proc 601 1 "" "" conmon
    out=$(ws prune 2>/dev/null)
    assert_eq "conmon counts as a container runtime too" "KEEP unreadable" "$(action_of "$out" "$m")"
}

test_inspect_must_answer_for_every_container() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    add_container docker web bind "$m"
    echo "Error: No such object: zzz" >"$FX/docker.inspect.err"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "inspect that prints nothing for a listed container is an error" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
    assert "the worktree stays in place" is_worktree "$m"
    rm "$FX/docker.inspect.err"
    mkdir "$FX/wrap"
    printf '#!/usr/bin/env bash\nif [[ $1 == inspect ]]; then echo "Error: No such object: $2" >&2; exit 124; fi\nexec %q "$@"\n' \
        "$FX/bin/docker" >"$FX/wrap/docker"
    chmod +x "$FX/wrap/docker"
    out=$(PATH=$FX/wrap:$PATH ws prune 2>/dev/null)
    assert_eq "inspect that times out is an error even when it says the container is gone" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
}

set_containers() {
    jq "$2" <<<'[]' >"$FX/$1.json" || abort "cannot write $1.json"
}

test_container_mount_shapes() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out real
    set_containers docker "[{Id: \"id-a\", Name: \"/a\", Mounts: null, HostConfig: {Binds: [\"$m:/src:ro\", \"data:/data\"]}}]"
    out=$(ws prune 2>/dev/null)
    assert_eq "a bind in HostConfig.Binds is KEEP in-use" "KEEP in-use" "$(action_of "$out" "$m")"
    assert "that row names the container" grep -q "docker container a" <<<"$(detail_of "$out" "$m")"
    assert_eq "a named volume in HostConfig.Binds is no bind" REMOVE "$(action_of "$out" "$WS_PROJECTS/alpha-closed")"
    set_containers docker "[{Id: \"id-a\", Name: \"/a\", Mounts: [{Type: \"bind\", Source: \"$m\"}], HostConfig: {Binds: [\"$m:/src\"]}}]"
    out=$(ws prune 2>/dev/null)
    assert_eq "a bind in both Mounts and Binds names its container once" "docker container a" "$(detail_of "$out" "$m")"

    set_containers docker '[{Id: "id-a", Name: "/a", Mounts: [{Type: "Bind", Source: "'"$m"'"}]}]'
    out=$(ws prune 2>/dev/null)
    assert_eq "a mount type in another case is still a bind" "KEEP in-use" "$(action_of "$out" "$m")"

    for real in '"projects/alpha-merged"' '"~/projects/alpha-merged"' null; do
        set_containers docker '[{Id: "id-a", Name: "/a", Mounts: [{Type: "bind", Source: '"$real"'}]}]'
        out=$(ws prune 2>/dev/null)
        assert_eq "a bind source $real is no absolute path, so every row is KEEP unreadable" \
            "REMOVE 0  KEEP 9 (unreadable 9)" "$(tail -n 1 <<<"$out")"
    done
    set_containers docker '[{Id: "id-a", Name: "/a", HostConfig: {Binds: ["~/projects/alpha-merged:/src"]}}]'
    out=$(ws prune 2>/dev/null)
    assert_eq "a relative source in HostConfig.Binds makes every row KEEP unreadable" \
        "REMOVE 0  KEEP 9 (unreadable 9)" "$(tail -n 1 <<<"$out")"

    for real in '"/evil\u0000/elsewhere"' '"/a\u0000/b\u0000c"'; do
        set_containers docker '[{Id: "id-a", Name: '"$real"', Mounts: [{Type: "bind", Source: "'"$m"'"}]}]'
        out=$(ws prune 2>/dev/null)
        assert_eq "a container name $real with a NUL byte makes every row KEEP unreadable" \
            "REMOVE 0  KEEP 9 (unreadable 9)" "$(tail -n 1 <<<"$out")"
    done

    set_containers docker '[{Id: "id-a", Name: "/a", Mounts: [{Type: "bind", Source: "'"$m"'"}]}]'
    real=$(PATH=$_base_path command -v jq)
    printf '#!/usr/bin/env bash\nif [[ " $* " == *" --arg engine "* ]]; then %q "$@" | tr -d "\\000"; exit "${PIPESTATUS[0]}"; fi\nexec %q "$@"\n' \
        "$real" "$real" >"$FX/bin/jq"
    chmod +x "$FX/bin/jq"
    out=$(ws prune 2>/dev/null)
    rm "$FX/bin/jq"
    assert_eq "jq output without its NUL separators makes every row KEEP unreadable" \
        "REMOVE 0  KEEP 9 (unreadable 9)" "$(tail -n 1 <<<"$out")"
}

test_container_processes() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    fake_proc 240 1 "$FX"
    fake_proc 700 1 "" "" containerd-shim-runc-v2
    fake_cmdline 700 /usr/bin/containerd-shim-runc-v2 -namespace moby -id 4f2a -address /run/containerd/containerd.sock
    fake_proc 701 700
    fake_proc 702 701
    fake_proc 710 1 "" "" conmon
    fake_proc 711 710
    fake_proc 712 711
    out=$(ws prune 2>/dev/null)
    assert_eq "processes below a containerd-shim or conmon are judged by the engines' mounts" REMOVE \
        "$(action_of "$out" "$m")"
    mv "$FX/bin/podman" "$FX/bin/podman-off"
    out=$(ws prune 2>/dev/null)
    assert_eq "a process below conmon with no podman to vouch for it hides its directory" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
    assert "the row names that process" grep -q "process 712 " <<<"$(detail_of "$out" "$m")"
    mv "$FX/bin/podman-off" "$FX/bin/podman"
    fake_proc 740 1 "" "" containerd-shim-runc-v2
    fake_cmdline 740 /usr/bin/containerd-shim-runc-v2 -namespace k8s.io -id 9c1d -address /run/k3s/containerd/containerd.sock
    fake_proc 741 740
    fake_proc 742 741
    out=$(ws prune 2>/dev/null)
    assert_eq "a process below a containerd-shim of another containerd namespace hides its directory" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
    assert "the row names that process" grep -q "process 742 " <<<"$(detail_of "$out" "$m")"
    rm -r "$WS_PROC/740" "$WS_PROC/741" "$WS_PROC/742"
    fake_proc 720 999
    out=$(ws prune 2>/dev/null)
    assert_eq "a hidden process whose parent has no entry fails closed" "KEEP unreadable" "$(action_of "$out" "$m")"
    rm -r "$WS_PROC/720"
    fake_proc 721 0
    out=$(ws prune 2>/dev/null)
    assert_eq "a hidden process with parent 0 fails closed" "KEEP unreadable" "$(action_of "$out" "$m")"
    rm -r "$WS_PROC/721"
    fake_proc 730 240
    fake_proc 731 730 "$m"
    printf '#!/usr/bin/env bash\n[[ " $* " != *"/cwd "* ]] || exit 0\nexec %q "$@"\n' "$(PATH=$_base_path command -v find)" \
        >"$FX/bin/find"
    chmod +x "$FX/bin/find"
    out=$(ws prune 2>/dev/null)
    rm "$FX/bin/find"
    assert_eq "a process of ours that the cwd scan missed still counts" "KEEP in-use" "$(action_of "$out" "$m")"
}

test_purge_checks_the_original_path() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    add_container docker devbox bind "$m"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "a container that mounts the path an entry came from keeps that entry" is_worktree "$entry"
    assert "purge names that container" grep -q "^Kept ~/.*-alpha-merged: KEEP in-use (docker container devbox)" <<<"$out"
}

test_bundle_path_taken() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry lost out bundle real
    lost=$(lost_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    bundle=$(trash_dir)/archive/${entry##*/}.bundle
    mkdir -p "$(trash_dir)/archive"
    fake_git "if [[ \" \$* \" == *' bundle verify '* ]]; then
    \"\$real\" \"\$@\"
    rc=\$?
    echo someone-elses >$(printf %q "$bundle")
    exit \$rc
fi"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    rm "$FX/bin/git"
    assert "an entry whose bundle path another process took stays" is_worktree "$entry"
    assert_eq "the other process's file is untouched" someone-elses "$(<"$bundle")"
    assert "purge says that path exists" grep -q "^ws: ~/.*\.bundle exists" <<<"$out"
    assert "the commit only its reflog holds is still there" reachable "$lost"

    rm "$bundle"
    real=$(PATH=$_base_path command -v ln)
    printf '#!/usr/bin/env bash\n[[ ${*: -2:1} != */bundle ]] || exit 0\nexec %q "$@"\n' "$real" >"$FX/bin/ln"
    chmod +x "$FX/bin/ln"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/ln"
    assert "an entry whose bundle ln reports a link it did not make stays" is_worktree "$entry"
    refute "and no bundle shows up in the archive" compgen -G "$(trash_dir)/archive/*.bundle"
}

test_bundle_on_a_full_trash() {
    new_fixture
    if ! unshare -rm true 2>/dev/null; then
        ok "full trash bundle skipped: no user namespaces"
        return
    fi
    local out
    mkdir "$FX/small" "$FX/wrap"
    printf '#!/usr/bin/env bash\n%q "$@"\nrc=$?\nif [[ " $* " == *" bundle verify "* && ! -e $SM/full ]]; then : >"$SM/full"; dd if=/dev/zero of="$SM/fill" bs=4k 2>/dev/null; fi\nexit $rc\n' \
        "$(command -v git)" >"$FX/wrap/git"
    chmod +x "$FX/wrap/git"
    cat >"$FX/inner.sh" <<'EOF'
set -u
mount -t tmpfs -o size=2m tmpfs "$SM" || exit 9
export WS_ROOT=$SM/work WS_TRASH=$SM/trash
mkdir -p "$WS_ROOT/t9" "$WS_TRASH"
wt=$WS_ROOT/t9/alpha
git -C "$WS_PROJECTS/alpha" worktree add -q -b feat/small "$wt"
echo s >"$wt/s.txt"
git -C "$wt" add s.txt
git -C "$wt" commit -qm small
git -C "$wt" push -q -u origin feat/small
printf 'alpha\tfeat/small\tMERGED\t300\t%s\tfalse\n' "$(git -C "$wt" rev-parse HEAD)" >>"$FX/prs.tsv"
echo l >"$wt/l.txt"
git -C "$wt" add l.txt
git -C "$wt" commit -qm lost
lost=$(git -C "$wt" rev-parse HEAD)
git -C "$wt" reset -q --hard HEAD~1
bash "$WS_BIN" prune --apply <<<y >/dev/null 2>&1
PATH=$WRAP:$PATH bash "$WS_BIN" prune --purge --older-than 0d <<<y >/dev/null 2>&1
rm -f "$SM/fill"
for b in "$WS_TRASH"/archive/*.bundle "$WS_TRASH"/archive/*/*.bundle; do
    [[ -e $b ]] || continue
    if git -C "$WS_PROJECTS/alpha" bundle list-heads "$b" 2>/dev/null | grep -q "^$lost "; then echo saved; else echo broken; fi
done
git -C "$WS_PROJECTS/alpha" rev-list --all --reflog | grep -qx "$lost" && echo kept
umount "$SM"
EOF
    WS_ROOT=$FX/small/work WS_TRASH=$FX/small/trash ws_guard
    out=$(env SM="$FX/small" FX="$FX" WS_BIN="$WS_BIN" WRAP="$FX/wrap" unshare -rm bash "$FX/inner.sh" 2>&1)
    refute "a trash that fills while purge saves a bundle never keeps a broken bundle" grep -qx broken <<<"$out"
    assert "purge still saves the commit only the reflog holds, since the bundle only needs a link" grep -qx saved <<<"$out"
}

test_detail_is_decoded() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    echo 'x%y.log' >>"$WS_PROJECTS/alpha/.git/info/exclude"
    echo secret >"$m/x%y.log"
    out=$(ws prune 2>/dev/null)
    assert_eq "a file name with a percent sign shows as it is" "x%y.log" "$(detail_of "$out" "$m")"
    rm "$m/x%y.log"
    echo 'Error: http://%2Fvar%2Frun%2Fdocker.sock: connect: permission denied' >"$FX/docker.err"
    out=$(ws prune 2>/dev/null)
    assert_eq "an engine error with a percent sign shows as the engine printed it" \
        "docker ps failed: Error: http://%2Fvar%2Frun%2Fdocker.sock: connect: permission denied" \
        "$(detail_of "$out" "$m")"
}

test_empty_ticket_dir_is_listed() {
    new_fixture
    local b=$WS_ROOT/t1/beta entry
    merged_worktree "$WS_PROJECTS/t1" feat/t1p 50
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$b")
    git -C "$entry" worktree move "$entry" "$b"
    rm "$entry.meta"
    assert "the notes settle" settle
    refute "following them leaves no empty ticket dir in the trash" test -e "${entry%/*}"
    assert "the worktree stays where it was moved" is_worktree "$b"
}

test_purge_fails_when_ticket_files_stay() {
    new_fixture
    local t=$WS_ROOT/t3
    mkdir -p "$t"
    merged_worktree "$t/alpha" feat/t3 30
    echo note >"$t/CLAUDE.md"
    ws prune --apply <<<y >/dev/null 2>&1
    mkdir -p "$(trash_dir)/archive"
    chmod 555 "$(trash_dir)/archive"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert_eq "purge exits 1 when ticket files could not move to the archive" 1 $?
    chmod 755 "$(trash_dir)/archive"
}

test_wsproc_self_must_be_a_dir() {
    new_fixture
    local out
    mkdir "$FX/link-proc"
    ln -s "$FX/link-proc/gone" "$FX/link-proc/self"
    out=$(WS_PROC=$FX/link-proc ws prune 2>&1)
    assert_eq "a WS_PROC whose self is a dangling symlink exits 1" 1 $?
    assert "it says what WS_PROC lacks" grep -q "^ws: WS_PROC .*self directory" <<<"$out"
}

test_notes_follow_a_nested_purge() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry lost out
    lost=$(lost_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    fake_git 'if [[ $2 == worktree && $3 == move && $5 == *-alpha-merged.purging ]]; then
    mkdir -p "$5/logs"
    "$real" "$@"
    kill -KILL "$PPID"
    exit
fi'
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    out=$(notes)
    assert "the next run names the worktree git lists inside the dir" \
        grep -qF "lists a worktree in it, at ~/${entry#"$HOME/"}.purging/${entry##*/}." <<<"$out"
    refute "it never says the dir has no record" grep -q "alpha-merged.purging has no record" <<<"$out"
    refute "it prints no step" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the worktree stays where git lists it" is_worktree "$entry.purging/${entry##*/}"
    assert "and the commit only its HEAD reflog holds" reachable "$lost"
}

test_notes_follow_a_moved_main_checkout() {
    local gitfile m entry lost out
    for gitfile in absolute relative; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        lost=$(lost_commit "$m" l1)
        ws prune --apply <<<y >/dev/null 2>&1
        entry=$(trash_of "$m")
        if [[ $gitfile == relative ]]; then
            printf 'gitdir: %s\n' "$(realpath -m --relative-to="$entry" "$WS_PROJECTS/alpha/.git/worktrees/alpha-merged")" \
                >"$entry/.git"
        fi
        rm "$entry.meta"
        mv "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-moved"
        out=$(notes)
        assert "with a $gitfile .git file, the note says where it points, and that the path is gone" \
            grep -qF "its .git file points at ~/projects/alpha/.git/worktrees/alpha-merged, which is gone" <<<"$out"
        refute "it prints no step" grep -q '^    ' <<<"$out"
        assert "following the notes and pruning every repo settles" settle
        assert "the entry keeps its files" test -f "$entry/work.txt"
        assert "and the commit only its HEAD reflog holds" reachable "$lost"
    done
}

test_double_nest_keeps_the_record() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    fake_git 'if [[ $2 == worktree && $3 == move && $5 == *-alpha-merged ]]; then
    mkdir -p "$5/logs"
elif [[ $2 == worktree && $3 == move && $5 == */projects/alpha-merged ]]; then
    mkdir -p "$5/cache"
fi'
    out=$(ws prune --apply <<<y 2>&1)
    rm "$FX/bin/git"
    assert "apply names where the worktree is after both moves nested" \
        grep -q "it is at ~/projects/alpha-merged/alpha-merged" <<<"$out"
    entry=$(compgen -G "$(trash_dir)/*-alpha-merged")
    assert "its unfinished record stays" test -f "$entry.meta.tmp"
    assert "the record holds where the worktree is" grep -qx "at=$m/alpha-merged" "$entry.meta.tmp"
    out=$(notes)
    assert "the next run names that path" grep -q "lists its worktree at ~/projects/alpha-merged/alpha-merged" <<<"$out"
    refute "it prints no move or rm while the worktree sits there" grep -qE '^    .*(worktree move|rm -- )' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the worktree stays where git lists it" is_worktree "$m/alpha-merged"
    assert "and its record stays" test -f "$entry.meta.tmp"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    echo "at=$FX/earlier" >>"$entry.meta"
    fake_git "if [[ \$2 == worktree && \$3 == move && \$5 == $(printf %q "$m") ]]; then
    mkdir -p \"\$5/logs\"
elif [[ \$2 == worktree && \$3 == move && \$5 == $(printf %q "$entry") ]]; then
    mkdir -p \"\$5/cache\"
fi"
    out=$(ws prune --restore alpha-merged 2>&1)
    rm "$FX/bin/git"
    assert "restore names where the worktree is after both moves nested" \
        grep -qF "it is at ~/${entry#"$HOME/"}/${entry##*/}" <<<"$out"
    assert "its record holds that path" grep -qx "at=$entry/${entry##*/}" "$entry.meta"
    assert_eq "and only that path" 1 "$(grep -c '^at=' "$entry.meta")"
    assert "following the notes and pruning every repo settles" settle
    assert "the worktree stays where git lists it" is_worktree "$entry/${entry##*/}"
    assert "and its record stays" test -f "$entry.meta"
}

test_trash_temp_dirs_are_not_listed() {
    new_fixture
    local out ns
    ws prune --apply <<<y >/dev/null 2>&1
    ns=$(readlink /proc/self/ns/pid)
    ns=${ns#pid:[}
    mkdir -p "$(trash_dir)/.tmp.$$.${ns%]}.abc123/r"
    echo partial >"$(trash_dir)/.tmp.$$.${ns%]}.abc123/bundle"
    out=$(notes)
    refute "a temp dir of a run that still runs gets no note" grep -q "tmp\..*abc123" <<<"$out"
    assert "and stays" test -d "$(trash_dir)/.tmp.$$.${ns%]}.abc123/r"
}

test_ticket_files_never_hold_a_worktree() {
    local rel b entry nested lost
    for rel in beta x/y x/y/z/w; do
        new_fixture
        b=$WS_ROOT/t1/beta
        lost=$(head_only_commit "$b" l1)
        ws prune --apply <<<y >/dev/null 2>&1
        entry=$(trash_of "$b")
        nested=$entry.n/$rel
        mkdir -p "${nested%/*}"
        git -C "$entry" worktree move "$entry" "$nested"
        rm "$entry.meta"
        ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
        assert "the notes settle with a worktree at beta.n/$rel in a ticket dir" settle
        assert "neither a note nor a purge moves it to the archive" \
            test -z "$(find "$(trash_dir)/archive" -name .git 2>/dev/null)"
        assert "it stays where git lists it" is_worktree "$nested"
        assert "the commit only its HEAD reflog holds survives" reachable "$lost"
    done
}

test_restore_nest_then_kill() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    fake_git "if [[ \$2 == worktree && \$3 == move && \$5 == $(printf %q "$m") ]]; then
    mkdir -p \"\$5/logs\"
    \"\$real\" \"\$@\"
    kill -KILL \"\$PPID\"
    exit
fi"
    ws prune --restore alpha-merged >/dev/null 2>&1
    rm "$FX/bin/git"
    out=$(notes)
    assert "the next run names where git put the worktree" \
        grep -qF "lists its worktree at ~/projects/alpha-merged/${entry##*/}" <<<"$out"
    refute "it prints no step while the worktree sits there" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the worktree stays where git lists it" is_worktree "$m/${entry##*/}"
    assert "and its record stays" test -f "$entry.meta"
}

test_notes_trust_the_repo_that_lists_the_worktree() {
    local variant m entry lost out
    for variant in live stale; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        lost=$(head_only_commit "$m" l1)
        ws prune --apply <<<y >/dev/null 2>&1
        entry=$(trash_of "$m")
        if [[ $variant == live ]]; then
            echo "gitdir: $WS_PROJECTS/beta/.git/worktrees/beta" >"$entry/.git"
        else
            git -C "$WS_PROJECTS/beta" worktree add -q --detach "$FX/ghost" && rm -r "$FX/ghost"
            echo "gitdir: $WS_PROJECTS/beta/.git/worktrees/ghost" >"$entry/.git"
        fi
        out=$(notes)
        refute "an entry whose .git names a $variant worktree of another repo gets no step" grep -q '^    ' <<<"$out"
        assert "its note says where the .git file points" \
            grep -qF "its .git file points at ~/projects/beta/.git/worktrees/" <<<"$out"
        assert "following the notes and pruning every repo settles" settle
        assert "the entry keeps its files" test -f "$entry/work.txt"
        assert "the commit only its HEAD reflog held survives" reachable "$lost"
        assert "the other repo's worktree stays where it was" is_worktree "$(trash_of "$WS_ROOT/t1/beta")"
    done
}

test_notes_after_a_reclone() {
    local variant m entry lost out old
    for variant in inside samename outside; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        lost=$(head_only_commit "$m" l1)
        ws prune --apply <<<y >/dev/null 2>&1
        entry=$(trash_of "$m")
        old=$WS_PROJECTS/alpha-old
        [[ $variant != outside ]] || old=$FX/elsewhere/alpha
        mkdir -p "${old%/*}"
        mv "$WS_PROJECTS/alpha" "$old"
        git clone -q https://github.com/fixture/alpha.git "$WS_PROJECTS/alpha" || abort "cannot clone alpha"
        if [[ $variant == samename ]]; then
            git -C "$WS_PROJECTS/alpha" worktree add -q -b other "$FX/x/alpha-merged" || abort "cannot add a worktree"
        fi
        out=$(notes)
        refute "after a reclone $variant, no note prints a step" grep -q '^    ' <<<"$out"
        assert "following the notes and pruning every repo settles" settle "$old/.git"
        assert "the commit only its HEAD reflog held survives" reachable "$lost" "$old/.git"
        assert "the entry keeps its files" test -f "$entry/work.txt"
        assert "and the old repo still lists it" grep -qxF "worktree $entry" \
            <<<"$(git -C "$old" worktree list --porcelain)"
    done
}

test_notes_with_copies_of_the_main_checkout() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry lost out
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    cp -a "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-copy"
    cp -a "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-copy2"
    mkdir -p "$FX/elsewhere"
    mv "$WS_PROJECTS/alpha" "$FX/elsewhere/alpha"
    out=$(notes)
    assert "with two copies that list the entry, its note names both" \
        grep -qF ". ~/projects/alpha-copy lists it, and ~/projects/alpha-copy2 lists it" <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
    assert "the entry stays" test -f "$entry/work.txt"
    rm -r "$WS_PROJECTS/alpha-copy2"
    out=$(notes)
    refute "with one copy left and the .git file naming a gone path, it prints no step either" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle "$FX/elsewhere/alpha/.git"
    assert "the entry keeps its files" test -f "$entry/work.txt"
    assert "the commit only its HEAD reflog held survives" reachable "$lost" "$FX/elsewhere/alpha/.git"
}

test_notes_find_a_worktree_two_levels_down() {
    local variant m entry lost out
    for variant in meta meta.tmp; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        lost=$(head_only_commit "$m" l1)
        ws prune --apply <<<y >/dev/null 2>&1
        entry=$(trash_of "$m")
        [[ $variant == meta ]] || mv "$entry.meta" "$entry.meta.tmp"
        git -C "$WS_PROJECTS/alpha" worktree move "$entry" "$FX/aside"
        mkdir -p "$entry/x"
        git -C "$WS_PROJECTS/alpha" worktree move "$FX/aside" "$entry/x/y"
        out=$(notes)
        refute "an entry with a $variant record and its worktree two levels down gets no step" \
            grep -q '^    ' <<<"$out"
        assert "its note names where the worktree is" grep -qF "lists a worktree in it, at ~/${entry#"$HOME/"}/x/y." <<<"$out"
        assert "following the notes and pruning every repo settles" settle
        assert "the worktree stays where git lists it" is_worktree "$entry/x/y"
        assert "the commit only its HEAD reflog held survives" reachable "$lost"
    done
}

test_notes_when_a_worktree_list_fails() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed entry centry lost out
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    centry=$(trash_of "$c")
    mv "$entry.meta" "$entry.meta.tmp"
    git -C "$WS_PROJECTS/alpha" worktree move "$centry" "$c"
    fake_git 'if [[ " $* " == *" worktree list "* ]]; then echo "fatal: simulated" >&2; exit 128; fi'
    out=$(notes)
    rm "$FX/bin/git"
    refute "no note prints a step while git worktree list fails" grep -q '^    ' <<<"$out"
    assert "the notes say ws cannot read the worktree list" \
        grep -q "ws cannot read the worktree list of ~/projects/alpha" <<<"$out"
    refute "they never say git does not list a worktree" grep -q "does not list" <<<"$out"
    assert "an entry whose repo cannot list its worktrees says why it stays" \
        grep -q "^Kept ~/.*-t1/beta: ws cannot read the worktree list of .*~/projects/beta" <<<"$out"
    assert "the record of a worktree out of the trash stays" test -f "$centry.meta"
    assert "following the notes and pruning settles once the list works" settle
    assert "the worktree is out of the trash" is_worktree "$m"
    assert "the commit only its HEAD reflog held survives" reachable "$lost"
    assert "nothing of it stays in the trash" nothing_in_trash alpha-merged
}

test_notes_follow_a_main_checkout_with_odd_paths() {
    local name m entry lost
    for name in 'al pha' $'al\npha'; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        lost=$(head_only_commit "$m" l1)
        ws prune --apply <<<y >/dev/null 2>&1
        entry=$(trash_of "$m")
        mv "$WS_PROJECTS/alpha" "$WS_PROJECTS/$name"
        assert "following the notes and pruning settles after the main checkout moves to $(printf %q "$name")" settle
        assert "the entry keeps its files" test -f "$entry/work.txt"
        assert "the commit only its HEAD reflog held survives" reachable "$lost"
    done
}

test_one_step_per_worktree() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    git -C "$WS_PROJECTS/alpha" worktree move "$entry" "$entry.purging"
    mkdir "$entry"
    echo made by another process >"$entry/blocker.txt"
    out=$(ws prune --restore nothing-like-this 2>&1)
    assert_eq "a worktree at the .purging name of an entry another process took gets one move" 1 \
        "$(grep -c ' worktree move ' <<<"$out")"
    assert "following the notes and pruning settles" settle
    assert "the worktree is out of the trash" is_worktree "$m"
    assert "the other process's file stays" test -f "$entry/blocker.txt"
}

test_record_follows_a_repaired_repo() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    mv "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-moved"
    git -C "$WS_PROJECTS/alpha-moved" worktree repair >/dev/null 2>&1
    out=$(ws prune --restore nothing-like-this 2>&1)
    assert "ws says the record names the repo git now lists the worktree in" \
        grep -q "^Record ~/.*-alpha-merged.meta now names ~/projects/alpha-moved" <<<"$out"
    assert_eq "the record holds that repo" "$WS_PROJECTS/alpha-moved/.git" "$(sed -n 's/^common=//p' "$entry.meta")"
    ws prune --restore alpha-merged >/dev/null 2>&1
    assert "the entry restores from there" is_worktree "$m"
    refute "and leaves no record" test -e "$entry.meta"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    ws prune --apply <<<y >/dev/null 2>&1
    mv "$WS_PROJECTS/alpha" "$WS_PROJECTS/al"$'\n'"pha"
    git -C "$WS_PROJECTS/al"$'\n'"pha" worktree repair >/dev/null 2>&1
    ws prune --restore nothing-like-this >/dev/null 2>&1
    ws prune --restore alpha-merged >/dev/null 2>&1
    assert "an entry whose repo moved to a path with a newline still restores" is_worktree "$m"
}

test_record_of_a_gone_worktree_stays() {
    new_fixture
    local c=$WS_PROJECTS/alpha-closed entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$c")
    git -C "$WS_PROJECTS/alpha" worktree move "$entry" "$c"
    rm -r "$c"
    out=$(notes)
    assert "a record whose worktree git lists at a path that is gone is listed" \
        grep -q "lists its worktree at ~/projects/alpha-closed, which holds no .git file" <<<"$out"
    refute "it is never deleted" grep -q "rm -- .*alpha-closed.meta" <<<"$out"
}

test_purging_dir_in_a_ticket_is_no_ticket_file() {
    new_fixture
    local t=$WS_ROOT/t8 tdir
    two_worktree_ticket "$t"
    tdir=$(trash_of "$t/alpha")
    tdir=${tdir%/*}
    mv "$tdir/beta" "$tdir/beta.purging"
    rm "$tdir/beta.purging/.git" "$tdir/beta.meta"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert "purge deletes the other worktree of the ticket" test ! -e "$tdir/alpha"
    assert "a .purging dir left in the ticket dir stays in place" test -f "$tdir/beta.purging/feat-t8b.txt"
    assert "the ticket's files stay with it" test -f "$tdir/CLAUDE.md"
}

test_dead_runs_leave_no_temp_dirs() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged lost real left
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    real=$(PATH=$_base_path command -v ln)
    printf '#!/usr/bin/env bash\nif [[ ${*: -1} == *.bundle ]]; then\n    %q "$@"\n    kill -KILL "$(ps -o ppid= -p "$PPID")" "$PPID"\n    exit 1\nfi\nexec %q "$@"\n' \
        "$real" "$real" >"$FX/bin/ln"
    chmod +x "$FX/bin/ln"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/ln"
    left=$(compgen -G "$(trash_dir)/.tmp.*")
    assert "a purge killed while it saves a bundle leaves its temp dir" test -n "$left"
    mkdir "$(trash_dir)/.tmp.$$.keepme"
    ws prune --restore nothing-like-this >/dev/null 2>&1
    refute "the next run removes the temp dir of the dead run" test -e "$left"
    assert "it keeps the temp dir of a run that still runs" test -d "$(trash_dir)/.tmp.$$.keepme"
    assert "the commit only its HEAD reflog held survives" reachable "$lost"
}

test_bundle_link_never_replaces_a_file() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry lost real bundle
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    bundle=$(trash_dir)/archive/${entry##*/}.bundle
    real=$(PATH=$_base_path command -v ln)
    printf '#!/usr/bin/env bash\n[[ ${*: -1} != *.bundle ]] || echo someone-elses >"${*: -1}"\nexec %q "$@"\n' "$real" \
        >"$FX/bin/ln"
    chmod +x "$FX/bin/ln"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/ln"
    assert_eq "a file that appears at the bundle path just before the link stays as it was" someone-elses \
        "$(<"$bundle")"
    assert "the entry stays" is_worktree "$entry"
    assert "the commit only its HEAD reflog held survives" reachable "$lost"
}

wrap_engine() {
    mkdir -p "$FX/wrap"
    printf '#!/usr/bin/env bash\n%s\nexec %q "$@"\n' "$2" "$FX/bin/$1" >"$FX/wrap/$1"
    chmod +x "$FX/wrap/$1"
}

test_inspect_accounts_for_every_container() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    add_container docker web bind "$m"
    add_container docker other bind "$FX/elsewhere"
    wrap_engine docker "[[ \$1 != inspect ]] || exec $(printf %q "$FX/bin/docker") inspect id-other"
    out=$(PATH=$FX/wrap:$PATH ws prune --apply <<<y 2>/dev/null)
    assert_eq "inspect that exits 0 without one container ps listed is an error" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
    assert "the row names that container" grep -q "docker inspect did not answer for container id-web" \
        <<<"$(detail_of "$out" "$m")"
    assert "the worktree stays in place" is_worktree "$m"

    rm -r "$FX/wrap"
    echo id-gone >"$FX/docker.gone"
    wrap_engine docker "if [[ \$1 == inspect ]]; then $(printf %q "$FX/bin/docker") \"\$@\"; rc=\$?; echo 'Error: permission denied' >&2; exit \$rc; fi"
    out=$(PATH=$FX/wrap:$PATH ws prune 2>/dev/null)
    assert_eq "an inspect error line next to a gone container is an error" "KEEP unreadable" "$(action_of "$out" "$m")"
    assert "the row names that line" grep -q "docker inspect failed: Error: permission denied" \
        <<<"$(detail_of "$out" "$m")"
}

test_engine_exit_codes() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out err
    add_container docker web bind "$m"
    wrap_engine docker '[[ $1 != ps ]] || exit 1'
    out=$(PATH=$FX/wrap:$PATH ws prune 2>/dev/null)
    assert_eq "an engine that fails with no message is an error, not a stopped daemon" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
    assert "the row names the exit code" grep -q "docker ps failed: exit code 1" <<<"$(detail_of "$out" "$m")"

    wrap_engine docker '[[ $1 != ps ]] || kill -KILL $$'
    out=$(PATH=$FX/wrap:$PATH ws prune 2>/dev/null)
    assert_eq "an engine killed at once is an error" "KEEP unreadable" "$(action_of "$out" "$m")"
    assert "it is no timeout" grep -q "docker ps failed: exit code 137" <<<"$(detail_of "$out" "$m")"

    wrap_engine docker 'if [[ $1 == ps ]]; then echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2; kill -KILL $$; fi'
    out=$(PATH=$FX/wrap:$PATH ws prune 2>/dev/null)
    assert_eq "an engine killed after it says the daemon is down is an error" "KEEP unreadable" "$(action_of "$out" "$m")"

    rm -r "$FX/wrap"
    printf '#!/usr/bin/env bash\n[[ " $* " != *" inspect "* ]] || kill -KILL $$\nexec %q "$@"\n' \
        "$(PATH=$_base_path command -v timeout)" >"$FX/bin/timeout"
    chmod +x "$FX/bin/timeout"
    out=$(ws prune 2>"$FX/err")
    err=$(<"$FX/err")
    rm "$FX/bin/timeout"
    assert_eq "an inspect killed by a signal is an error" "KEEP unreadable" "$(action_of "$out" "$m")"
    refute "bash prints no job notice for it" grep -q Killed <<<"$err"

    set_containers docker '[{Id: "id-a", Name: "/a", Mounts: [{Type: "bind", Source: "projects/alpha-merged"}]}]'
    out=$(ws prune 2>/dev/null)
    assert "a jq error names its input, not a temp path" grep -q "(at <stdin>:" <<<"$(detail_of "$out" "$m")"
}

test_engine_down_with_other_runtimes() {
    local runtime m out
    for runtime in crun runc runsc-sandbox conmon-rs; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" \
            >"$FX/docker.err"
        fake_proc 600 1 "" "" "$runtime"
        out=$(ws prune 2>/dev/null)
        assert_eq "a stopped daemon with $runtime still running makes the worktree KEEP unreadable" "KEEP unreadable" \
            "$(action_of "$out" "$m")"
    done
}

test_process_status_must_be_read() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out real
    fake_proc 240 1 "$FX"
    fake_proc 250 240 "$FX"
    fake_proc 300 250
    chmod 000 "$WS_PROC/300/status"
    out=$(ws prune 2>/dev/null)
    assert_eq "a process of ours whose status file ws cannot read hides its directory" "KEEP unreadable" \
        "$(action_of "$out" "$m")"
    assert "the row names that process" grep -q "process 300 " <<<"$(detail_of "$out" "$m")"
    chmod 644 "$WS_PROC/300/status"

    real=$(PATH=$_base_path command -v awk)
    printf '#!/usr/bin/env bash\nif [[ " $* " == *" me="* ]]; then cat >/dev/null; exit 0; fi\nexec %q "$@"\n' "$real" \
        >"$FX/bin/awk"
    chmod +x "$FX/bin/awk"
    out=$(ws prune 2>/dev/null)
    assert_eq "an awk that exits 0 with no output makes every worktree KEEP unreadable" \
        "REMOVE 0  KEEP 9 (unreadable 9)" "$(tail -n 1 <<<"$out")"
    printf '#!/usr/bin/env bash\nif [[ " $* " == *" me="* ]]; then %q "$@" | head -c 3; exit 0; fi\nexec %q "$@"\n' \
        "$real" "$real" >"$FX/bin/awk"
    out=$(ws prune 2>/dev/null)
    rm "$FX/bin/awk"
    assert_eq "an awk whose output is cut makes every worktree KEEP unreadable" \
        "REMOVE 0  KEEP 9 (unreadable 9)" "$(tail -n 1 <<<"$out")"
}

test_zombie_rows_name_the_parent() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    fake_proc 240 1 "$FX"
    fake_proc 650 240 "$FX" "" bash
    fake_zombie 700 650 sh
    out=$(ws prune 2>/dev/null)
    assert_eq "a zombie of ours makes the worktree KEEP unreadable" "KEEP unreadable" "$(action_of "$out" "$m")"
    assert_eq "the row says whose zombie it is" "process 700 (sh) is a zombie child of process 650 (bash)" \
        "$(detail_of "$out" "$m")"
    rm -r "$WS_PROC/700"
    fake_zombie 710 999 sh
    out=$(ws prune 2>/dev/null)
    assert_eq "a zombie whose parent is gone says so" "process 710 (sh) is a zombie child of process 999 (parent gone)" \
        "$(detail_of "$out" "$m")"
}

test_notes_ask_the_recorded_repo_first() {
    new_fixture
    local g=$FX/outside/gamma t=$WS_ROOT/t9 entry out
    git clone -q https://github.com/fixture/alpha.git "$g" || abort "cannot clone gamma"
    mkdir -p "$t"
    git -C "$g" worktree add -q -b feat/t9g "$t/gamma" || abort "cannot add a worktree of gamma"
    commit_file "$t/gamma" g.txt gamma
    git -C "$t/gamma" push -q -u origin feat/t9g || abort "cannot push feat/t9g"
    add_pr alpha feat/t9g MERGED 90 "$(head_of "$t/gamma")"
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$t/gamma")
    mv "$entry.meta" "$entry.meta.tmp"
    out=$(notes)
    assert "the note moves the worktree from the repo its record names, outside WS_PROJECTS" \
        grep -qF "git -C $(printf %q "$g") worktree move $(printf %q "$entry")" <<<"$out"
    assert "following the notes settles" settle
    assert "the worktree is back in its ticket" is_worktree "$t/gamma"
}

test_notes_keep_a_dir_with_two_worktrees() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed entry centry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    centry=$(trash_of "$c")
    git -C "$WS_PROJECTS/alpha" worktree move "$entry" "$FX/aside"
    mkdir "$entry"
    git -C "$WS_PROJECTS/alpha" worktree move "$FX/aside" "$entry/a"
    git -C "$WS_PROJECTS/alpha" worktree move "$centry" "$entry/b"
    out=$(ws prune --restore nothing-like-this 2>&1)
    assert "an entry that holds two worktrees names both" \
        grep -qF "lists a worktree in it, at ~/${entry#"$HOME/"}/a, and ~/projects/alpha lists a worktree in it, at ~/${entry#"$HOME/"}/b." \
        <<<"$out"
    refute "and prints no move for either" grep -q " worktree move .*${entry##*/}/[ab] " <<<"$out"
    assert "following the notes and pruning settles" settle
    assert "the first worktree stays where it is" is_worktree "$entry/a"
    assert "the second too" is_worktree "$entry/b"
}

test_notes_ask_every_repo() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry lost out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    cp -a "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-b"
    git -C "$WS_PROJECTS/alpha-b" worktree repair "$entry" >/dev/null 2>&1
    lost=$(head_only_commit "$entry" l1)
    mv "$WS_PROJECTS/alpha-b" "$WS_PROJECTS/alpha-c"
    out=$(notes)
    assert "an entry that the repo in its record and a copy both list names both" \
        grep -qF ". ~/projects/alpha lists it, and ~/projects/alpha-c lists it" <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the entry keeps its files" test -f "$entry/work.txt"
    assert "the commit only the copy's reflog holds survives" reachable "$lost"
}

test_notes_never_repair() {
    new_fixture
    local a=$WS_PROJECTS/alpha x=$WS_ROOT/t2/wt m=$WS_PROJECTS/alpha-merged lost xl out
    git -C "$a" worktree add -q --detach "$x" || abort "cannot add a worktree"
    rm -rf "$x"
    git -C "$WS_PROJECTS/beta" worktree add -q -b bx "$x" || abort "cannot add a worktree of beta"
    echo wip >"$x/wip.txt"
    xl=$(head_only_commit "$x" xl)
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    mv "$a" "$WS_PROJECTS/alpha-moved"
    out=$(notes)
    refute "no note prints git worktree repair" grep -q 'worktree repair' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert_eq "a live worktree of another repo at a path the moved repo once used stays that repo's" \
        "$WS_PROJECTS/beta/.git" "$(git -C "$x" rev-parse --path-format=absolute --git-common-dir)"
    assert "its untracked file stays" test -f "$x/wip.txt"
    assert "the commit only its HEAD reflog holds survives" reachable "$xl"
    assert "the commit only the trashed worktree's reflog holds survives" reachable "$lost"

    new_fixture
    a=$WS_PROJECTS/alpha
    local t=$WS_ROOT/t1/alpha lnew
    ws prune --apply <<<y >/dev/null 2>&1
    mv "$a" "$WS_PROJECTS/alpha-old"
    git clone -q https://github.com/fixture/alpha.git "$a" || abort "cannot clone alpha"
    rm -rf "$t"
    git -C "$a" worktree add -q "$t" feat/ticket 2>/dev/null || abort "cannot add a ticket worktree"
    lnew=$(head_only_commit "$t" lnew)
    sed -i '/^alpha\tfeat\/ticket\tOPEN/d' "$FX/prs.tsv"
    add_pr alpha feat/ticket MERGED 70 "$(head_of "$t")"
    out=$(notes)
    refute "after a reclone, no note prints git worktree repair" grep -q 'worktree repair' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert_eq "a new ticket worktree at the old ticket path stays the fresh clone's" "$a/.git" \
        "$(git -C "$t" rev-parse --path-format=absolute --git-common-dir)"
    ws prune --apply <<<y >/dev/null 2>&1
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert "apply, purge, and pruning every repo settle" settle
    assert "the commit only its HEAD reflog held survives them" reachable "$lnew"
}

test_notes_refuse_a_symlinked_git() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged live=$WS_PROJECTS/beta-live entry out
    git -C "$WS_PROJECTS/beta" worktree add -q -b blive "$live" || abort "cannot add a worktree of beta"
    echo live >"$live/live.txt"
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    rm "$entry/.git"
    ln -s "$live/.git" "$entry/.git"
    out=$(notes)
    assert "the note says the entry's .git is a symlink" grep -q "its .git is a symlink" <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert_eq "the worktree the symlink points at stays its repo's" "$WS_PROJECTS/beta/.git" \
        "$(git -C "$live" rev-parse --path-format=absolute --git-common-dir)"
    assert_eq "on its own branch" blive "$(git -C "$live" symbolic-ref --short HEAD)"
    assert_eq "with only its untracked file" "?? live.txt" "$(git -C "$live" status --short)"
    assert "the entry keeps its files" test -f "$entry/work.txt"
}

test_notes_on_dirs_without_a_record() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged a=$WS_PROJECTS/alpha entry lost out wrap
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    git -C "$a" worktree move "$entry" "$entry.old"
    mkdir "$entry"
    echo other >"$entry/other.txt"
    git -C "$a" worktree move "$entry.old" "$entry/alpha-merged"
    rm "$entry.meta"
    out=$(notes)
    assert "a dir with no record names the worktree git lists in it" \
        grep -qF "record. ~/projects/alpha lists a worktree in it, at ~/${entry#"$HOME/"}/alpha-merged." <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the worktree stays where git lists it" is_worktree "$entry/alpha-merged"
    refute "no ticket dir appears for it" test -e "$WS_ROOT/alpha-merged"
    assert "the other file stays" test -f "$entry/other.txt"
    assert "the commit only its HEAD reflog holds survives" reachable "$lost"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    wrap=$(trash_dir)/20200101T000000Z-alpha-wrap
    mkdir -p "$(trash_dir)/20200101T000000Z-alpha-old" "$wrap/a/b/c"
    echo notes >"$(trash_dir)/20200101T000000Z-alpha-old/notes.txt"
    git -C "$WS_PROJECTS/alpha" worktree move "$entry" "$wrap/a/b/c/wt"
    rm "$entry.meta"
    out=$(notes)
    assert "a dir with files and no record says so" \
        grep -q "^Kept ~/.*-alpha-old: it holds no record. No repo lists a worktree in it. ws keeps what it holds.$" \
        <<<"$out"
    assert "a dir with no record names a worktree four levels down in it" \
        grep -qF "lists a worktree in it, at ~/${wrap#"$HOME/"}/a/b/c/wt." <<<"$out"
    refute "no note prints a step" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the file stays" test -f "$(trash_dir)/20200101T000000Z-alpha-old/notes.txt"
    assert "the worktree stays where git lists it" is_worktree "$wrap/a/b/c/wt"
    assert "the commit only its HEAD reflog holds survives" reachable "$lost"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    fake_git 'if [[ $2 == worktree && $3 == move && $5 == *-alpha-merged ]]; then
    mkdir -p "$5/logs"
    echo log >"$5/logs/x.log"
fi'
    ws prune --apply <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    entry=$(compgen -G "$(trash_dir)/*-alpha-merged")
    out=$(notes)
    assert "a dir another process made at a trash path says it holds no record" \
        grep -q "^Kept ~/.*-alpha-merged: it holds no record" <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the other process's file stays where it put it" test -f "$entry/logs/x.log"
    assert "the worktree is where it was" is_worktree "$m"
}

test_notes_list_a_worktree_through_a_symlink() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry admin out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    ln -s "$XDG_DATA_HOME" "$FX/datalink"
    admin=$(sed 's/^gitdir: //' "$entry/.git")
    printf '%s\n' "$FX/datalink/ws/trash/${entry##*/}/.git" >"$admin/gitdir"
    out=$(notes)
    refute "an entry git lists through a symlinked path gets no note" grep -qF "${entry##*/}" <<<"$out"
    ws prune --restore alpha-merged >/dev/null 2>&1
    assert "it restores" is_worktree "$m"
}

test_notes_on_a_worktree_deep_in_an_entry() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged a=$WS_PROJECTS/alpha entry lost out
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    git -C "$a" worktree move "$entry" "$entry.old"
    mkdir -p "$entry/a/b"
    git -C "$a" worktree move "$entry.old" "$entry/a/b/c"
    out=$(notes)
    assert "the note names the worktree git lists in the entry" \
        grep -qF "lists a worktree in it, at ~/${entry#"$HOME/"}/a/b/c." <<<"$out"
    refute "it never says the entry holds no worktree" grep -qi "holds no worktree" <<<"$out"
    refute "it prints no step" grep -q '^    ' <<<"$out"
    assert "following the notes and pruning every repo settles" settle
    assert "the worktree stays where git lists it" is_worktree "$entry/a/b/c"
    assert "the commit only its HEAD reflog holds survives" reachable "$lost"
}

deep_ticket() {
    git -C "$WS_PROJECTS/alpha" worktree remove --force "$WS_ROOT/t1/alpha" || abort "cannot remove t1/alpha"
    mkdir -p "$WS_ROOT/t1/notes"
    echo note >"$WS_ROOT/t1/notes/n.md"
}

test_ticket_files_are_decided_by_git() {
    local rel t n lost out
    for rel in a/b/wt a/b/c/d/wt; do
        new_fixture
        t=$WS_ROOT/t1
        deep_ticket
        n=$t/notes/$rel
        mkdir -p "${n%/*}"
        git -C "$WS_PROJECTS/alpha" worktree add -q --detach "$n" || abort "cannot add $n"
        echo wip >"$n/wip.txt"
        lost=$(lost_commit "$n" l1)
        out=$(ws prune --apply <<<y 2>&1)
        assert "apply names the worktree at notes/$rel that keeps the ticket" \
            grep -qF "Kept ticket ~/work/t1: ~/projects/alpha lists a worktree in it, at ~/work/t1/notes/$rel" <<<"$out"
        assert "the worktree stays in place" is_worktree "$n"
        assert "with its untracked file" test -f "$n/wip.txt"
        assert "the ticket's file stays" test -f "$t/notes/n.md"
        ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
        assert "following the notes and pruning every repo settles" settle
        assert "the worktree is still in place after a purge" is_worktree "$n"
        assert "the commit only its HEAD reflog holds survives" reachable "$lost"
    done

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    git clone -q --bare "$FX/origins/alpha.git" "$WS_PROJECTS/gamma.git" || abort "cannot clone gamma"
    git --git-dir="$WS_PROJECTS/gamma.git" worktree add -q --detach "$t/notes/a/b/wt" || abort "cannot add a worktree"
    out=$(ws prune --apply <<<y 2>&1)
    assert "a worktree of a bare repo in WS_PROJECTS keeps the ticket" \
        grep -qF "Kept ticket ~/work/t1: ~/projects/gamma.git lists a worktree in it" <<<"$out"

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    { mkdir -p "$FX/sep" && git clone -q --separate-git-dir="$FX/sep/delta.git" "$FX/origins/alpha.git" "$WS_PROJECTS/delta"; } ||
        abort "cannot clone delta"
    git -C "$WS_PROJECTS/delta" worktree add -q --detach "$t/notes/a/b/c/wt" || abort "cannot add a worktree"
    out=$(ws prune --apply <<<y 2>&1)
    assert "a worktree of a main checkout with a .git file keeps the ticket" \
        grep -qF "Kept ticket ~/work/t1: ~/sep/delta.git lists a worktree in it" <<<"$out"

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    git init -q "$WS_PROJECTS/zeta" || abort "cannot make zeta"
    fake_git "if [[ \$1 == --git-dir=$(printf %q "$WS_PROJECTS/zeta/.git") && \" \$* \" == *\" worktree list \"* ]]; then exit 128; fi"
    out=$(ws prune --apply <<<y 2>&1)
    rm "$FX/bin/git"
    assert "a repo whose worktree list fails keeps every worktree" \
        grep -qF "Skipped ~/work/t1/beta: ws cannot read the worktree list of ~/projects/zeta" <<<"$out"
    assert "with the ticket's files" test -f "$t/notes/n.md"

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    git clone -q https://github.com/fixture/alpha.git "$t/clone" || abort "cannot clone into the ticket"
    out=$(ws prune --apply <<<y 2>&1)
    assert "a clone in the ticket dir keeps it" \
        grep -qxF "Kept ticket ~/work/t1: it holds a repository at ~/work/t1/clone" <<<"$out"
    assert "the clone stays" test -d "$t/clone/.git"

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    fake_proc 100 1 "$t/notes"
    out=$(ws prune --apply <<<y 2>&1)
    assert "a process that works in the ticket dir keeps it" \
        grep -qF "Kept ticket ~/work/t1: a process works in it" <<<"$out"
    rm -r "$WS_PROC/100"
    add_container docker web bind "$t/notes"
    merged_worktree "$t/alpha2" feat/t1c 51
    out=$(ws prune --apply <<<y 2>&1)
    assert "a container that mounts a dir in the ticket keeps it" \
        grep -qF "Kept ticket ~/work/t1: docker container web mounts it" <<<"$out"
    assert "with its files" test -f "$t/notes/n.md"

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    git clone -q https://github.com/fixture/alpha.git "$FX/outside/gamma" || abort "cannot clone gamma"
    { git -C "$FX/outside/gamma" worktree add -q --detach "$WS_PROJECTS/gamma-wt" &&
        git -C "$FX/outside/gamma" worktree add -q --detach "$t/notes/a/b/wt"; } || abort "cannot add worktrees of gamma"
    out=$(ws prune --apply <<<y 2>&1)
    assert "a worktree of a repo outside WS_PROJECTS that the scan found keeps the ticket" \
        grep -qF "Kept ticket ~/work/t1: ~/outside/gamma lists a worktree in it" <<<"$out"
}

test_worktree_lists_time_out() {
    new_fixture
    local z=$WS_PROJECTS/zeta m=$WS_PROJECTS/alpha-merged rt out rc i
    { git init -q "$z" && git -C "$z" commit -q --allow-empty -m z &&
        git -C "$z" worktree add -q --detach "$FX/zw" && git -C "$z" worktree add -q --detach "$WS_PROJECTS/zeta-wt"; } ||
        abort "cannot make zeta"
    ws prune --apply <<<y >/dev/null 2>&1
    rm "$z/.git/worktrees/zw/gitdir"
    mkfifo "$z/.git/worktrees/zw/gitdir"
    rt=$(PATH=$_base_path command -v timeout)
    printf '#!/usr/bin/env bash\nif [[ $1 == -k && " $* " == *" worktree list "* ]]; then exec %q -k 1 1 "${@:4}"; fi\nexec %q "$@"\n' \
        "$rt" "$rt" >"$FX/bin/timeout"
    chmod +x "$FX/bin/timeout"
    ws_guard
    out=$("$rt" 60 bash "$WS_BIN" prune --restore nothing-like-this 2>&1)
    rc=$?
    assert "restore finishes while a worktree list never answers" test "$rc" != 124
    assert "its notes name that repo" grep -q "cannot read the worktree list of ~/projects/zeta" <<<"$out"
    refute "and print no step" grep -q '^    ' <<<"$out"
    out=$("$rt" 60 bash "$WS_BIN" prune --purge --older-than 0d <<<y 2>&1)
    rc=$?
    assert "purge finishes too" test "$rc" != 124
    assert "it keeps the entry" in_trash "$m"
    out=$("$rt" 60 bash "$WS_BIN" prune 2>&1)
    rc=$?
    assert "the scan finishes too" test "$rc" != 124
    assert_eq "a worktree of that repo is KEEP unreadable" "KEEP unreadable" "$(action_of "$out" "$WS_PROJECTS/zeta-wt")"
    for i in 1 2 3; do
        "$rt" 2 bash -c ': >"$1"' _ "$z/.git/worktrees/zw/gitdir" 2>/dev/null
    done
    rm "$FX/bin/timeout"
}

test_temp_dirs_of_other_runs() {
    new_fixture
    local ns dead m=$WS_PROJECTS/alpha-merged lost pid
    ws prune --apply <<<y >/dev/null 2>&1
    ns=$(readlink /proc/self/ns/pid)
    ns=${ns#pid:[}
    ns=${ns%]}
    true &
    dead=$!
    wait "$dead"
    mkdir -p "$(trash_dir)/.tmp.abc123" "$(trash_dir)/.tmp.1.$ns.abcdef" "$(trash_dir)/.tmp.$dead.$ns.ghijkl" \
        "$(trash_dir)/.tmp.$dead.1.mnopqr"
    ws prune --restore nothing-like-this >/dev/null 2>&1
    assert "a temp dir whose name holds no pid stays" test -d "$(trash_dir)/.tmp.abc123"
    assert "a temp dir of process 1, which runs, stays" test -d "$(trash_dir)/.tmp.1.$ns.abcdef"
    refute "a temp dir of a run of this pid namespace that died is removed" test -e "$(trash_dir)/.tmp.$dead.$ns.ghijkl"
    assert "a temp dir of another pid namespace stays" test -d "$(trash_dir)/.tmp.$dead.1.mnopqr"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    lost=$(head_only_commit "$m" l1)
    ws prune --apply <<<y >/dev/null 2>&1
    mkfifo "$FX/go"
    fake_git "if [[ \" \$* \" == *\" bundle create \"* ]]; then echo x >$(printf %q "$FX/started"); read -r _ <$(printf %q "$FX/go"); fi"
    ws prune --purge --older-than 0d <<<y >"$FX/purge.out" 2>&1 &
    pid=$!
    wait_for "$FX/started" x || abort "the purge never reached its bundle"
    ws_guard
    unshare -Upf --mount-proc bash "$WS_BIN" prune --restore nothing-like-this >"$FX/other.out" 2>&1
    echo go >"$FX/go"
    wait "$pid"
    rm "$FX/bin/git"
    refute "a ws run in another pid namespace removes no temp dir of a run that still runs" \
        grep -q "^Removed " "$FX/other.out"
    assert "the purge saves the commit only its reflog held" grep -q "^Saved 1 commit" "$FX/purge.out"
    assert "which stays reachable" reachable "$lost"
}

test_record_updates() {
    new_fixture
    local b=$WS_ROOT/t1/beta m=$WS_PROJECTS/alpha-merged entry real out fd old
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$b")
    mv "$WS_PROJECTS/beta" "$WS_PROJECTS/beta-moved"
    git -C "$WS_PROJECTS/beta-moved" worktree repair "$entry" >/dev/null 2>&1
    real=$(PATH=$_base_path command -v awk)
    printf '#!/usr/bin/env bash\nif [[ $* == *"index(\\$0, key) != 1"* ]]; then %q "$@"; kill -KILL "$PPID"; exit 1; fi\nexec %q "$@"\n' \
        "$real" "$real" >"$FX/bin/awk"
    chmod +x "$FX/bin/awk"
    ws prune --restore nothing-like-this >/dev/null 2>&1
    rm "$FX/bin/awk"
    out=$(ws prune --restore nothing-like-this 2>&1)
    assert "the next run removes what a killed record update left" grep -q "^Removed ~/.*/\.tmp\." <<<"$out"
    refute "it leaves no file next to the record" compgen -G "$entry.meta?*"
    ws prune --restore t1 >/dev/null 2>&1
    assert "restore puts the worktree back" is_worktree "$b"
    assert_eq "and moves no stray file into the ticket" "alpha beta" "$(cd "$WS_ROOT/t1" && echo *)"

    entry=$(trash_of "$m")
    mv "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-moved"
    git -C "$WS_PROJECTS/alpha-moved" worktree repair "$entry" >/dev/null 2>&1
    exec {fd}<"$entry.meta"
    ws prune --restore nothing-like-this >/dev/null 2>&1
    old=$(cat <&"$fd")
    exec {fd}<&-
    assert "a reader that opened the record before an update reads the old record whole" \
        grep -qx "common=$WS_PROJECTS/alpha/.git" <<<"$old"
    assert "the record names the repo that lists the worktree now" \
        grep -qx "common=$WS_PROJECTS/alpha-moved/.git" "$entry.meta"
}

pause_notes_at_record() {
    local real
    mkfifo "$FX/go" || abort "cannot make $FX/go"
    mkdir -p "$FX/wrap"
    real=$(PATH=$_base_path command -v awk)
    printf '#!/usr/bin/env bash\nif [[ $* == *"index(\\$0, key) != 1"* && $* == *-alpha-merged.meta* ]]; then %q "$@"; rc=$?; echo x >%q; read -r _ <%q; exit $rc; fi\nexec %q "$@"\n' \
        "$real" "$FX/waiting" "$FX/go" "$real" >"$FX/wrap/awk"
    chmod +x "$FX/wrap/awk"
    PATH=$FX/wrap:$PATH ws prune --restore nothing-like-this >"$FX/b.out" 2>&1 &
    NOTES_PID=$!
    wait_for "$FX/waiting" x || abort "the notes pass never reached the record"
}

release_notes() {
    echo go >"$FX/go"
    wait "$NOTES_PID"
}

moved_main_checkout() {
    ws prune --apply <<<y >/dev/null 2>&1
    mv "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-moved"
    git -C "$WS_PROJECTS/alpha-moved" worktree repair >/dev/null 2>&1
}

test_notes_never_bring_back_a_purged_record() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry
    moved_main_checkout
    entry=$(trash_of "$m")
    pause_notes_at_record
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    refute "the purge deletes the record" test -e "$entry.meta"
    release_notes
    refute "a notes pass that ran meanwhile leaves it deleted" test -e "$entry.meta"
    refute "and does not say it updated it" grep -q "alpha-merged.meta now names" "$FX/b.out"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    moved_main_checkout
    entry=$(trash_of "$m")
    pause_notes_at_record
    rm "$entry.meta"
    release_notes
    refute "a record deleted while a notes pass reads it stays deleted" test -e "$entry.meta"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    moved_main_checkout
    entry=$(trash_of "$m")
    pause_notes_at_record
    git -C "$WS_PROJECTS/alpha-moved" worktree move "$entry" "$entry.purging"
    release_notes
    assert "a notes pass leaves the record of an entry a purge holds as it was" \
        grep -qx "common=$WS_PROJECTS/alpha/.git" "$entry.meta"
}

test_notes_with_another_unreadable_repo() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry tdir out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    rm "$entry.meta"
    tdir=$(trash_of "$WS_ROOT/t1/beta")
    tdir=${tdir%/*}
    mkdir "$tdir/notes"
    echo note >"$tdir/notes/n.md"
    git init -q "$WS_PROJECTS/zeta" || abort "cannot make zeta"
    fake_git "if [[ \$1 == --git-dir=$(printf %q "$WS_PROJECTS/zeta/.git") && \" \$* \" == *\" worktree list \"* ]]; then exit 128; fi"
    out=$(notes)
    rm "$FX/bin/git"
    assert "an orphan its repo lists, while another repo's list fails, says which list ws cannot read" \
        grep -q "^Orphan ~/.*-alpha-merged has no record.* cannot read the worktree list of ~/projects/zeta" <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
    assert "the entry stays" is_worktree "$entry"
    assert "a dir in a ticket dir counts as no ticket file while a worktree list fails" \
        grep -q "^Orphan ~/.*-t1/notes has no record.* cannot read the worktree list of ~/projects/zeta" <<<"$out"
}

test_notes_check_the_git_file_against_the_listing() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    cp -a "$WS_PROJECTS/alpha" "$WS_PROJECTS/alpha-copy"
    out=$(notes)
    assert "an entry with a sound .git file that two repos list names both" \
        grep -qF ". ~/projects/alpha lists it, and ~/projects/alpha-copy lists it." <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
    out=$(ws prune --restore alpha-merged 2>&1)
    assert "restore refuses it, naming the other repo" grep -q "cannot restore .*~/projects/alpha-copy lists" <<<"$out"
    refute "and leaves it in the trash" test -e "$m"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert "a purge keeps it" is_worktree "$entry"

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    rm "$entry.meta"
    echo "gitdir: $WS_PROJECTS/alpha/.git/worktrees/alpha-closed" >"$entry/.git"
    out=$(notes)
    assert "an orphan whose .git file names the repo's entry for another worktree says so" \
        grep -qF "its .git file points at ~/projects/alpha/.git/worktrees/alpha-closed, which names another path" <<<"$out"
    refute "and prints no step" grep -q '^    ' <<<"$out"
}

test_purge_keeps_ticket_files_that_hold_a_worktree() {
    new_fixture
    local b=$WS_ROOT/t1/beta entry tdir n lost out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$b")
    tdir=${entry%/*}
    n=$tdir/notes/a/b/c/wt
    mkdir -p "${n%/*}"
    git -C "$WS_PROJECTS/alpha" worktree add -q --detach "$n" || abort "cannot add $n"
    lost=$(lost_commit "$n" l1)
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "purge says why the ticket files stay" \
        grep -qF "Kept ~/${tdir#"$HOME/"}: ~/projects/alpha lists a worktree in it, at ~/${n#"$HOME/"}" <<<"$out"
    assert "the worktree stays where git lists it" is_worktree "$n"
    assert "following the notes and pruning every repo settles" settle
    assert "the commit only its HEAD reflog holds survives" reachable "$lost"
}

test_notes_ask_a_separate_gitdir_repo() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged a=$WS_PROJECTS/alpha entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    rm "$entry.meta"
    mkdir -p "$FX/sep"
    mv "$a/.git" "$FX/sep/alpha.git"
    printf 'gitdir: %s\n' "$FX/sep/alpha.git" >"$a/.git"
    out=$(notes)
    assert "a main checkout whose .git is a file is asked, and its repo named" \
        grep -qF "came from ~/projects/alpha-merged. ~/sep/alpha.git lists it." <<<"$out"
    refute "the note prints no step" grep -q '^    ' <<<"$out"
}

test_entry_that_is_a_symlink() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    git -C "$entry" worktree move "$entry" "$FX/real"
    ln -s "$FX/real" "$entry"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "purge says it keeps an entry that is a symlink" grep -q "^Kept ~/.*-alpha-merged: it is a symlink" <<<"$out"
    assert "the worktree the symlink points at stays" is_worktree "$FX/real"
    assert "with its files" test -f "$FX/real/work.txt"
}

test_entry_whose_git_is_a_symlink() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    mv "$entry/.git" "$FX/gitfile"
    ln -s "$FX/gitfile" "$entry/.git"
    out=$(ws prune --restore alpha-merged 2>&1)
    assert "restore refuses an entry whose .git is a symlink" grep -q "cannot restore .*: its .git is a symlink" <<<"$out"
    refute "the worktree does not move" test -e "$m"
    assert "the entry keeps its files" test -f "$entry/work.txt"
}

test_record_of_a_worktree_listed_at_its_purging_path() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged entry out
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$m")
    git -C "$entry" worktree move "$entry" "$entry.purging"
    mv "$entry.purging" "$FX/hidden"
    out=$(notes)
    assert "a record whose worktree git lists at its .purging path says so" \
        grep -qF "lists its worktree at ~/${entry#"$HOME/"}.purging, so ws keeps the record" <<<"$out"
    refute "it is never deleted" grep -q "rm -- .*alpha-merged.meta" <<<"$out"
}

test_inspect_fails_with_no_message() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged out
    add_container docker web bind "$FX/elsewhere"
    wrap_engine docker "if [[ \$1 == inspect ]]; then $(printf %q "$FX/bin/docker") \"\$@\"; exit 1; fi"
    out=$(PATH=$FX/wrap:$PATH ws prune 2>/dev/null)
    assert_eq "an inspect that exits 1 with no message is an error" "KEEP unreadable" "$(action_of "$out" "$m")"
    assert "the row names the exit code" grep -q "docker inspect failed: exit code 1" <<<"$(detail_of "$out" "$m")"
}

test_shim_namespace_flags() {
    local flags m out
    local -a args=()
    for flags in "-namespace moby -namespace k8s.io" "-namespace moby2" "--namespace=moby2"; do
        new_fixture
        m=$WS_PROJECTS/alpha-merged
        read -r -a args <<<"$flags"
        fake_proc 700 1 "" "" containerd-shim-runc-v2
        fake_cmdline 700 /usr/bin/containerd-shim-runc-v2 "${args[@]}" -id 4f2a
        fake_proc 701 700
        fake_proc 702 701
        out=$(ws prune 2>/dev/null)
        assert_eq "a process below a shim started with $flags hides its directory" "KEEP unreadable" \
            "$(action_of "$out" "$m")"
    done
}

test_ticket_dirs_ask_every_repo_with_a_git_inside() {
    local variant t z n lost out want
    for variant in nested-projects nested-mirror outside unread gone-repo; do
        new_fixture
        t=$WS_ROOT/t1
        deep_ticket
        z=$WS_PROJECTS/poc/zeta n=$t/notes/zwt
        case $variant in
        nested-mirror) n=$t/poc/zeta ;;
        outside | gone-repo) z=$FX/elsewhere/zeta ;;
        esac
        { git init -q "$z" && git -C "$z" commit -q --allow-empty -m z0 && mkdir -p "${n%/*}" &&
            git -C "$z" worktree add -q --detach "$n" && echo wip >"$n/wip.txt"; } || abort "cannot make zeta"
        lost=$(lost_commit "$n" l1)
        want="Kept ticket ~/work/t1: ~/${z#"$HOME/"} lists a worktree in it, at ~/${n#"$HOME/"}"
        if [[ $variant == gone-repo ]]; then
            rm -rf "$z"
            want="Kept ticket ~/work/t1: it holds ~/${n#"$HOME/"}/.git, and no repo ws can ask lists ~/${n#"$HOME/"}"
        elif [[ $variant == unread ]]; then
            fake_git "if [[ \$1 == --git-dir=$(printf %q "$z/.git") && \" \$* \" == *\" worktree list \"* ]]; then exit 128; fi"
            want="Kept ticket ~/work/t1: ws cannot read the worktree list of ~/${z#"$HOME/"}"
        fi
        out=$(ws prune --apply <<<y 2>&1)
        rm -f "$FX/bin/git"
        assert "apply moves the ticket's merged worktree ($variant)" in_trash "$t/beta"
        assert "apply names what keeps the ticket ($variant)" grep -qxF "$want" <<<"$out"
        assert_eq "apply says once that it keeps the ticket ($variant)" 1 "$(grep -c '^Kept ticket' <<<"$out")"
        assert "the ticket's file stays ($variant)" test -f "$t/notes/n.md"
        assert "the worktree's untracked file stays ($variant)" test -f "$n/wip.txt"
        [[ $variant == gone-repo ]] && continue
        assert "the worktree stays where its repo lists it ($variant)" is_worktree "$n"
        git -C "$z" worktree prune || abort "cannot prune zeta"
        assert "the commit only its HEAD reflog holds survives git worktree prune ($variant)" reachable "$lost" "$z/.git"
    done

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    n=$t/notes/scratch
    git clone -q https://github.com/fixture/alpha.git "$n" || abort "cannot clone into the ticket"
    commit_file "$n" c.txt "unpushed in a plain clone"
    lost=$(head_of "$n")
    out=$(ws prune --apply <<<y 2>&1)
    assert "a plain clone deep in a ticket keeps it" \
        grep -qxF "Kept ticket ~/work/t1: it holds a repository at ~/work/t1/notes/scratch" <<<"$out"
    assert "the clone stays with its unpushed commit" git -C "$n" cat-file -e "$lost"

    new_fixture
    t=$WS_ROOT/t1
    deep_ticket
    { mkdir -p "$t/notes/locked" && chmod 000 "$t/notes/locked"; } || abort "cannot make an unreadable dir"
    out=$(ws prune --apply <<<y 2>&1)
    chmod 755 "$t/notes/locked"
    assert "a ticket ws cannot search for a .git stays" \
        grep -qxF "Kept ticket ~/work/t1: ws cannot search it for a .git" <<<"$out"
    assert "with its files" test -f "$t/notes/n.md"
}

test_apply_skips_a_worktree_another_repo_lists() {
    local variant x branch lost out a old
    for variant in ticket project; do
        new_fixture
        a=$WS_PROJECTS/alpha old=$WS_PROJECTS/alpha-old
        if [[ $variant == ticket ]]; then
            x=$WS_ROOT/t1/alpha branch=feat/ticket
        else
            x=$WS_PROJECTS/alpha-merged branch=feat/merged
        fi
        lost=$(head_only_commit "$x" l1)
        mv "$a" "$old"
        git clone -q https://github.com/fixture/alpha.git "$a" || abort "cannot clone alpha"
        rm -rf "$x"
        git -C "$a" worktree add -q "$x" "$branch" || abort "cannot add $x again"
        if [[ $variant == ticket ]]; then
            sed -i '/^alpha\tfeat\/ticket\tOPEN/d' "$FX/prs.tsv"
            add_pr alpha feat/ticket MERGED 70 "$(head_of "$x")"
        fi
        out=$(ws prune --apply <<<y 2>&1)
        assert "apply skips a worktree two repos list ($variant), naming both" grep -qF \
            "Skipped ~/${x#"$HOME/"}: ~/projects/alpha lists it, and ~/projects/alpha-old lists it too" <<<"$out"
        assert "the worktree stays in place ($variant)" is_worktree "$x"
        { git -C "$a" worktree prune && git -C "$old" worktree prune; } || abort "cannot prune"
        assert "the commit only the old repo's reflog holds survives git worktree prune ($variant)" reachable "$lost"
        assert_eq "apply names the ticket that stays once ($variant)" 1 "$(grep -c '^Kept ticket ~/work/t1:' <<<"$out")"
    done
}

test_one_ticket_line_per_ticket() {
    new_fixture
    local t=$WS_ROOT/t8 out tdir
    mkdir -p "$t"
    add_worktree alpha "$t/alpha" feat/t8a
    add_pr alpha feat/t8a MERGED 700 "$(head_of "$t/alpha")"
    add_worktree beta "$t/beta" feat/t8b
    add_pr beta feat/t8b MERGED 701 "$(head_of "$t/beta")"
    echo notes >"$t/CLAUDE.md"
    out=$(ws prune --apply <<<y 2>&1)
    assert "the first worktree of the ticket moves" in_trash "$t/alpha"
    assert "the second worktree of the ticket moves" in_trash "$t/beta"
    assert_eq "apply says once that the ticket moved" 1 "$(grep -c '^Moved ticket ~/work/t8 ' <<<"$out")"
    refute "and never that it kept it" grep -q '^Kept ticket ~/work/t8:' <<<"$out"
    tdir=$(trash_of "$t/beta")
    assert "the ticket's file moves with it" test -f "${tdir%/*}/CLAUDE.md"
}

test_temp_dirs_of_older_runs() {
    new_fixture
    local tr dead n inner out host=0
    ws prune --apply <<<y >/dev/null 2>&1
    tr=$(trash_dir)
    [[ $(readlink /proc/self/ns/pid) != "pid:[4026531836]" ]] || host=1
    true &
    dead=$!
    wait "$dead"
    for n in "$dead.abcdef" 1.ghijkl abc123; do
        { mkdir -p "$tr/.tmp.$n" && echo partial >"$tr/.tmp.$n/bundle"; } || abort "cannot make .tmp.$n"
    done
    out=$(ws prune --restore nothing-like-this 2>&1)
    if ((host)); then
        refute "a dir of an older run whose pid no process has is removed" test -e "$tr/.tmp.$dead.abcdef"
        assert "and the run says so" grep -qF "Removed ~/.local/share/ws/trash/.tmp.$dead.abcdef" <<<"$out"
    else
        assert "outside the host's pid namespace, a dir of an older run stays" test -d "$tr/.tmp.$dead.abcdef"
    fi
    assert "a dir of an older run whose pid runs stays" test -f "$tr/.tmp.1.ghijkl/bundle"
    assert "and is listed with its path" grep -q "^Kept ~/.local/share/ws/trash/.tmp.1.ghijkl: " <<<"$out"
    assert "a dir whose name holds no pid stays" test -f "$tr/.tmp.abc123/bundle"
    assert "and is listed with its path" grep -q "^Kept ~/.local/share/ws/trash/.tmp.abc123: " <<<"$out"

    mkdir "$tr/.tmp.$dead.mnopqr" || abort "cannot make a temp dir"
    ws_guard
    out=$(unshare -Upf --mount-proc bash "$WS_BIN" prune --restore nothing-like-this 2>&1)
    assert "a ws run in a child pid namespace keeps a dir of an older run" test -d "$tr/.tmp.$dead.mnopqr"
    assert "and lists it" grep -q "^Kept ~/.local/share/ws/trash/.tmp.$dead.mnopqr: " <<<"$out"

    for n in 77777 87777 97777 107777 117777; do
        [[ -e /proc/$n ]] || break
    done
    unshare -Urpf --kill-child --mount-proc bash -c 'echo $(($1 - 1)) >/proc/sys/kernel/ns_last_pid || exit 1
        sleep 60 &
        echo "$!" >"$2"
        wait' _ "$n" "$FX/inner" &
    inner=$!
    wait_for "$FX/inner" "^$n\$" || abort "cannot start a process with pid $n in a child pid namespace"
    mkdir "$tr/.tmp.$n.stuvwx" || abort "cannot make a temp dir"
    out=$(ws prune --restore nothing-like-this 2>&1)
    kill "$inner"
    wait "$inner" 2>/dev/null
    assert "a dir of an older run whose pid runs in a child pid namespace stays" test -d "$tr/.tmp.$n.stuvwx"
    assert "and is listed" grep -q "^Kept ~/.local/share/ws/trash/.tmp.$n.stuvwx: " <<<"$out"
}

run_test test_dry_run
run_test test_help
run_test test_gh_calls
run_test test_gh_parallel
run_test test_apply_yes
run_test test_meta_record
run_test test_apply_no
run_test test_include_detached
run_test test_gh_failure
run_test test_gh_partial_failures
run_test test_gh_bad_output
run_test test_gh_timeout
run_test test_dirty_ignores_user_config
run_test test_hidden_flags
run_test test_ignored_files
run_test test_ignored_dirs
run_test test_regenerable_only_at_the_top
run_test test_odd_worktree_path
run_test test_bare_common
run_test test_records_cannot_be_forged
run_test test_pushed
run_test test_branch_deletion
run_test test_pr_matching
run_test test_pr_window
run_test test_origins
run_test test_non_github_origin
run_test test_recheck_before_move
run_test test_change_after_recheck
run_test test_locked_and_submodules
run_test test_leaves_other_worktree_entries
run_test test_layout
run_test test_restore
run_test test_ticket_moves_with_last_repo
run_test test_purge
run_test test_purge_ticket
run_test test_purge_archives_ticket_files
run_test test_cross_fs
run_test test_trash_location
run_test test_symlinked_trash
run_test test_forged_records
run_test test_restore_trusts_no_ticket_field
run_test test_damaged_records
run_test test_record_age
run_test test_restore_stops_at_a_ticket_file_in_the_way
run_test test_restore_checks_git_first
run_test test_restore_keeps_the_record_when_git_fails
run_test test_concurrent_restore_and_apply
run_test test_restore_one_of_two
run_test test_purge_one_of_two
run_test test_trash_names
run_test test_purge_rechecks_after_the_prompt
run_test test_purge_moves_the_entry_before_it_deletes
run_test test_purge_saves_reflog_commits
run_test test_purge_keeps_entries_it_cannot_bundle
run_test test_purge_ignores_status_config
run_test test_purge_never_nests_the_entry
run_test test_orphans
run_test test_orphan_without_a_record
run_test test_trash_leftovers_are_listed
run_test test_full_trash
run_test test_hidden_cwd
run_test test_vanished_process
run_test test_process_scan_fails_closed
run_test test_containers
run_test test_engine_errors
run_test test_containers_are_checked_before_each_move
run_test test_purge_survives_reflog_step_failures
run_test test_purge_saves_worktree_ref_reflogs
run_test test_moves_land_where_ws_asked
run_test test_partial_remove
run_test test_apply_keeps_the_record_when_git_fails_after_its_move
run_test test_leftover_records
run_test test_orphan_name_with_a_counter
run_test test_purge_keeps_entries_git_cannot_open
run_test test_in_use
run_test test_sourceable
run_test test_fixture_isolation
run_test test_unknown_command
run_test test_engine_down_needs_every_line
run_test test_engine_down_with_running_containers
run_test test_inspect_must_answer_for_every_container
run_test test_container_mount_shapes
run_test test_container_processes
run_test test_purge_checks_the_original_path
run_test test_bundle_path_taken
run_test test_bundle_on_a_full_trash
run_test test_detail_is_decoded
run_test test_empty_ticket_dir_is_listed
run_test test_purge_fails_when_ticket_files_stay
run_test test_wsproc_self_must_be_a_dir
run_test test_notes_follow_a_nested_purge
run_test test_notes_follow_a_moved_main_checkout
run_test test_double_nest_keeps_the_record
run_test test_trash_temp_dirs_are_not_listed
run_test test_ticket_files_never_hold_a_worktree
run_test test_restore_nest_then_kill
run_test test_notes_trust_the_repo_that_lists_the_worktree
run_test test_notes_after_a_reclone
run_test test_notes_with_copies_of_the_main_checkout
run_test test_notes_find_a_worktree_two_levels_down
run_test test_notes_when_a_worktree_list_fails
run_test test_notes_follow_a_main_checkout_with_odd_paths
run_test test_one_step_per_worktree
run_test test_record_follows_a_repaired_repo
run_test test_record_of_a_gone_worktree_stays
run_test test_purging_dir_in_a_ticket_is_no_ticket_file
run_test test_dead_runs_leave_no_temp_dirs
run_test test_bundle_link_never_replaces_a_file
run_test test_inspect_accounts_for_every_container
run_test test_engine_exit_codes
run_test test_engine_down_with_other_runtimes
run_test test_process_status_must_be_read
run_test test_zombie_rows_name_the_parent
run_test test_notes_ask_the_recorded_repo_first
run_test test_notes_keep_a_dir_with_two_worktrees
run_test test_notes_ask_every_repo
run_test test_notes_never_repair
run_test test_notes_refuse_a_symlinked_git
run_test test_notes_on_dirs_without_a_record
run_test test_notes_list_a_worktree_through_a_symlink
run_test test_notes_on_a_worktree_deep_in_an_entry
run_test test_ticket_files_are_decided_by_git
run_test test_worktree_lists_time_out
run_test test_temp_dirs_of_other_runs
run_test test_record_updates
run_test test_notes_never_bring_back_a_purged_record
run_test test_notes_with_another_unreadable_repo
run_test test_notes_ask_a_separate_gitdir_repo
run_test test_purge_keeps_ticket_files_that_hold_a_worktree
run_test test_notes_check_the_git_file_against_the_listing
run_test test_entry_that_is_a_symlink
run_test test_entry_whose_git_is_a_symlink
run_test test_record_of_a_worktree_listed_at_its_purging_path
run_test test_inspect_fails_with_no_message
run_test test_shim_namespace_flags
run_test test_ticket_dirs_ask_every_repo_with_a_git_inside
run_test test_apply_skips_a_worktree_another_repo_lists
run_test test_one_ticket_line_per_ticket
run_test test_temp_dirs_of_older_runs
run_test test_killed_run_leaves_no_temp_dir
finish
