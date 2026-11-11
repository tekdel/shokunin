# shellcheck shell=bash

WS_TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_failures=0
_base_path=$PATH
_sandboxes=()
trap 'drop_fixtures' EXIT

ok() {
    printf 'ok    %s\n' "$1"
}

not_ok() {
    printf 'FAIL  %s\n' "$1"
    _failures=$((_failures + 1))
}

abort() {
    printf 'ABORT %s\n' "$1"
    exit 2
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

drop_fixtures() {
    local dir
    for dir in "${_sandboxes[@]}"; do
        chmod -R u+rwx "$dir" 2>/dev/null
        rm -rf "$dir"
    done
    _sandboxes=()
}

new_fixture() {
    local sandbox
    drop_fixtures
    unset FX
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ws-test.XXXXXX") || abort "cannot make a sandbox"
    _sandboxes+=("$sandbox")
    PATH=$_base_path
    bash "$WS_TESTS/fixture.sh" "$sandbox/root" >/dev/null || abort "fixture.sh failed"
    # shellcheck source=/dev/null
    source "$sandbox/root/env.sh" || abort "cannot source env.sh"
    _sandboxes+=("$TMUX_TMPDIR")
    [[ $HOME == "$sandbox/root" ]] || abort "env.sh did not set HOME"
    FX=$sandbox/root
}

run_test() {
    "$1"
    drop_fixtures
}

ws() {
    [[ -n ${FX-} && $HOME == "$FX" ]] || abort "ws called outside a fixture"
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

trash_dir() {
    echo "$XDG_DATA_HOME/ws/trash"
}

meta_of() {
    local f
    for f in "$(trash_dir)"/*.meta "$(trash_dir)"/*/*.meta; do
        if [[ -f $f ]] && grep -aqxF "orig=${1//%/%25}" "$f"; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

meta_get() {
    local f value
    f=$(meta_of "$1") || return 0
    value=$(sed -n "s/^$2=//p" "$f")
    printf '%s\n' "${value//%25/%}"
}

trash_of() {
    local f
    f=$(meta_of "$1") || return 0
    printf '%s\n' "${f%.meta}"
}

other_fs_dir() {
    local dev dir
    dev=$(stat -c %d "$FX")
    for dir in /dev/shm "/run/user/$(id -u)" /var/tmp; do
        if [[ -d $dir && -w $dir && $(stat -c %d "$dir") != "$dev" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

fake_git() {
    {
        printf '#!/usr/bin/env bash\nreal=%q\n' "$(PATH=$_base_path command -v git)"
        # shellcheck disable=SC2016
        printf '%s\nexec "$real" "$@"\n' "$1"
    } >"$FX/bin/git"
    chmod +x "$FX/bin/git"
}

in_trash() {
    local trash
    trash=$(trash_of "$1")
    [[ -n $trash && ! -e $1 ]] && is_worktree "$trash"
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
