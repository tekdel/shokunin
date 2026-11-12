#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<'EOF'
usage: CLAUDE_CODE_OAUTH_TOKEN=<token> WS_LIVE_ID=<id> bash tests/ws/verify.live.sh

Runs the S4 lanes that need a real model and a running env, with the ws of
this checkout, the real claude, and the caller's HOME, WS_ROOT, and WS_VAULT.
WS_LIVE_ID names a ticket whose env is up (ws up) and whose scenarios ws
scenarios wrote. Captures go to WS_LIVE_OUT, ~/work-evidence/S4/live by
default.

  lane 4   a session named <id>-verify shows in claude agents --json
  lane 5   the evidence directory holds results.md and S<n>.png per scenario
  lane 6   WS_LIVE_BREAK, a command that breaks one behavior, makes a scenario
           fail and leaves the stage at building; WS_LIVE_FIX undoes it
  lane 7   the verify transcript reads qa-calibration.md
  lane 9   every URL in the transcript's tool calls is on localhost
  perf     WS_LIVE_PERF=1 runs ws verify three times; the median must stay
           under 15 minutes. It prints each run's cost, or its tokens when
           the transcript holds no cost, for a manual check against 2 USD.
EOF
}

here=$(cd "$(dirname "$0")" && pwd)
ws_bin=$here/../../dotfiles/bin/ws
out=${WS_LIVE_OUT:-$HOME/work-evidence/S4/live}
id=${WS_LIVE_ID-}
fails=0

if [[ ${1-} == -h || ${1-} == --help ]]; then
    usage
    exit 0
fi
if [[ -z ${CLAUDE_CODE_OAUTH_TOKEN-} || -z $id ]]; then
    echo "skip live lanes 4, 5, 6, 7, 9 and the perf probe: they need CLAUDE_CODE_OAUTH_TOKEN and WS_LIVE_ID, a ticket whose env is up and whose scenarios are written, so they run once after merge"
    exit 0
fi

check() {
    local desc=$1
    shift
    if "$@"; then
        printf 'PASS  %s\n' "$desc"
    else
        printf 'FAIL  %s\n' "$desc"
        fails=$((fails + 1))
    fi
}

stage() {
    sed -n 's/^WS_STAGE=//p' "${WS_ROOT:-$HOME/work}/$id/.ws"
}

evidence_of() {
    local dir
    dir=$(sed -n 's|^Waiting for \(.*\)/results\.md, at most .*|\1|p' "$1" | tail -n 1)
    printf '%s\n' "${dir/#\~/$HOME}"
}

transcript_of() {
    grep -lF -- "\"cwd\":\"$1\"" "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -n 1
}

tool_inputs() {
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name) \(.input | tojson)"' "$1"
}

run_verify() {
    local start rc
    start=$EPOCHSECONDS
    bash "$ws_bin" verify "$id" >"$1" 2>&1
    rc=$?
    echo "$((EPOCHSECONDS - start)) $rc"
}

mkdir -p "$out"
scenarios=$(sed -n 's/^## \(S[0-9][0-9]*\)\. .*/\1/p' \
    "${WS_VAULT:-$HOME/claude-knowledge-vault}/projects/work/$(sed -n 's/^WS_TOPIC=//p' "${WS_ROOT:-$HOME/work}/$id/.ws")/scenarios/$id.md")

run_verify "$out/verify-1.out" >"$out/verify-1.time" &
pid=$!
: >"$out/s4-l4-bg.txt"
for _ in $(seq 120); do
    claude agents --json </dev/null 2>/dev/null | jq -c --arg n "$id-verify" '.[] | select(.name == $n)' >"$out/s4-l4-bg.txt"
    [[ ! -s $out/s4-l4-bg.txt ]] || break
    sleep 1
done
check "lane 4: claude agents lists a session named $id-verify" test -s "$out/s4-l4-bg.txt"
wait "$pid"
read -r secs rc <"$out/verify-1.time"
ev=$(evidence_of "$out/verify-1.out")
cat "$out/verify-1.out"

{
    echo "ws verify exit $rc in $secs s; evidence at $ev"
    ls -lAR "$ev"
} >"$out/s4-l5-evidence.txt"
check "lane 5: the evidence directory holds results.md" test -s "$ev/results.md"
for s in $scenarios; do
    check "lane 5: it holds a screenshot $s.png" test -n "$(find "$ev" -name "$s.png" -print -quit)"
done

transcript=$(transcript_of "$ev")
tool_inputs "$transcript" >"$out/tools.txt" 2>/dev/null
grep -F qa-calibration.md "$out/tools.txt" >"$out/s4-l7-calibration.txt"
check "lane 7: the verify session read qa-calibration.md" grep -q '^Read .*qa-calibration\.md' "$out/s4-l7-calibration.txt"

grep -oE 'https?://[^/"\\ ]+' "$out/tools.txt" | sort -u >"$out/s4-l9-noprod.txt"
check "lane 9: every URL in the tool calls is on localhost" \
    test -z "$(grep -vE '^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?$' "$out/s4-l9-noprod.txt")"

if [[ -n ${WS_LIVE_BREAK-} && -n ${WS_LIVE_FIX-} ]]; then
    bash "$ws_bin" stage "$id" building
    bash -c "$WS_LIVE_BREAK"
    run_verify "$out/s4-l6-fail.txt" >/dev/null
    bash -c "$WS_LIVE_FIX"
    cat "$out/s4-l6-fail.txt"
    check "lane 6: the stage stays building" test "$(stage)" = building
    check "lane 6: results.md names a failed scenario" grep -qE '^RESULT S[0-9]+ FAIL' "$(evidence_of "$out/s4-l6-fail.txt")/results.md"
else
    echo "skip lane 6: set WS_LIVE_BREAK and WS_LIVE_FIX to break one behavior and undo it"
fi

if [[ ${WS_LIVE_PERF-} == 1 ]]; then
    echo "$secs" >"$out/perf.tsv"
    for n in 2 3; do
        run_verify "$out/perf-$n.out" | cut -d ' ' -f 1 >>"$out/perf.tsv"
    done
    median=$(sort -n "$out/perf.tsv" | sed -n 2p)
    echo "perf: ws verify wall times $(paste -sd ' ' "$out/perf.tsv") s, median $median s"
    for f in "$out"/verify-1.out "$out"/perf-2.out "$out"/perf-3.out; do
        t=$(transcript_of "$(evidence_of "$f")")
        jq -sc '{usd: ([.[] | .costUSD // empty] | add), input_tokens: ([.[] | .message.usage? | objects
            | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)] | add),
            output_tokens: ([.[] | .message.usage? | objects | .output_tokens // 0] | add)}' "$t"
    done | sed 's/^/perf: model use of one run: /'
    check "perf: the median wall time is under 15 minutes" test "$median" -le 900
else
    echo "skip the perf probe: set WS_LIVE_PERF=1 to run ws verify three times"
fi

echo "captures in $out"
((fails == 0))
