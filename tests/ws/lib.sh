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
    # shellcheck source=/dev/null
    source "$sandbox/root/env.sh"
}

ws() {
    bash "$WS_TESTS/../../dotfiles/bin/ws" "$@"
}

finish() {
    if ((_failures)); then
        echo "$_failures failed"
        exit 1
    fi
    echo "all passed"
}
