#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: fixture.sh [--no-ticket] <root>

Builds a ws sandbox at <root>, which must not exist or be empty.
--no-ticket leaves out work/t1.

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
  bin/claude           claude shim: agents --json prints agents.json,
                       stop <id> marks that session stopped and kills
                       its pid, agents alone prints a banner and waits
                       for a line, and anything else prints its
                       arguments and sleeps
  agents.json          the sessions claude agents --json lists, [] at
                       first
  claude.log           one line per claude call
  bin/tmux             runs the real tmux on the socket name wsfx
  bin/docker           container engine shims, answer ps -q --no-trunc
  bin/podman           and inspect from <engine>.json; docker also
                       answers ps -q with a compose project label and
                       status=running filter, and compose -p <project>
                       logs, which prints one line and sleeps
  docker.logs-exit     create it to make compose logs exit half a second
                       after its line
  <engine>.json        the running containers, [] at first: objects with
                       Id, Name, Mounts of Type and Source, and Labels
  bin/dockyard         dockyard shim: up, down, and nuke keep
                       ~/.dockyard/slots.json as dockyard does, start
                       and stop containers in docker.json that mount
                       each repo of DOCKYARD_WORKSPACE, and print the
                       URL lines of dockyard up
  dockyard.log         one line per dockyard call: DOCKYARD_WORKSPACE,
                       a tab, and the arguments; nuke adds a line that
                       says whether the workspace still exists
  dockyard.lock        create it to make up of a new stack time out on
                       the slot lock and exit 2
  dockyard.build       create it to make up fail after it records the
                       slot and exit 1
  dockyard.steal       holds a directory; down then writes it into the
                       stack's record as the workspace
  dockyard.down-fail   create it to make down exit 1 and stop nothing
  dockyard.nuke-fail   create it to make nuke exit 1 and remove nothing
  dockyard.prefix      holds text that the stack name starts with, as
                       if dockyard named stacks another way
  dockyard.claim       holds a directory; up of a new stack first
                       records it with that workspace, as if another up
                       got there first
  dockyard.web-url     holds the URL that up prints for the web UI
  bin/curl             curl shim: answers with the first line of
                       http/<port> and drops that line while more
                       follow, or fails as a closed port; logs each URL
                       to http/calls
  volumes.txt          the named volumes of the stacks, one per line
  bin/doppler          doppler shim: logs its arguments to doppler.log
                       and exits 1, so no call reaches Doppler
  <engine>.gone        ids that ps lists and inspect no longer knows
  <engine>.err         create it to make the engine print its content to
                       stderr and exit 1
  <engine>.inspect.err the same for inspect alone
  <engine>.log         one line per engine call
  env.sh               exports HOME, the XDG_CONFIG_HOME, XDG_CACHE_HOME,
                       XDG_DATA_HOME, and XDG_STATE_HOME dirs under
                       <root>, TMPDIR as <root>/.tmp, GIT_CONFIG_GLOBAL,
                       GIT_CONFIG_NOSYSTEM, WS_ROOT, WS_PROJECTS,
                       WS_VAULT, PATH, and a short TMUX_TMPDIR under
                       /tmp, and unsets TMUX and TMUX_PANE; remove
                       TMUX_TMPDIR with <root>
EOF
}

ticket=1
if [[ ${1-} == --no-ticket ]]; then
    ticket=0
    shift
fi
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
real_tmux=$(command -v tmux) || real_tmux=
mkdir -p "$root/origins" "$projects/notes" "$root/work" "$root/vault" "$root/bin" \
    "$root/.cache" "$root/.config" "$root/.local/share" "$root/.local/state" "$root/.tmp"
: >"$root/.zshrc"
# A socket path under <root> can pass the 108-byte limit.
tmux_dir=$(mktemp -d /tmp/wsx.XXXXXX)
trap 'rm -rf -- "$tmux_dir"' EXIT

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
export TMPDIR=$(printf %q "$root/.tmp")
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
if ((ticket)); then
    add_worktree alpha "$root/work/t1/alpha" feat/ticket
    add_worktree beta "$root/work/t1/beta" feat/ticket
fi

: >"$root/prs.tsv"
pr alpha feat/merged CLOSED 1 "$projects/alpha-merged"
pr alpha feat/merged MERGED 2 "$projects/alpha-merged"
pr alpha feat/dirty MERGED 3 "$projects/alpha-dirty"
pr alpha feat/unpushed MERGED 4 "$projects/alpha-unpushed"
pr alpha feat/closed CLOSED 5 "$projects/alpha-closed"
pr alpha feat/open OPEN 6 "$projects/alpha-open"
((ticket == 0)) || pr alpha feat/ticket OPEN 7 "$root/work/t1/alpha"
pr alpha feat/open MERGED 9 "$projects/alpha-open"
pr alpha feat/merged CLOSED 10 "$projects/alpha-merged"
pr alpha feat/dirty MERGED 11 "$projects/alpha-dirty"
((ticket == 0)) || pr beta feat/ticket MERGED 1 "$root/work/t1/beta"

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

cat >"$root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
engine=${0##*/}
printf '%s\n' "$*" >>"$root/$engine.log"
if [[ -f $root/$engine.err ]]; then
    cat "$root/$engine.err" >&2
    exit 1
fi
case "$*" in
"ps -q --no-trunc")
    jq -r '.[].Id' "$root/$engine.json"
    [[ ! -f $root/$engine.gone ]] || cat "$root/$engine.gone"
    ;;
"ps -q --filter label=com.docker.compose.project="*" --filter status=running")
    jq -r --arg p "${4#label=com.docker.compose.project=}" \
        '.[] | select(.Labels["com.docker.compose.project"] == $p) | .Id' "$root/$engine.json"
    ;;
"compose -p "*" logs --follow --tail 50")
    echo "$3 | fixture log line"
    [[ -f $root/$engine.logs-exit ]] || exec sleep infinity
    sleep 0.5
    ;;
"inspect "*)
    shift
    if [[ -f $root/$engine.inspect.err ]]; then
        cat "$root/$engine.inspect.err" >&2
        exit 1
    fi
    rc=0
    for id; do
        if ! jq -e --arg id "$id" 'any(.[]; .Id == $id)' "$root/$engine.json" >/dev/null; then
            echo "Error: No such object: $id" >&2
            rc=1
        fi
    done
    jq '[.[] | select(.Id | IN($ARGS.positional[]))]' "$root/$engine.json" --args "$@"
    exit "$rc"
    ;;
*)
    echo "$engine shim: unsupported call: $*" >&2
    exit 3
    ;;
esac
EOF
chmod +x "$root/bin/docker"
cp "$root/bin/docker" "$root/bin/podman"
echo '[]' >"$root/docker.json"
echo '[]' >"$root/podman.json"

cat >"$root/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$*" >>"$root/claude.log"
case ${1-} in
agents)
    if [[ " $* " == *" --json "* ]]; then
        cat "$root/agents.json"
        exit 0
    fi
    echo "claude agents (fixture shim)"
    read -r _ || true
    ;;
stop | kill)
    jq -e --arg id "${2-}" 'any(.[]; .id == $id)' "$root/agents.json" >/dev/null || {
        echo "No background session ${2-}" >&2
        exit 1
    }
    pid=$(jq -r --arg id "$2" '.[] | select(.id == $id) | .pid | numbers' "$root/agents.json")
    jq --arg id "$2" 'map(if .id == $id then .state = "stopped" | del(.pid, .status, .waitingFor) else . end)' \
        "$root/agents.json" >"$root/agents.json.new"
    mv "$root/agents.json.new" "$root/agents.json"
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
    ;;
*)
    echo "claude $* (fixture shim)"
    exec sleep infinity
    ;;
esac
EOF
chmod +x "$root/bin/claude"
echo '[]' >"$root/agents.json"

cat >"$root/bin/dockyard" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
state=$HOME/.dockyard
slots=$state/slots.json
printf '%s\t%s\n' "${DOCKYARD_WORKSPACE-}" "$*" >>"$root/dockyard.log"
log() { echo -e "\033[0;32m[dockyard]\033[0m $*"; }
die() {
    echo -e "\033[0;31m[dockyard]\033[0m $1" >&2
    exit "${2:-1}"
}
slugify() {
    [[ ! -f $root/dockyard.prefix ]] || printf '%s' "$(<"$root/dockyard.prefix")"
    echo "$1" | sed -E 's|^(feature\|fix\|hotfix\|release)/||' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' |
        sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}
save() {
    jq "$@" "$slots" >"$slots.tmp" && mv "$slots.tmp" "$slots"
}
containers() {
    jq "$@" "$root/docker.json" >"$root/docker.json.tmp" && mv "$root/docker.json.tmp" "$root/docker.json"
}
cmd=${1-} branch=${2-}
[[ -n $branch ]] || die "Usage: dockyard $cmd <branch>"
slug=$(slugify "$branch")
[[ -n $slug ]] || die "Branch '$branch' gives an empty stack name."
project=dockyard-$slug
record=""
[[ ! -f $slots ]] || record=$(jq -c --arg s "$slug" '.[$s] // empty' "$slots")
case $cmd in
up)
    workspace=""
    if [[ -n ${DOCKYARD_WORKSPACE-} ]]; then
        [[ -d $DOCKYARD_WORKSPACE ]] || die "DOCKYARD_WORKSPACE is not a directory: $DOCKYARD_WORKSPACE"
        workspace=$(cd -P -- "$DOCKYARD_WORKSPACE" && pwd -P)
    fi
    log "Feature: $branch (slug: $slug)"
    if [[ -z $record && -f $root/dockyard.claim ]]; then
        mkdir -p "$state"
        [[ -f $slots ]] || echo '{}' >"$slots"
        save --arg s "$slug" --arg w "$(<"$root/dockyard.claim")" \
            '.[$s] = {slot: 9, repos: [], profiles: [], created: "2026-01-01T00:00:00Z", workspace: $w}'
        record=$(jq -c --arg s "$slug" '.[$s]' "$slots")
    fi
    created=""
    if [[ -n $record ]]; then
        recorded=$(jq -r '.workspace // ""' <<<"$record")
        [[ -z $workspace || $workspace == "$recorded" ]] ||
            die "stack $slug is registered with workspace ${recorded:-none}; run nuke first"
        workspace=$recorded
        slot=$(jq -r .slot <<<"$record")
        log "Stack already registered (slot $slot). Restarting..."
    else
        [[ ! -f $root/dockyard.lock ]] ||
            die "Timed out after 10s waiting for $state/slots.lock.d, which process 1 holds." 2
        mkdir -p "$state"
        [[ -f $slots ]] || echo '{}' >"$slots"
        slot=$(jq '[.[].slot] as $used | first(range(1; infinite) | select(IN($used[]) | not))' "$slots")
        save --arg s "$slug" --argjson slot "$slot" --arg w "$workspace" \
            '.[$s] = {slot: $slot, repos: [], profiles: [], created: "2026-01-01T00:00:00Z", workspace: $w}'
        log "Allocated slot $slot — web-ui:$((4000 + slot * 100)) gateway:$((8000 + slot * 100))"
        created=1
    fi
    if [[ -f $root/dockyard.build ]]; then
        echo -e "\033[0;31m[dockyard]\033[0m Build failed. Last 30 lines:" >&2
        [[ -z $created ]] ||
            echo -e "\033[0;31m[dockyard]\033[0m Run 'dockyard nuke $branch' to remove what this up created." >&2
        exit 1
    fi
    containers --arg p "$project" 'map(select(.Labels["com.docker.compose.project"] != $p))
        + [{Id: "id-\($p)-redis-1", Name: "/\($p)-redis-1", Mounts: [], Labels: {"com.docker.compose.project": $p}}]'
    for dir in "$workspace"/*/; do
        [[ -n $workspace && -d $dir ]] || continue
        dir=${dir%/}
        containers --arg p "$project" --arg n "$project-${dir##*/}-1" --arg src "$dir" \
            '. + [{Id: "id-\($n)", Name: "/\($n)", Mounts: [{Type: "bind", Source: $src, Destination: "/app"}],
                Labels: {"com.docker.compose.project": $p}}]'
    done
    for volume in web-node-modules api-node-modules; do
        grep -qxF "${project}_$volume" "$root/volumes.txt" 2>/dev/null || echo "${project}_$volume" >>"$root/volumes.txt"
    done
    log "Services started."
    echo
    echo -e "\033[1mStack: $slug\033[0m"
    web=http://localhost:$((4000 + slot * 100))
    [[ ! -f $root/dockyard.web-url ]] || web=$(<"$root/dockyard.web-url")
    echo -e "  \033[0;34mWeb UI:\033[0m           $web"
    echo -e "  \033[0;34mAPI Gateway:\033[0m      http://localhost:$((8000 + slot * 100))"
    echo -e "  \033[0;34mPortal:\033[0m           (internal, routed via gateway)"
    ;;
down)
    [[ -n $record ]] || die "No stack found for '$branch' (slug: $slug)"
    [[ ! -f $root/dockyard.down-fail ]] || die "compose down failed"
    containers --arg p "$project" 'map(select(.Labels["com.docker.compose.project"] != $p))'
    [[ ! -f $root/dockyard.steal ]] || save --arg s "$slug" --arg w "$(<"$root/dockyard.steal")" '.[$s].workspace = $w'
    log "Stack stopped. Volumes preserved. Use 'dockyard up $branch' to restart."
    ;;
nuke)
    [[ -n $record ]] || die "No stack found for '$branch' (slug: $slug)"
    [[ ! -f $root/dockyard.nuke-fail ]] || die "compose down failed, so the slot, worktrees, and Doppler config are kept."
    workspace=$(jq -r '.workspace // ""' <<<"$record")
    if [[ -n $workspace && -e $workspace ]]; then
        printf 'nuke %s: workspace exists\n' "$slug" >>"$root/dockyard.log"
    else
        printf 'nuke %s: workspace gone\n' "$slug" >>"$root/dockyard.log"
    fi
    containers --arg p "$project" 'map(select(.Labels["com.docker.compose.project"] != $p))'
    if [[ -f $root/volumes.txt ]]; then
        grep -v "^${project}_" "$root/volumes.txt" >"$root/volumes.tmp" || true
        mv "$root/volumes.tmp" "$root/volumes.txt"
    fi
    save --arg s "$slug" 'del(.[$s])'
    log "Stack $slug completely removed."
    ;;
*) die "dockyard shim: unsupported call: $*" 3 ;;
esac
EOF
chmod +x "$root/bin/dockyard"

mkdir -p "$root/http"
cat >"$root/bin/curl" <<'EOF'
#!/usr/bin/env bash
http=$(cd "$(dirname "$0")/../http" && pwd)
url=${*: -1}
port=${url##*:}
port=${port%%/*}
printf '%s\n' "$url" >>"$http/calls"
if [[ ! -s $http/$port ]]; then
    printf 000
    exit 7
fi
code=$(head -n 1 "$http/$port")
(($(wc -l <"$http/$port") < 2)) || sed -i 1d "$http/$port"
printf '%s' "$code"
EOF
chmod +x "$root/bin/curl"

cat >"$root/bin/doppler" <<'EOF'
#!/usr/bin/env bash
root=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$*" >>"$root/doppler.log"
echo "doppler shim: no call reaches Doppler" >&2
exit 1
EOF
chmod +x "$root/bin/doppler"

if [[ -n $real_tmux ]]; then
    printf '#!/usr/bin/env bash\nexec %q -L wsfx "$@"\n' "$real_tmux" >"$root/bin/tmux"
    chmod +x "$root/bin/tmux"
fi
trap - EXIT
