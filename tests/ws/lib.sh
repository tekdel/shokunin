# shellcheck shell=bash

WS_TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_failures=0
_base_path=$PATH
_base_tmpdir=${TMPDIR-}
_sandboxes=()
_sandbox=
_suite=$$
exec {_suite_out}>&1
trap 'drop_fixtures' EXIT
trap 'exit 2' TERM

ok() {
    printf 'ok    %s\n' "$1"
}

not_ok() {
    printf 'FAIL  %s\n' "$1"
    _failures=$((_failures + 1))
}

abort() {
    printf 'ABORT %s\n' "$1" >&"$_suite_out"
    [[ $BASHPID == "$_suite" ]] || kill -TERM "$_suite"
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

wait_exit() {
    local pid i
    for ((i = 0; i < 200; i++)); do
        for pid; do
            if kill -0 "$pid" 2>/dev/null; then
                sleep 0.05
                continue 2
            fi
        done
        return 0
    done
    return 1
}

drop_fixtures() {
    local dir
    local -a pids=()
    for dir in "${_sandboxes[@]}"; do
        if [[ -x $dir/root/bin/tmux ]]; then
            read -r -a pids < <("$dir/root/bin/tmux" list-panes -a -F '#{pid} #{pane_pid}' 2>/dev/null | tr '\n' ' ')
            "$dir/root/bin/tmux" kill-server 2>/dev/null
            wait_exit "${pids[@]}"
            flock -w 10 "$dir/root/.cache/ws/refresh.lock" true 2>/dev/null
        fi
        chmod -R u+rwx "$dir" 2>/dev/null
        rm -rf "$dir"
    done
    _sandboxes=()
}

new_fixture() {
    make_fixture
}

new_fixture_no_ticket() {
    make_fixture --no-ticket
}

make_fixture() {
    local sandbox
    drop_fixtures
    unset FX WS_TRASH
    _sandbox=
    if [[ -n $_base_tmpdir ]]; then
        export TMPDIR=$_base_tmpdir
    else
        unset TMPDIR
    fi
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ws-test.XXXXXX") || abort "cannot make a sandbox"
    _sandboxes+=("$sandbox")
    PATH=$_base_path
    bash "$WS_TESTS/fixture.sh" "$@" "$sandbox/root" >/dev/null || abort "fixture.sh failed"
    # shellcheck source=/dev/null
    source "$sandbox/root/env.sh" || abort "cannot source env.sh"
    _sandboxes+=("$TMUX_TMPDIR")
    [[ $HOME == "$sandbox/root" ]] || abort "env.sh did not set HOME"
    _sandbox=$(realpath -e -- "$sandbox") || abort "cannot resolve the sandbox"
    FX=$sandbox/root
    export WS_PROC=$FX/proc
    { mkdir -p "$WS_PROC/self/ns" && ln -s "mnt:[1]" "$WS_PROC/self/ns/mnt" && fake_root_owned_init; } ||
        abort "cannot make the fake process tree"
    ws_guard
}

ws_guard() {
    local path gh cmd
    [[ -n $_sandbox && -n ${FX-} && $HOME == "$FX" ]] || abort "ws called outside a fixture"
    gh=$(command -v gh) || gh=
    for path in "$HOME" "${WS_ROOT-}" "${WS_PROJECTS-}" "${WS_TRASH:-${XDG_DATA_HOME:-$HOME/.local/share}/ws/trash}" "$gh" \
        "${WS_VAULT-}" "${WS_VAULT-}/bin/vault-consolidate"; do
        [[ -n $path && $(realpath -m -- "$path") == "$_sandbox"/* ]] || abort "ws refused: '$path' is outside $_sandbox"
    done
    for cmd in docker podman; do
        path=$(command -v "$cmd") || continue
        [[ $(realpath -m -- "$path") == "$_sandbox"/* ]] || abort "ws refused: $cmd '$path' is outside $_sandbox"
    done
    for cmd in claude tmux dockyard doppler curl; do
        path=$(type -P "$cmd") || abort "ws refused: no $cmd on PATH"
        [[ $(realpath -m -- "$path") == "$_sandbox"/* ]] || abort "ws refused: $cmd '$path' is outside $_sandbox"
    done
}

run_test() {
    "$1"
    drop_fixtures
}

ws() {
    ws_guard
    bash "$WS_TESTS/../../dotfiles/bin/ws" "$@"
}

ws_on_other_fs() {
    ws_guard
    mkdir -p "$FX/otherfs" || abort "cannot make $FX/otherfs"
    # shellcheck disable=SC2016
    unshare -rm bash -c 'mount -t tmpfs -o size=8m tmpfs "$1" && mkdir "$1/trash" "$1/data" || exit 9
        dir=$1
        shift
        bash "$@"
        rc=$?
        find "$dir" -mindepth 2 >"$dir.landed"
        exit "$rc"' _ "$FX/otherfs" "$WS_TESTS/../../dotfiles/bin/ws" "$@"
}

fake_root_owned_init() {
    ln -s / "$WS_PROC/1"
}

fake_proc() {
    local pid=$1 ppid=$2 cwd=${3-} ns=${4:-mnt:[1]} name=${5:-fake$1} dir=$WS_PROC/$1
    {
        mkdir -p "$dir/ns" &&
            printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$name" "$EUID" "$EUID" "$EUID" "$EUID" >"$dir/status" &&
            printf '%s (%s) S %s 0 0 0\n' "$pid" "$name" "$ppid" >"$dir/stat" &&
            if [[ -n $cwd ]]; then
                ln -s "$ns" "$dir/ns/mnt" && ln -s "$cwd" "$dir/cwd"
            else
                : >"$dir/ns/mnt" && : >"$dir/cwd"
            fi
    } || abort "cannot make fake process $pid"
}

fake_cmdline() {
    local pid=$1
    shift
    printf '%s\0' "$@" >"$WS_PROC/$pid/cmdline" || abort "cannot write the command line of fake process $pid"
}

fake_zombie() {
    local tid
    local -a tasks=()
    fake_proc "$1" "$2" "" "" "$3"
    for tid in "$1" "${@:4}"; do
        tasks+=("$WS_PROC/$1/task/$tid")
    done
    {
        printf 'Name:\t%s\nState:\tZ (zombie)\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$3" "$2" "$EUID" "$EUID" "$EUID" "$EUID" \
            >"$WS_PROC/$1/status" &&
            printf '%s (%s) Z %s 0 0 0 0 4227148\n' "$1" "$3" "$2" >"$WS_PROC/$1/stat" &&
            mkdir -p "${tasks[@]}"
    } || abort "cannot make fake zombie $1"
}

add_container() {
    local engine=$1 name=$2 type=$3 source=$4
    {
        jq --arg name "$name" --arg type "$type" --arg source "$source" \
            '. + [{Id: "id-\($name)", Name: "/\($name)", Mounts: [{Type: $type, Source: $source, Destination: "/src"}]}]' \
            "$FX/$engine.json" >"$FX/$engine.json.new" &&
            mv "$FX/$engine.json.new" "$FX/$engine.json"
    } || abort "cannot add container $name"
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
    {
        git -C "$WS_PROJECTS/$repo" worktree add -q -b "$branch" "$path" &&
            echo "$branch" >"$path/$file" &&
            git -C "$path" add "$file" &&
            git -C "$path" commit -qm "work on $branch" &&
            git -C "$path" push -q -u origin "$branch"
    } || abort "cannot add worktree $path"
}

add_pr() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" "${6:-false}" >>"$FX/prs.tsv" ||
        abort "cannot add a PR for $2"
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
