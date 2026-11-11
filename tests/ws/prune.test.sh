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
    echo "$3" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -qm "$3"
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
    assert "help says orphans are never deleted" grep -qi "orphan" <<<"$help"
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
    assert "the output names the changed worktree" grep -qx "Skipped ~/projects/alpha-merged: it changed after the scan" <<<"$out"
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
        "$(action_of "$out" "${sp//%/%25}")"
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
    local dir out
    if ! dir=$(other_fs_dir); then
        ok "cross-fs skipped: no writable directory on another filesystem"
        return
    fi
    out=$(WS_TRASH=$dir/ws-test-trash-$$/trash ws prune --apply <<<y 2>/dev/null)
    assert_eq "a trash on another filesystem is KEEP cross-fs" "KEEP cross-fs" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert "that worktree stays" is_worktree "$WS_PROJECTS/alpha-merged"
    refute "no trash is made on the other filesystem" test -e "$dir/ws-test-trash-$$"
    rm -rf "${dir:?}/ws-test-trash-$$"
}

test_trash_location() {
    new_fixture
    local before dir out code far
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

    if ! dir=$(other_fs_dir); then
        ok "symlinked trash skipped: no writable directory on another filesystem"
        return
    fi
    far=$(mktemp -d "$dir/ws-test.XXXXXX")
    _sandboxes+=("$far")
    mkdir "$far/trash" "$far/data"
    ln -s "$far/trash" "$FX/trash-link"
    out=$(WS_TRASH=$FX/trash-link ws prune --apply <<<y 2>/dev/null)
    assert_eq "a trash reached through a symlink to another filesystem is KEEP cross-fs" "KEEP cross-fs" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    rmdir "$(trash_dir)" "$XDG_DATA_HOME/ws"
    ln -s "$far/data" "$XDG_DATA_HOME/ws"
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a missing trash below a symlink to another filesystem is KEEP cross-fs" "KEEP cross-fs" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert_eq "neither moves anything" "$before" "$(snapshot alpha beta)"
    refute "nothing lands on the other filesystem" test -n "$(find "$far" -mindepth 2 -print -quit)"
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
    mkdir -p "$1"
    add_worktree alpha "$1/alpha" feat/t8a
    add_pr alpha feat/t8a MERGED 700 "$(head_of "$1/alpha")"
    add_worktree beta "$1/beta" feat/t8b
    add_pr beta feat/t8b MERGED 701 "$(head_of "$1/beta")"
    echo notes >"$1/CLAUDE.md"
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
    out=$(WS_STAMP=$stamp ws prune --apply <<<y 2>&1)
    assert_eq "apply skips a name a pending record holds" "$tr/$stamp-alpha-closed.2" \
        "$(trash_of "$WS_PROJECTS/alpha-closed")"
    assert "the pending record stays as it was" grep -qx pending "$tr/$stamp-alpha-closed.meta.tmp"
    assert_eq "a worktree named like a ticket gets the plain name" "$tr/$stamp-alpha-merged" \
        "$(trash_of "$WS_PROJECTS/alpha-merged")"
    assert_eq "the ticket gets its own trash dir" "$tr/$stamp-alpha-merged.2/beta" \
        "$(trash_of "$WS_ROOT/alpha-merged/beta")"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "purge deletes the worktree" test ! -e "$tr/$stamp-alpha-merged"
    assert "purge deletes the ticket's worktree" test ! -e "$tr/$stamp-alpha-merged.2/beta"
    assert "the ticket's notes go to the archive" test -f "$tr/archive/$stamp-alpha-merged.2/notes.md"
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
    fake_git "if [[ \$2 == worktree && \$3 == remove ]] && echo only-copy 2>/dev/null >$(printf %q "$entry/.late"); then
    : >$(printf %q "$FX/late.wrote")
fi"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    rm "$FX/bin/git"
    assert "a file written to the entry's path while purge deletes it is never lost" \
        test ! -e "$FX/late.wrote" -o -f "$entry/.late"
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

    new_fixture
    m=$WS_PROJECTS/alpha-merged
    fake_git 'if [[ $2 == worktree && $3 == move && $4 == */alpha-merged ]]; then mkdir -p "$5"; fi'
    out=$(ws prune --apply <<<y 2>&1)
    rm "$FX/bin/git"
    cmd=$(grep -o "git -C .*" <<<"$out")
    assert "apply prints a command when git moved the worktree into a dir another process made" test -n "$cmd"
    out=$(ws prune --purge --older-than 0d <<<y 2>&1)
    assert "purge lists that worktree as an orphan" grep -q "^Orphan ~/.*-alpha-merged" <<<"$out"
    bash -c "$cmd" >/dev/null 2>&1
    assert "the printed command puts it back" is_worktree "$m"

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
    assert "the listed command gives the entry its name back" is_worktree "$entry"
    ws prune --purge --older-than 0d <<<y >/dev/null 2>&1
    assert "the next purge deletes it" test ! -e "$entry"
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
    out=$(env SM="$FX/small" FX="$FX" WS_BIN="$WS_BIN" unshare -rm bash "$FX/inner.sh" 2>&1)
    assert "the worktree on the small filesystem is REMOVE before it fills" grep -qx planned <<<"$out"
    assert "a trash with no free space never strands a worktree" grep -qxE "stayed|restored" <<<"$out"
}

test_hidden_cwd() {
    new_fixture
    if ! command -v python3 >/dev/null; then
        ok "hidden cwd skipped: no python3"
        return
    fi
    local entry out pid i
    ws prune --apply <<<y >/dev/null 2>&1
    entry=$(trash_of "$WS_PROJECTS/alpha-merged")
    cat >"$FX/hide.py" <<'EOF'
import ctypes, os, sys, time
os.chdir(sys.argv[1])
ctypes.CDLL(None).prctl(4, 0, 0, 0, 0)
with open(sys.argv[2], "w") as f:
    f.write(str(os.getpid()))
time.sleep(30)
EOF
    (python3 -I "$FX/hide.py" "$entry" "$FX/orphan" &)
    for ((i = 0; i < 100; i++)); do
        [[ ! -s $FX/orphan ]] || break
        sleep 0.05
    done
    out=$(ws prune --purge --older-than 0d <<<n 2>/dev/null)
    kill "$(<"$FX/orphan")" 2>/dev/null
    assert_eq "a hidden process that init or the user manager adopted is skipped, as daemons are" REMOVE \
        "$(action_of "$out" "$entry")"

    python3 -I "$FX/hide.py" "$entry" "$FX/ready" &
    pid=$!
    for ((i = 0; i < 100; i++)); do
        [[ ! -s $FX/ready ]] || break
        sleep 0.05
    done
    out=$(ws prune --purge --older-than 0d <<<y 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    assert_eq "an entry is KEEP unreadable while a process of ours hides its working directory" "KEEP unreadable" \
        "$(action_of "$out" "$entry")"
    assert "the table names that process" grep -q "$pid" <<<"$(detail_of "$out" "$entry")"
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
    local m=$WS_PROJECTS/alpha-merged out pid
    mkdir -p "$m/sub"
    echo sub/ >>"$WS_PROJECTS/alpha/.git/info/exclude"
    (cd "$m/sub" && exec sleep 30) &
    pid=$!
    out=$(ws prune --apply <<<y 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    assert_eq "a worktree a process works in is KEEP in-use" "KEEP in-use" "$(action_of "$out" "$m")"
    assert "that worktree stays in place" is_worktree "$m"
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
    out=$(env -u WS_TMP bash -c 'source "$1"; ws_wt_facts "$2" >"$3"; ws_wt_unsafe "$3"' _ "$WS_BIN" \
        "$WS_ROOT/t1/beta" "$FX/facts")
    assert_eq "ws_wt_unsafe finds a clean pushed worktree safe without PR or GitHub gates" "" "$out"
    echo edit >>"$WS_ROOT/t1/beta/work.txt"
    out=$(bash -c 'source "$1"; ws_wt_facts "$2" >"$3"; ws_wt_unsafe "$3"' _ "$WS_BIN" \
        "$WS_ROOT/t1/beta" "$FX/facts")
    assert_eq "ws_wt_unsafe names the first unsafe reason" $'reason=dirty\tdetail=' "$out"

    git -C "$WS_ROOT/t1/beta" checkout -q -- work.txt
    out=$(bash -c 'source "$1"; ws_wt_facts "$2" >"$3"; ws_trash_move "$2" "$3"' _ "$WS_BIN" \
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
run_test test_concurrent_restore_and_apply
run_test test_restore_one_of_two
run_test test_purge_one_of_two
run_test test_trash_names
run_test test_purge_rechecks_after_the_prompt
run_test test_purge_moves_the_entry_before_it_deletes
run_test test_purge_saves_reflog_commits
run_test test_orphans
run_test test_full_trash
run_test test_hidden_cwd
run_test test_purge_keeps_entries_git_cannot_open
run_test test_in_use
run_test test_sourceable
run_test test_fixture_isolation
run_test test_unknown_command
finish
