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
  bin/gh               gh shim, answers pr list from prs.tsv
  prs.tsv              repo, branch, state, number per PR
  gh.log               one line per gh call
  gh.fail              create it to make gh exit 1, list repo names to
                       fail only those repos
  env.sh               exports WS_ROOT, WS_PROJECTS, WS_VAULT, PATH
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

# The operator's global config can sign commits or rename the default branch.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

projects=$root/projects
mkdir -p "$root/origins" "$projects" "$root/work/t1" "$root/vault" "$root/bin" "$projects/notes"

make_repo() {
    local repo=$1 seed=$root/seed-$1
    git init -q -b main "$seed"
    echo "$repo" >"$seed/README"
    git -C "$seed" add README
    git -C "$seed" commit -qm "init $repo"
    git clone -q --bare "$seed" "$root/origins/$repo.git"
    rm -rf "$seed"
    git clone -q "$root/origins/$repo.git" "$projects/$repo"
    # A github.com origin URL lets ws derive the slug, insteadOf keeps git traffic local.
    git -C "$projects/$repo" remote set-url origin "https://github.com/fixture/$repo.git"
    git -C "$projects/$repo" config "url.$root/origins/.insteadOf" "https://github.com/fixture/"
}

add_worktree() {
    local repo=$1 path=$2 branch=$3
    git -C "$projects/$repo" worktree add -q -b "$branch" "$path"
    echo "$branch" >"$path/work.txt"
    git -C "$path" add work.txt
    git -C "$path" commit -qm "work on $branch"
    git -C "$path" push -q -u origin "$branch"
}

make_repo alpha
make_repo beta

add_worktree alpha "$projects/alpha-merged" feat/merged
add_worktree alpha "$projects/alpha-dirty" feat/dirty
echo edit >>"$projects/alpha-dirty/work.txt"
add_worktree alpha "$projects/alpha-unpushed" feat/unpushed
echo more >>"$projects/alpha-unpushed/work.txt"
git -C "$projects/alpha-unpushed" commit -qam "local only"
add_worktree alpha "$projects/alpha-closed" feat/closed
add_worktree alpha "$projects/alpha-open" feat/open
add_worktree alpha "$projects/alpha-nopr" feat/nopr
git -C "$projects/alpha" worktree add -q --detach "$projects/alpha-detached"
add_worktree alpha "$root/work/t1/alpha" feat/ticket
add_worktree beta "$root/work/t1/beta" feat/ticket

printf '%s\t%s\t%s\t%s\n' \
    alpha feat/merged CLOSED 1 \
    alpha feat/merged MERGED 2 \
    alpha feat/dirty MERGED 3 \
    alpha feat/unpushed MERGED 4 \
    alpha feat/closed CLOSED 5 \
    alpha feat/open OPEN 6 \
    alpha feat/ticket OPEN 7 \
    beta feat/ticket MERGED 1 \
    >"$root/prs.tsv"

cat >"$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$*" >>"$root/gh.log"
args="$*"
repo="" state="" json=""
[[ ${1:-} == pr && ${2:-} == list ]] || {
    echo "gh shim: unsupported call: $args" >&2
    exit 3
}
shift 2
while (($#)); do
    case $1 in
    -R | --repo) repo=$2 ;;
    --state) state=$2 ;;
    --json) json=$2 ;;
    -L | --limit) ;;
    *)
        echo "gh shim: unsupported flag $1" >&2
        exit 3
        ;;
    esac
    shift 2
done
[[ -n $repo && $state == all && $json == headRefName,state,number ]] || {
    echo "gh shim: unsupported call: $args" >&2
    exit 3
}
name=${repo#*/}
if [[ -f $root/gh.fail ]] && { [[ ! -s $root/gh.fail ]] || grep -qx "$name" "$root/gh.fail"; }; then
    echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2
    exit 1
fi
jq -Rn --arg repo "$name" '
    [inputs | split("\t") | select(.[0] == $repo)
     | {headRefName: .[1], state: .[2], number: (.[3] | tonumber)}]
    | sort_by(-.number)' "$root/prs.tsv"
EOF
chmod +x "$root/bin/gh"

cat >"$root/env.sh" <<EOF
export WS_ROOT=$(printf %q "$root/work")
export WS_PROJECTS=$(printf %q "$projects")
export WS_VAULT=$(printf %q "$root/vault")
export PATH=$(printf %q "$root/bin"):\$PATH
EOF
