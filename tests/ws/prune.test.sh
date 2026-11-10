#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

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

test_dry_run() {
    new_fixture
    local before out
    before=$(snapshot alpha beta)
    out=$(ws prune)
    assert_eq "dry run exits 0" 0 $?
    assert_eq "dry run leaves git worktree list unchanged" "$before" "$(snapshot alpha beta)"
    assert_eq "summary line counts every class" \
        "REMOVE 3  KEEP 6 (open 2, no-pr 1, detached 1, dirty 1, unpushed 1)" "$(tail -n1 <<<"$out")"
    assert_eq "a merged PR outranks older and newer closed ones" "#2 merged" \
        "$(pr_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert_eq "the newest of two merged PRs shows" "#11 merged" "$(pr_of "$out" "$WS_PROJECTS/alpha-dirty")"
    assert_eq "an open PR outranks a newer merged one" "KEEP open" "$(action_of "$out" "$WS_PROJECTS/alpha-open")"
    assert_eq "the open PR shows" "#6 open" "$(pr_of "$out" "$WS_PROJECTS/alpha-open")"
}

test_gh_calls() {
    new_fixture
    ws prune >/dev/null
    local repo state
    for repo in alpha beta; do
        for state in open all; do
            assert_eq "$repo has one --state $state --limit 1000 call" 1 \
                "$(gh_calls "-R fixture/$repo" "--state $state" "--limit 1000" '!--head')"
        done
    done
    assert_eq "a branch with no PR in the lists is confirmed by --head" 1 \
        "$(gh_calls "-R fixture/alpha" "--head feat/nopr" "--state all")"
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
    local out
    out=$(ws prune --apply <<<y 2>"$FX/err")
    assert_eq "apply exits 0" 0 $?
    assert_eq "a successful apply prints nothing on stderr" "" "$(<"$FX/err")"

    assert_eq "merged clean worktree is REMOVE" REMOVE "$(action_of "$out" "$WS_PROJECTS/alpha-merged")"
    assert "merged clean worktree is gone" test ! -e "$WS_PROJECTS/alpha-merged"
    refute "merged branch is deleted" has_branch alpha feat/merged

    assert_eq "closed clean worktree is REMOVE" REMOVE "$(action_of "$out" "$WS_PROJECTS/alpha-closed")"
    assert "closed clean worktree is gone" test ! -e "$WS_PROJECTS/alpha-closed"
    assert "closed branch is kept" has_branch alpha feat/closed

    assert_eq "merged ticket worktree under WS_ROOT is REMOVE" REMOVE "$(action_of "$out" "$WS_ROOT/t1/beta")"
    assert "merged ticket worktree is gone" test ! -e "$WS_ROOT/t1/beta"
    refute "merged ticket branch is deleted in its own repo" has_branch beta feat/ticket

    assert_eq "merged dirty worktree is KEEP dirty" "KEEP dirty" "$(action_of "$out" "$WS_PROJECTS/alpha-dirty")"
    assert "merged dirty worktree survives" is_worktree "$WS_PROJECTS/alpha-dirty"

    assert_eq "merged worktree with a local commit is KEEP unpushed" "KEEP unpushed" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-unpushed")"
    assert "unpushed worktree survives" is_worktree "$WS_PROJECTS/alpha-unpushed"
    assert "unpushed branch survives" has_branch alpha feat/unpushed

    assert_eq "open PR worktree is KEEP open" "KEEP open" "$(action_of "$out" "$WS_PROJECTS/alpha-open")"
    assert "open PR worktree survives" is_worktree "$WS_PROJECTS/alpha-open"
    assert "open PR branch survives" has_branch alpha feat/open
    assert_eq "same branch with an open PR in another repo is KEEP open" "KEEP open" \
        "$(action_of "$out" "$WS_ROOT/t1/alpha")"
    assert "open ticket worktree survives" is_worktree "$WS_ROOT/t1/alpha"

    assert_eq "branch without a PR is KEEP no-pr" "KEEP no-pr" "$(action_of "$out" "$WS_PROJECTS/alpha-nopr")"
    assert "no-PR worktree survives" is_worktree "$WS_PROJECTS/alpha-nopr"

    assert_eq "detached worktree is KEEP detached" "KEEP detached" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-detached")"
    assert "detached worktree survives without --include-detached" is_worktree "$WS_PROJECTS/alpha-detached"

    refute "no prunable entries remain" grep -q "^prunable" <<<"$(snapshot alpha beta)"
}

test_apply_no() {
    new_fixture
    local before out
    before=$(snapshot alpha beta)
    ws prune --apply <<<n >/dev/null
    assert_eq "declined apply exits 0" 0 $?
    assert_eq "declined apply removes nothing" "$before" "$(snapshot alpha beta)"
    assert "declined apply keeps merged branch" has_branch alpha feat/merged

    out=$(ws prune --apply </dev/null)
    assert "end of input at the prompt ends the prompt line" grep -qx "Nothing removed." <<<"$out"
    assert_eq "end of input removes nothing" "$before" "$(snapshot alpha beta)"
}

test_include_detached() {
    new_fixture
    local out
    out=$(ws prune --apply --include-detached <<<y 2>/dev/null)
    assert_eq "clean detached worktree is REMOVE with --include-detached" REMOVE \
        "$(action_of "$out" "$WS_PROJECTS/alpha-detached")"
    assert "clean detached worktree is gone with --include-detached" test ! -e "$WS_PROJECTS/alpha-detached"

    new_fixture
    echo edit >>"$WS_PROJECTS/alpha-detached/README"
    out=$(ws prune --apply --include-detached <<<y 2>/dev/null)
    assert_eq "dirty detached worktree is KEEP dirty with --include-detached" "KEEP dirty" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-detached")"
    assert "dirty detached worktree survives" is_worktree "$WS_PROJECTS/alpha-detached"
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
    assert_eq "gh failure removes nothing" "$before" "$(snapshot alpha beta)"
}

test_gh_bad_output() {
    new_fixture
    local before body code
    before=$(snapshot alpha beta)
    for body in null '{}' '{"message":"API rate limit exceeded"}' '' '[{"headRefName":"feat/merged","sta'; do
        printf '%s' "$body" >"$FX/gh.out"
        ws prune --apply <<<y >/dev/null 2>&1
        code=$?
        assert_eq "gh output '$body' exits 2" 2 "$code"
        assert_eq "gh output '$body' removes nothing" "$before" "$(snapshot alpha beta)"
    done

    rm "$FX/gh.out"
    mv "$FX/bin/gh" "$FX/bin/gh-real"
    printf '#!/usr/bin/env bash\n[[ " $* " != *" --state open "* ]] || exit 0\nexec %q "$@"\n' \
        "$FX/bin/gh-real" >"$FX/bin/gh"
    chmod +x "$FX/bin/gh"
    ws prune --apply <<<y >/dev/null 2>&1
    assert_eq "an empty answer to one of two gh calls exits 2" 2 $?
    assert_eq "that empty answer removes nothing" "$before" "$(snapshot alpha beta)"
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
    assert_eq "a gh timeout removes nothing" "$before" "$(snapshot alpha beta)"
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

    add_worktree alpha "$n" feat/nestwt
    add_pr alpha feat/nestwt MERGED 40 "$(head_of "$n")"
    git -C "$WS_PROJECTS/beta" worktree add -q -b feat/inner "$n/.wt/beta"

    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "an ignored file with no copy in the main checkout is KEEP ignored-unique" \
        "KEEP ignored-unique" "$(action_of "$out" "$m")"
    assert_eq "the table names the unique ignored file" ".env" "$(detail_of "$out" "$m")"
    assert "the unique ignored file survives apply" grep -q only-copy "$m/.env"

    assert_eq "an ignored copy of the main checkout's file and an ignored dir are REMOVE" REMOVE \
        "$(action_of "$out" "$c")"
    assert "that worktree is gone" test ! -e "$c"

    assert_eq "a repo inside an ignored dir is KEEP nested-repo" "KEEP nested-repo" "$(action_of "$out" "$b")"
    assert_eq "the table names the nested repo" "vendor/lib" "$(detail_of "$out" "$b")"
    assert "the nested repo's commit survives apply" git -C "$b/vendor/lib" cat-file -e "$nested"

    assert_eq "a linked worktree inside an ignored dir is KEEP nested-repo" "KEEP nested-repo" \
        "$(action_of "$out" "$n")"
    assert "the inner worktree survives apply" is_worktree "$n/.wt/beta"
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

    add_worktree alpha "$s" feat/squash
    add_pr alpha feat/squash MERGED 20 "$(head_of "$s")"
    add_worktree alpha "$o" feat/moved-on
    add_pr alpha feat/moved-on MERGED 21 "$(head_of "$o")"
    add_worktree alpha "$g" feat/closed-gone
    add_pr alpha feat/closed-gone CLOSED 22 "$(head_of "$g")"
    git -C "$WS_PROJECTS/alpha" push -q origin --delete feat/squash feat/moved-on feat/closed-gone
    git -C "$WS_PROJECTS/alpha" fetch -q --prune
    commit_file "$o" later "commit after the merge"

    out=$(ws prune --apply <<<y 2>"$FX/err")
    err=$(<"$FX/err")
    assert_eq "a commit held only by refs/worktree is KEEP unpushed" "KEEP unpushed" "$(action_of "$out" "$m")"
    assert_eq "the refs/worktree commit survives apply" "$parked" \
        "$(git -C "$m" rev-parse -q --verify refs/worktree/parked)"
    assert_eq "a commit held only by refs/bisect is KEEP unpushed" "KEEP unpushed" "$(action_of "$out" "$c")"
    assert_eq "the refs/bisect commit survives apply" "$bad" "$(git -C "$c" rev-parse -q --verify refs/bisect/bad)"

    assert_eq "HEAD at the merged PR's head is REMOVE after GitHub deleted the branch" REMOVE \
        "$(action_of "$out" "$s")"
    assert "that worktree is gone" test ! -e "$s"
    refute "its branch is deleted because the tip is the PR head" has_branch alpha feat/squash
    assert_eq "deleting that branch prints nothing on stderr" "" "$err"

    assert_eq "a commit past the merged PR's head is KEEP unpushed" "KEEP unpushed" "$(action_of "$out" "$o")"
    assert "that worktree survives" is_worktree "$o"
    assert_eq "a closed PR's head does not count as pushed" "KEEP unpushed" "$(action_of "$out" "$g")"
    assert "the closed-PR worktree survives" is_worktree "$g"
}

test_branch_deletion() {
    new_fixture
    local merger=$FX/merger r=$WS_PROJECTS/alpha-refused out code
    git clone -q https://github.com/fixture/alpha.git "$merger"
    git -C "$merger" merge -q --no-ff -m "Merge pull request #2" origin/feat/merged
    git -C "$merger" push -q origin main
    git -C "$merger" push -q origin --delete feat/merged
    git -C "$WS_PROJECTS/alpha" fetch -q --prune

    add_worktree alpha "$r" feat/refused
    add_pr alpha feat/refused MERGED 30 "$(git -C "$WS_PROJECTS/alpha" rev-parse main)"
    git -C "$r" push -q origin feat/refused:refs/heads/copy
    git -C "$WS_PROJECTS/alpha" update-ref -d refs/remotes/origin/feat/refused

    out=$(ws prune --apply <<<y 2>"$FX/err")
    code=$?
    assert_eq "kept branches do not change the exit code" 0 "$code"
    assert_eq "branch deletion prints nothing on stderr" "" "$(<"$FX/err")"
    refute "a merged branch GitHub deleted is deleted when its tip is the PR head" has_branch alpha feat/merged
    assert "the worktree of a branch git refuses to delete is removed" test ! -e "$r"
    assert "a refused branch whose tip is not the PR head survives" has_branch alpha feat/refused
    assert "the output says why the branch stayed" grep -q "^Kept branch feat/refused: .*not fully merged" <<<"$out"
}

test_pr_matching() {
    new_fixture
    local x=$WS_PROJECTS/c-alpha-subx y=$WS_PROJECTS/c-sub-x out
    add_pr alpha feat/nopr MERGED 99 "$(head_of "$WS_PROJECTS/alpha-nopr")" true

    git clone -q https://github.com/fixture/beta.git "$WS_PROJECTS/alpha/sub"
    echo sub/ >>"$WS_PROJECTS/alpha/.git/info/exclude"
    add_worktree alpha "$x" sub/x
    add_pr alpha sub/x OPEN 50 "$(head_of "$x")"
    add_worktree alpha/sub "$y" x
    add_pr beta x MERGED 51 "$(head_of "$y")"

    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "a fork PR with the same branch name is ignored" "KEEP no-pr" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-nopr")"
    assert "the fork-named worktree survives" is_worktree "$WS_PROJECTS/alpha-nopr"
    assert "the fork-named branch survives" has_branch alpha feat/nopr
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
    add_worktree alpha "$m" feat/old-merged
    add_pr alpha feat/old-merged MERGED 12 "$(head_of "$m")"
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
    local b=$WS_ROOT/t1/beta out code
    : >"$FX/gh.log"
    git -C "$WS_PROJECTS/beta" remote set-url origin https://gitlab.com/fixture/beta.git
    out=$(ws prune --apply <<<y 2>/dev/null)
    code=$?
    assert_eq "a non-GitHub origin does not fail the run" 0 "$code"
    assert_eq "a non-GitHub origin is KEEP no-github" "KEEP no-github" "$(action_of "$out" "$b")"
    assert "the non-GitHub worktree survives" is_worktree "$b"
    assert_eq "no gh call names the non-GitHub repo" 0 "$(gh_calls "-R fixture/beta")"
    assert "other repos still apply" test ! -e "$WS_PROJECTS/alpha-merged"

    git -C "$WS_PROJECTS/beta" remote set-url origin https://github.example.com/fixture/beta.git
    assert_eq "a GitHub Enterprise origin is KEEP no-github" "KEEP no-github" "$(action_of "$(ws prune)" "$b")"
    git -C "$WS_PROJECTS/beta" remote remove origin
    out=$(ws prune)
    assert_eq "no origin exits 0" 0 $?
    assert_eq "no origin is KEEP no-github" "KEEP no-github" "$(action_of "$out" "$b")"
}

test_recheck_before_remove() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed out code pid answer
    echo .env >>"$WS_PROJECTS/alpha/.git/info/exclude"
    mkfifo "$FX/answer"
    ws prune --apply <"$FX/answer" >"$FX/out" 2>"$FX/err" &
    pid=$!
    exec {answer}>"$FX/answer"
    wait_for "$FX/out" 'Remove [0-9]* worktrees?'
    echo late-edit >>"$m/work.txt"
    echo SECRET=late >"$c/.env"
    echo y >&"$answer"
    exec {answer}>&-
    wait "$pid"
    code=$?
    out=$(<"$FX/out")
    assert_eq "skipped worktrees do not change the exit code" 0 "$code"
    assert "a tracked edit made at the prompt survives" grep -q late-edit "$m/work.txt"
    assert "an ignored file made at the prompt survives" grep -q SECRET=late "$c/.env"
    assert "the output names the changed worktree" grep -qx "Skipped ~/projects/alpha-merged: it changed after the scan" <<<"$out"
    assert "unchanged worktrees are still removed" test ! -e "$WS_ROOT/t1/beta"
}

test_remove_never_forces() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged code
    cat >"$FX/bin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" worktree remove "* ]]; then
    echo racing-edit >>"\${!#}/work.txt"
fi
exec $(printf %q "$(command -v git)") "\$@"
EOF
    chmod +x "$FX/bin/git"
    ws prune --apply <<<y >/dev/null 2>"$FX/err"
    code=$?
    rm "$FX/bin/git"
    assert_eq "a worktree that changes after the recheck makes apply exit 1" 1 "$code"
    assert "an edit that lands after the recheck survives" grep -q racing-edit "$m/work.txt"
    assert "git's refusal reaches the user" grep -q "contains modified or untracked files" "$FX/err"
}

test_locked_and_submodules() {
    new_fixture
    local m=$WS_PROJECTS/alpha-merged c=$WS_PROJECTS/alpha-closed out code
    git -C "$WS_PROJECTS/alpha" worktree lock --reason "on removable drive" "$m"
    git -C "$c" submodule add -q https://github.com/fixture/beta.git libbeta
    git -C "$c" commit -qm "add submodule"
    git -C "$c" push -q
    out=$(ws prune --apply <<<y 2>"$FX/err")
    code=$?
    assert_eq "locked and submodule worktrees do not fail apply" 0 "$code"
    assert_eq "they print nothing on stderr" "" "$(<"$FX/err")"
    assert_eq "a locked worktree is KEEP locked" "KEEP locked" "$(action_of "$out" "$m")"
    assert_eq "the table shows the lock reason" "on removable drive" "$(detail_of "$out" "$m")"
    assert "the locked worktree survives" is_worktree "$m"
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
    local sp="$WS_PROJECTS/sp tree [1] *" out code
    add_worktree alpha "$sp" feat/space
    add_pr alpha feat/space MERGED 80 "$(head_of "$sp")"
    mkdir -p "$FX/elsewhere"
    add_worktree alpha "$FX/elsewhere/real-wt" feat/linked
    add_pr alpha feat/linked MERGED 83 "$(head_of "$FX/elsewhere/real-wt")"
    ln -s "$FX/elsewhere/real-wt" "$WS_PROJECTS/link-wt"
    ln -s "$WS_PROJECTS/alpha-merged" "$WS_PROJECTS/twice-link"
    ln -s "$FX/elsewhere" "$WS_ROOT/t-link"

    out=$(ws prune --apply <<<y 2>"$FX/err")
    code=$?
    assert_eq "apply with spaces and symlinks exits 0" 0 "$code"
    assert_eq "it prints nothing on stderr" "" "$(<"$FX/err")"
    assert_eq "a path with spaces and glob characters is REMOVE" REMOVE "$(action_of "$out" "$sp")"
    assert "that worktree is gone" test ! -e "$sp"
    refute "a symlink to a worktree is not listed" grep -q link-wt <<<"$out"
    assert "the worktree behind the symlink survives" is_worktree "$FX/elsewhere/real-wt"
    refute "a symlink to a listed worktree is not listed again" grep -q twice-link <<<"$out"
    assert_eq "a symlinked ticket dir adds no rows" 10 "$(rows "$out")"

    new_fixture
    out=$(WS_ROOT=$FX ws prune)
    assert_eq "a worktree reached through two roots is listed once" 7 "$(rows "$out")"
}

test_unknown_command() {
    local err
    err=$(ws bogus 2>&1)
    assert_eq "unknown command exits 1" 1 $?
    assert "usage lists prune" grep -q "prune" <<<"$err"
}

test_dry_run
test_gh_calls
test_gh_parallel
test_apply_yes
test_apply_no
test_include_detached
test_gh_failure
test_gh_bad_output
test_gh_timeout
test_dirty_ignores_user_config
test_hidden_flags
test_ignored_files
test_pushed
test_branch_deletion
test_pr_matching
test_pr_window
test_origins
test_non_github_origin
test_recheck_before_remove
test_remove_never_forces
test_locked_and_submodules
test_leaves_other_worktree_entries
test_layout
test_unknown_command
finish
