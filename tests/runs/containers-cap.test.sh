#!/usr/bin/env bash
set -uo pipefail

if [[ -z ${CAP_TEST_INSIDE-} ]]; then
    CAP_TEST_INSIDE=1 exec unshare -rm bash "$0" "$@"
fi

fixes=$(cd "$(dirname "$0")/../.." && pwd)/runs/99-fixes
failures=0
dir=$(mktemp -d) || exit 2
trap 'rm -rf "$dir"' EXIT

ok() { printf 'ok    %s\n' "$1"; }
not_ok() {
    printf 'FAIL  %s\n' "$1"
    failures=$((failures + 1))
}
assert() {
    local desc=$1
    shift
    if "$@"; then ok "$desc"; else not_ok "$desc"; fi
}
assert_eq() {
    if [[ $2 == "$3" ]]; then
        ok "$1"
    else
        not_ok "$1"
        printf '      expected: %s\n      actual:   %s\n' "$2" "$3"
    fi
}

mount -t tmpfs tmpfs /etc || exit 2
[[ $(stat -f -c %T /etc) == tmpfs ]] || exit 2
mkdir -p /etc/systemd/system

block=$(awk '/^# Run every Docker container under containers.slice/ { on = 1 } on && /^$/ { exit } on' "$fixes")
[[ -n $block ]] || not_ok "runs/99-fixes has a containers.slice block"

mkdir -p "$dir/bin" "$dir/state"
cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$CAP_LOG"
exec "$@"
EOF
cat >"$dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"is-active docker" | "is-active --quiet docker")
    if [[ -e $CAP_STATE/chroot ]]; then
        echo "Running in chroot, ignoring command 'is-active'" >&2
        exit 0
    fi
    state=inactive
    [[ -e $CAP_STATE/active ]] && state=active
    [[ $* == *--quiet* ]] || echo "$state"
    [[ $state == active ]] || exit 3
    ;;
"daemon-reload" | "restart docker") printf 'systemctl %s\n' "$*" >>"$CAP_LOG" ;;
*)
    echo "systemctl shim: unsupported call: $*" >&2
    exit 3
    ;;
esac
EOF
cat >"$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"-H unix:///var/run/docker.sock ps -q") daemon=system ;;
"ps -q") daemon=${DOCKER_HOST:-system} ;;
*)
    echo "docker shim: unsupported call: $*" >&2
    exit 3
    ;;
esac
if [[ -e $CAP_STATE/denied || -e $CAP_STATE/chroot ]]; then
    echo "cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2
    exit 1
fi
[[ $daemon != system ]] || cat "$CAP_STATE/containers"
EOF
chmod +x "$dir/bin/sudo" "$dir/bin/systemctl" "$dir/bin/docker"
export PATH=$dir/bin:$PATH CAP_LOG=$dir/log CAP_STATE=$dir/state

slice=/etc/systemd/system/containers.slice
conf=/etc/docker/daemon.json
slice_text=$'[Unit]\nDescription=All Docker containers, under one shared memory cap\n\n[Slice]\nMemoryMax=80%\n'
conf_text=$'{\n  "cgroup-parent": "containers.slice"\n}\n'
restart_hint="sudo systemctl restart docker"

run_block() {
    : >"$CAP_LOG"
    "$@" bash -c "$block" 2>&1
}
docker_state() {
    rm -f "$CAP_STATE/active" "$CAP_STATE/denied" "$CAP_STATE/chroot"
    : >"$CAP_STATE/containers"
    local word
    for word in "$@"; do
        case $word in
        active | denied | chroot) : >"$CAP_STATE/$word" ;;
        running) printf '3f2a9c1d7e6b\n8c4d0e5f1a2b\n' >"$CAP_STATE/containers" ;;
        esac
    done
}
systemctl_calls() { grep '^systemctl' "$CAP_LOG"; }
same_json() { [[ $(jq -S -c . "$1") == "$(jq -S -c . <<<"$2")" ]]; }
contains() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
put_conf() {
    mkdir -p "${conf%/*}"
    printf '%s\n' "$1" >"$conf"
}
stamp() { stat -c '%i %Y %s' "$@" 2>/dev/null; }
unchanged() {
    local before=$1
    shift
    [[ -n $before && $before == "$(stamp "$@")" ]]
}

docker_state
out=$(run_block)
assert "a first run writes containers.slice byte for byte" cmp -s "$slice" <(printf '%s' "$slice_text")
assert "it creates /etc/docker and writes daemon.json byte for byte" cmp -s "$conf" <(printf '%s' "$conf_text")
assert_eq "it reloads systemd and, with Docker stopped, restarts nothing" "systemctl daemon-reload" "$(systemctl_calls)"
assert "it prints no restart hint, since Docker reads daemon.json when it starts" lacks "$out" "$restart_hint"

docker_state active running
before=$(stamp "$slice" "$conf")
sleep 1.1
out=$(run_block)
assert_eq "a second run runs no sudo command" "" "$(cat "$CAP_LOG")"
assert_eq "it prints nothing" "" "$out"
assert "it leaves both files as they were" unchanged "$before" "$slice" "$conf"

rm -f "$slice"
put_conf '{ "cgroup-parent": "containers.slice" }'
docker_state active running
before=$(stamp "$conf")
sleep 1.1
out=$(run_block)
assert "a run with daemon.json already set by hand writes containers.slice back" \
    cmp -s "$slice" <(printf '%s' "$slice_text")
assert "it leaves that daemon.json as it was" unchanged "$before" "$conf"
assert_eq "it reloads systemd and restarts nothing" "systemctl daemon-reload" "$(systemctl_calls)"

put_conf '{"log-driver": "local", "log-opts": {"max-size": "10m"}, "registry-mirrors": ["https://mirror.example.invalid"]}'
docker_state
run_block >/dev/null
assert "a run on a daemon.json with other keys keeps them and adds cgroup-parent" same_json "$conf" \
    '{"log-driver": "local", "log-opts": {"max-size": "10m"}, "registry-mirrors": ["https://mirror.example.invalid"], "cgroup-parent": "containers.slice"}'

put_conf '{"cgroup-parent": "docker.slice", "log-driver": "local"}'
docker_state active running
out=$(run_block)
assert "a run that changes daemon.json while containers run sets cgroup-parent" \
    same_json "$conf" '{"cgroup-parent": "containers.slice", "log-driver": "local"}'
assert_eq "it restarts nothing" "" "$(systemctl_calls)"
assert "it tells the operator to run '$restart_hint'" contains "$out" "$restart_hint"

rm -f "$conf"
docker_state active
run_block >/dev/null
assert_eq "a run that changes daemon.json while no container runs restarts Docker" "systemctl restart docker" \
    "$(systemctl_calls)"

rm -f "$conf"
docker_state active denied
out=$(run_block)
assert_eq "a run that cannot list containers restarts nothing" "" "$(systemctl_calls)"
assert "it tells the operator to run '$restart_hint'" contains "$out" "$restart_hint"

rm -f "$conf"
docker_state
out=$(run_block)
assert "a run that changes daemon.json while Docker is stopped writes it" cmp -s "$conf" <(printf '%s' "$conf_text")
assert_eq "it restarts nothing" "" "$(systemctl_calls)"
assert "it prints no restart hint" lacks "$out" "$restart_hint"

put_conf '{"log-driver": "local",'
docker_state active
before=$(stamp "$conf")
sleep 1.1
out=$(run_block)
assert "a run on a daemon.json that is not valid JSON leaves it as it was" unchanged "$before" "$conf"
assert_eq "it runs no sudo command" "" "$(cat "$CAP_LOG")"
assert "it names the file to fix by hand" contains "$out" "$conf"

rm -f "$conf"
docker_state active running
out=$(DOCKER_HOST=unix:///run/user/1000/docker.sock run_block)
assert_eq "a run whose DOCKER_HOST names another daemon restarts nothing while system containers run" "" \
    "$(systemctl_calls)"
assert "it tells the operator to run '$restart_hint'" contains "$out" "$restart_hint"

rm -f "$conf"
docker_state chroot
out=$(run_block)
assert "a run inside the installer chroot writes daemon.json" cmp -s "$conf" <(printf '%s' "$conf_text")
assert_eq "it restarts nothing" "" "$(systemctl_calls)"
assert "it prints no restart hint" lacks "$out" "$restart_hint"

put_conf '{"log-driver": "local", "cgroup-parent": "docker.slice"}'
chmod 000 /etc/docker
docker_state active
before=$(stamp "$conf")
out=$(run_block setpriv --inh-caps=-all --bounding-set=-all)
chmod 755 /etc/docker
assert_eq "a run that cannot search /etc/docker runs no sudo command" "" "$(cat "$CAP_LOG")"
assert "it leaves daemon.json as it was" unchanged "$before" "$conf"
assert "it names the file to fix by hand" contains "$out" "$conf"

if ((failures)); then
    echo "$failures failed"
    exit 1
fi
echo "all passed"
