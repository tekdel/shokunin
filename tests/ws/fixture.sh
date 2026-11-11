#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: fixture.sh <root>

Builds a ws sandbox at <root>, which must not exist or be empty.

  origins/<repo>.git   bare origins for alpha and beta
  projects/            WS_PROJECTS: main clones and linked worktrees
  work/t1/             WS_ROOT ticket with a worktree of alpha and beta
  vault/               WS_VAULT
  gitconfig            GIT_CONFIG_GLOBAL: identity, and github.com/fixture
                       URLs rewritten to origins/
  bin/gh               gh shim, answers pr list from prs.tsv
  prs.tsv              repo, branch, state, number, headRefOid, and
                       isCrossRepository per PR: true, false (the
                       default), null, or missing to leave it out
  gh.log               one line per gh call
  gh.fail              create it to make gh exit 1, list repo names to
                       fail only those repos
  gh.out               create it to make gh print its content instead
  gh.slow              holds seconds for gh to sleep, and logs start and
                       end times to gh.times
  env.sh               exports HOME, the XDG_CONFIG_HOME, XDG_CACHE_HOME,
                       XDG_DATA_HOME, and XDG_STATE_HOME dirs under
                       <root>, GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM,
                       WS_ROOT, WS_PROJECTS, WS_VAULT, PATH, and a short
                       TMUX_TMPDIR under /tmp, and unsets TMUX and
                       TMUX_PANE
EOF
}

[[ $# -eq 1 && $1 != -h && $1 != --help ]] || {
    usage >&2
    exit 1
}
mkdir -p "$1"
root=$(cd "$1" && pwd)
[[ -z $(find "$root" -mindepth 1 -print -quit) ]] || {
    echo "fixture.sh: $root is not empty" >&2
    exit 1
}

projects=$root/projects
mkdir -p "$root/origins" "$projects/notes" "$root/work/t1" "$root/vault" "$root/bin" \
    "$root/.cache" "$root/.config" "$root/.local/share" "$root/.local/state"
# A socket path under <root> can pass the 108-byte limit.
tmux_dir=$(mktemp -d /tmp/wsx.XXXXXX)

cat >"$root/gitconfig" <<EOF
[user]
	name = fixture
	email = fixture@example.invalid
[init]
	defaultBranch = main
[advice]
	detachedHead = false
[protocol "file"]
	allow = always
[url "$root/origins/"]
	insteadOf = https://github.com/fixture/
	insteadOf = git@github.com:fixture/
EOF

cat >"$root/env.sh" <<EOF
export HOME=$(printf %q "$root")
export XDG_CONFIG_HOME=$(printf %q "$root/.config")
export XDG_CACHE_HOME=$(printf %q "$root/.cache")
export XDG_DATA_HOME=$(printf %q "$root/.local/share")
export XDG_STATE_HOME=$(printf %q "$root/.local/state")
export TMUX_TMPDIR=$(printf %q "$tmux_dir")
unset TMUX TMUX_PANE
export GIT_CONFIG_GLOBAL=$(printf %q "$root/gitconfig")
export GIT_CONFIG_NOSYSTEM=1
export WS_ROOT=$(printf %q "$root/work")
export WS_PROJECTS=$(printf %q "$projects")
export WS_VAULT=$(printf %q "$root/vault")
export PATH=$(printf %q "$root/bin"):\$PATH
EOF
# shellcheck source=/dev/null
source "$root/env.sh"

make_repo() {
    local repo=$1 seed=$root/seed-$1
    git init -q "$seed"
    echo "$repo" >"$seed/README"
    git -C "$seed" add README
    git -C "$seed" commit -qm "init $repo"
    git clone -q --bare "$seed" "$root/origins/$repo.git"
    rm -rf "$seed"
    git clone -q "https://github.com/fixture/$repo.git" "$projects/$repo"
}

add_worktree() {
    local repo=$1 path=$2 branch=$3
    git -C "$projects/$repo" worktree add -q -b "$branch" "$path"
    echo "$branch" >"$path/work.txt"
    git -C "$path" add work.txt
    git -C "$path" commit -qm "work on $branch"
    git -C "$path" push -q -u origin "$branch"
}

pr() {
    printf '%s\t%s\t%s\t%s\t%s\tfalse\n' "$1" "$2" "$3" "$4" "$(git -C "$5" rev-parse HEAD)" >>"$root/prs.tsv"
}

make_repo alpha
make_repo beta

add_worktree alpha "$projects/alpha-merged" feat/merged
add_worktree alpha "$projects/alpha-dirty" feat/dirty
echo edit >>"$projects/alpha-dirty/work.txt"
add_worktree alpha "$projects/alpha-unpushed" feat/unpushed
add_worktree alpha "$projects/alpha-closed" feat/closed
add_worktree alpha "$projects/alpha-open" feat/open
add_worktree alpha "$projects/alpha-nopr" feat/nopr
git -C "$projects/alpha" worktree add -q --detach "$projects/alpha-detached"
add_worktree alpha "$root/work/t1/alpha" feat/ticket
add_worktree beta "$root/work/t1/beta" feat/ticket

: >"$root/prs.tsv"
pr alpha feat/merged CLOSED 1 "$projects/alpha-merged"
pr alpha feat/merged MERGED 2 "$projects/alpha-merged"
pr alpha feat/dirty MERGED 3 "$projects/alpha-dirty"
pr alpha feat/unpushed MERGED 4 "$projects/alpha-unpushed"
pr alpha feat/closed CLOSED 5 "$projects/alpha-closed"
pr alpha feat/open OPEN 6 "$projects/alpha-open"
pr alpha feat/ticket OPEN 7 "$root/work/t1/alpha"
pr alpha feat/open MERGED 9 "$projects/alpha-open"
pr alpha feat/merged CLOSED 10 "$projects/alpha-merged"
pr alpha feat/dirty MERGED 11 "$projects/alpha-dirty"
pr beta feat/ticket MERGED 1 "$root/work/t1/beta"

echo more >>"$projects/alpha-unpushed/work.txt"
git -C "$projects/alpha-unpushed" commit -qam "local only"

cat >"$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$*" >>"$root/gh.log"
args="$*"
repo="" state=open json="" head="" limit=30
[[ ${1:-} == pr && ${2:-} == list ]] || {
    echo "gh shim: unsupported call: $args" >&2
    exit 3
}
shift 2
while (($#)); do
    case $1 in
    -R | --repo) repo=$2 ;;
    -s | --state) state=$2 ;;
    -H | --head) head=$2 ;;
    -L | --limit) limit=$2 ;;
    --json) json=$2 ;;
    *)
        echo "gh shim: unsupported flag $1" >&2
        exit 3
        ;;
    esac
    shift 2
done
[[ -n $repo && -n $json ]] || {
    echo "gh shim: unsupported call: $args" >&2
    exit 3
}
if [[ -f $root/gh.slow ]]; then
    printf 'start %s %s\n' "$(date +%s.%N)" "$args" >>"$root/gh.times"
    sleep "$(<"$root/gh.slow")"
    printf 'end %s %s\n' "$(date +%s.%N)" "$args" >>"$root/gh.times"
fi
name=${repo##*/}
if [[ -f $root/gh.fail ]] && { [[ ! -s $root/gh.fail ]] || grep -qx "$name" "$root/gh.fail"; }; then
    echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2
    exit 1
fi
if [[ -f $root/gh.out ]]; then
    cat "$root/gh.out"
    exit 0
fi
jq -Rn --arg repo "$name" --arg state "$state" --arg head "$head" --argjson limit "$limit" \
    --arg fields "$json" '
    [inputs | split("\t") | select(.[0] == $repo)
     | {headRefName: .[1], state: .[2], number: (.[3] | tonumber), headRefOid: (.[4] // ""),
        isCrossRepository: (.[5] as $c | if $c == "true" then true elif $c == "null" then null
            elif $c == "missing" then "missing" else false end)}
     | select($state == "all" or (.state | ascii_downcase) == $state)
     | select($head == "" or .headRefName == $head)
     | if .isCrossRepository == "missing" then del(.isCrossRepository) else . end]
    | sort_by(-.number) | .[:$limit]
    | map(with_entries(select(.key as $k | $fields | split(",") | index($k))))' "$root/prs.tsv"
EOF
chmod +x "$root/bin/gh"
