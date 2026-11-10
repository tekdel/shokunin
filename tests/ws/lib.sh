# shellcheck shell=bash

WS_TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_failures=0
_base_path=$PATH
_sandboxes=()
trap 'rm -rf "${_sandboxes[@]}"' EXIT

ok() {
    printf 'ok    %s\n' "$1"
}

not_ok() {
    printf 'FAIL  %s\n' "$1"
    _failures=$((_failures + 1))
}

assert() {
    local desc=$1
    shift
    if "$@"; then ok "$desc"; else not_ok "$desc"; fi
}

refute() {
    local desc=$1
    shift
    if "$@"; then not_ok "$desc"; else ok "$desc"; fi
}

assert_eq() {
    if [[ $2 == "$3" ]]; then
        ok "$1"
    else
        not_ok "$1"
        printf '      expected: %s\n      actual:   %s\n' "$2" "$3"
    fi
}

new_fixture() {
    local sandbox
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ws-test.XXXXXX")
    _sandboxes+=("$sandbox")
    bash "$WS_TESTS/fixture.sh" "$sandbox/root" >/dev/null
    PATH=$_base_path
    FX=$sandbox/root
    # shellcheck source=/dev/null
    source "$FX/env.sh"
}

ws() {
    bash "$WS_TESTS/../../dotfiles/bin/ws" "$@"
}

snapshot() {
    local repo
    for repo; do
        git -C "$WS_PROJECTS/$repo" worktree list --porcelain
    done
}

has_branch() {
    git -C "$WS_PROJECTS/$1" show-ref --verify -q "refs/heads/$2"
}

is_worktree() {
    local common
    [[ -d $1 ]] &&
        common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
        git --git-dir="$common" worktree list --porcelain | grep -Fqx "worktree $1"
}

table_field() {
    local shown=${3/#"$HOME/"/\~/}
    awk -F '  +' -v path="$shown" -v n="$1" '$5 == path { print $n }' <<<"$2"
}

action_of() {
    table_field 1 "$@"
}

detail_of() {
    table_field 6 "$@"
}

pr_of() {
    table_field 3 "$@"
}

add_worktree() {
    local repo=$1 path=$2 branch=$3 file=${3//\//-}.txt
    git -C "$WS_PROJECTS/$repo" worktree add -q -b "$branch" "$path"
    echo "$branch" >"$path/$file"
    git -C "$path" add "$file"
    git -C "$path" commit -qm "work on $branch"
    git -C "$path" push -q -u origin "$branch"
}

add_pr() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" "${6:-false}" >>"$FX/prs.tsv"
}

head_of() {
    git -C "$1" rev-parse HEAD
}

finish() {
    if ((_failures)); then
        echo "$_failures failed"
        exit 1
    fi
    echo "all passed"
}
