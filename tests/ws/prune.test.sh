#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

action_of() {
    awk -v path="$2" '$NF == path && $1 ~ /^(REMOVE|KEEP)$/ { print ($1 == "KEEP" ? $1 " " $2 : $1) }' <<<"$1"
}

snapshot() {
    git -C "$WS_PROJECTS/alpha" worktree list --porcelain
    git -C "$WS_PROJECTS/beta" worktree list --porcelain
}

has_branch() {
    git -C "$WS_PROJECTS/$1" show-ref --verify -q "refs/heads/$2"
}

is_worktree() {
    [[ -d $1 ]] && grep -Fqx "worktree $1" <<<"$(snapshot)"
}

test_dry_run() {
    new_fixture
    local before out
    before=$(snapshot)
    out=$(ws prune)
    assert_eq "dry run exits 0" 0 $?
    assert_eq "dry run leaves git worktree list unchanged" "$before" "$(snapshot)"
    assert_eq "summary line counts every class" \
        "REMOVE 3  KEEP 6 (open 2, no-pr 1, detached 1, dirty 1, unpushed 1)" "$(tail -n1 <<<"$out")"
    assert_eq "one gh call per repo" "fixture/alpha fixture/beta" \
        "$(awk '{ print $4 }' "$WS_PROJECTS/../gh.log" | sort | xargs)"
    assert_eq "newest merged PR wins over an older closed one" "#2 merged" \
        "$(awk -v p="$WS_PROJECTS/alpha-merged" '$NF == p { print $3, $4 }' <<<"$out")"
}

test_apply_yes() {
    new_fixture
    local out
    out=$(ws prune --apply <<<y 2>/dev/null)
    assert_eq "apply exits 0" 0 $?

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
    assert_eq "same branch with an open PR in another repo is KEEP open" "KEEP open" \
        "$(action_of "$out" "$WS_ROOT/t1/alpha")"
    assert "open ticket worktree survives" is_worktree "$WS_ROOT/t1/alpha"

    assert_eq "branch without a PR is KEEP no-pr" "KEEP no-pr" "$(action_of "$out" "$WS_PROJECTS/alpha-nopr")"
    assert "no-PR worktree survives" is_worktree "$WS_PROJECTS/alpha-nopr"

    assert_eq "detached worktree is KEEP detached" "KEEP detached" \
        "$(action_of "$out" "$WS_PROJECTS/alpha-detached")"
    assert "detached worktree survives without --include-detached" is_worktree "$WS_PROJECTS/alpha-detached"

    refute "no prunable entries remain" grep -q "^prunable" <<<"$(snapshot)"
}

test_apply_no() {
    new_fixture
    local before
    before=$(snapshot)
    ws prune --apply <<<n >/dev/null
    assert_eq "declined apply exits 0" 0 $?
    assert_eq "declined apply removes nothing" "$before" "$(snapshot)"
    assert "declined apply keeps merged branch" has_branch alpha feat/merged
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

test_branch_not_fully_merged() {
    new_fixture
    local err code
    git -C "$WS_PROJECTS/alpha-merged" push -q origin feat/merged:refs/heads/copy
    git -C "$WS_PROJECTS/alpha" update-ref -d refs/remotes/origin/feat/merged
    err=$(ws prune --apply <<<y 2>&1 >/dev/null)
    code=$?
    assert_eq "a branch git refuses to delete exits 1" 1 "$code"
    assert "git's refusal reaches the user" grep -q "not fully merged" <<<"$err"
    assert "the refused branch survives" has_branch alpha feat/merged
    assert "its worktree is still removed" test ! -e "$WS_PROJECTS/alpha-merged"
}

test_gh_failure() {
    new_fixture
    local before err code
    before=$(snapshot)
    echo beta >"$WS_PROJECTS/../gh.fail"
    err=$(ws prune --apply <<<y 2>&1 >/dev/null)
    code=$?
    assert_eq "gh failure exits 2" 2 "$code"
    assert "gh failure names the repo" grep -q "cannot read PR state for beta" <<<"$err"
    refute "gh failure does not blame a repo that answered" grep -q "for alpha" <<<"$err"
    assert_eq "gh failure removes nothing" "$before" "$(snapshot)"
}

test_unknown_command() {
    local err
    err=$(ws bogus 2>&1)
    assert_eq "unknown command exits 1" 1 $?
    assert "usage lists prune" grep -q "prune" <<<"$err"
}

test_dry_run
test_apply_yes
test_apply_no
test_include_detached
test_branch_not_fully_merged
test_gh_failure
test_unknown_command
finish
