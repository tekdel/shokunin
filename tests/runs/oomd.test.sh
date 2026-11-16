#!/usr/bin/env bash
# Runs the systemd-oomd block of runs/99-fixes as root of a user namespace, over a tmpfs at
# /etc/systemd/system, with shims for sudo and systemctl, so nothing it writes reaches the host.
set -uo pipefail

if [[ -z ${OOMD_TEST_INSIDE-} ]]; then
    OOMD_TEST_INSIDE=1 exec unshare -rm bash "$0" "$@"
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

mount -t tmpfs tmpfs /etc/systemd/system || exit 2
[[ $(stat -f -c %T /etc/systemd/system) == tmpfs ]] || exit 2

block=$(awk '/^# Keep systemd-oomd watching memory/ { on = 1 } on && /^$/ { exit } on' "$fixes")
[[ -n $block ]] || not_ok "runs/99-fixes has a systemd-oomd block"

mkdir -p "$dir/bin" "$dir/state"
cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$OOMD_LOG"
exec "$@"
EOF
cat >"$dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"is-enabled --quiet systemd-oomd") [[ -e $OOMD_STATE/enabled ]] ;;
"is-active --quiet systemd-oomd") [[ -e $OOMD_STATE/active ]] ;;
"daemon-reload") printf 'systemctl %s\n' "$*" >>"$OOMD_LOG" ;;
"enable --now systemd-oomd")
    printf 'systemctl %s\n' "$*" >>"$OOMD_LOG"
    : >"$OOMD_STATE/enabled"
    : >"$OOMD_STATE/active"
    ;;
*)
    echo "systemctl shim: unsupported call: $*" >&2
    exit 3
    ;;
esac
EOF
chmod +x "$dir/bin/sudo" "$dir/bin/systemctl"
export PATH=$dir/bin:$PATH OOMD_LOG=$dir/log OOMD_STATE=$dir/state

user=/etc/systemd/system/user@.service.d/oomd.conf
slice=/etc/systemd/system/-.slice.d/oomd.conf
user_text=$'[Service]\nManagedOOMMemoryPressure=kill\nManagedOOMMemoryPressureLimit=60%\n'
slice_text=$'[Slice]\nManagedOOMSwap=kill\n'

run_block() {
    : >"$OOMD_LOG"
    bash -c "$block" 2>&1
}

out=$(run_block)
assert "a first run writes the user@.service drop-in byte for byte" cmp -s "$user" <(printf '%s' "$user_text")
assert "it writes the -.slice drop-in byte for byte" cmp -s "$slice" <(printf '%s' "$slice_text")
assert_eq "it reloads systemd, then enables and starts systemd-oomd" \
    $'systemctl daemon-reload\nsystemctl enable --now systemd-oomd' "$(grep '^systemctl' "$OOMD_LOG")"
assert_eq "it says what it did" \
    $'Writing the systemd-oomd drop-ins...\n✓ systemd-oomd drop-ins written\nEnabling systemd-oomd...\n✓ systemd-oomd enabled' "$out"

before=$(stat -c '%i %Y %s' "$user" "$slice")
sleep 1.1
out=$(run_block)
assert_eq "a second run runs no sudo command" "" "$(cat "$OOMD_LOG")"
assert_eq "it prints nothing" "" "$out"
assert_eq "it leaves both files as they were" "$before" "$(stat -c '%i %Y %s' "$user" "$slice")"

printf '[Service]\nManagedOOMMemoryPressure=kill\nManagedOOMMemoryPressureLimit=50%%\n' >"$user"
out=$(run_block)
assert "a run after someone changed a drop-in writes its content back" cmp -s "$user" <(printf '%s' "$user_text")
assert_eq "it reloads systemd and enables nothing, since systemd-oomd runs" "systemctl daemon-reload" \
    "$(grep '^systemctl' "$OOMD_LOG")"

rm "$OOMD_STATE/active"
out=$(run_block)
assert_eq "a run while systemd-oomd is stopped writes nothing and only starts it" "sudo systemctl enable --now systemd-oomd" \
    "$(grep "^sudo" "$OOMD_LOG")"

if ((failures)); then
    echo "$failures failed"
    exit 1
fi
echo "all passed"
