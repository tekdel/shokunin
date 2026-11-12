#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

export WS_VERIFY_POLL=0.1

ws_value() {
    sed -n "s/^$2=//p" "$WS_ROOT/$1/.ws"
}

scenarios_of() {
    echo "$WS_VAULT/projects/work/$1/scenarios/$1.md"
}

evidence_of() {
    echo "$WS_VAULT/projects/work/$1/evidence/$1/$(date +%F)"
}

shown() {
    echo "${1/#"$HOME/"/\~/}"
}

ticket_with_scenarios() {
    ws new "$@" >/dev/null 2>&1
    printf 'As a user I can undo a save.\n' >"$FX/ticket.txt"
    ws scenarios "$1" --from "$FX/ticket.txt" >/dev/null 2>&1 || abort "ws scenarios $1 failed"
}

ticket_ready() {
    ticket_with_scenarios t1 feat/x alpha
    ws up t1 >/dev/null 2>&1 || abort "ws up t1 failed"
    echo 0.3 >"$FX/verify.delay"
}

results() {
    printf 'Opened the page and pressed Save.\n\n' >"$FX/verify.results"
    printf 'RESULT %s\n' "$@" >>"$FX/verify.results"
}

bg_args() {
    mapfile -d '' BG_ARGS <"$FX/claude.bg-args"
}

test_new_writes_the_deny_rules() {
    local settings vault root rules out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    settings=$WS_ROOT/t1/.claude/settings.json
    vault=$(realpath -m "$WS_VAULT") root=$(realpath -m "$WS_ROOT")
    rules="[\"Edit(/$vault/projects/work/t1/scenarios/t1.md)\",\"Edit(/$root/t1/.ws)\",\"Edit(/$vault/projects/work/t1/evidence/t1/**)\"]"
    assert_eq "new denies Claude edits of the ticket's scenarios, its .ws, and its evidence by absolute path" "$rules" \
        "$(jq -c .permissions.deny "$settings")"

    jq '.permissions.allow = ["Bash(npm test)"] | .model = "opus" | .permissions.deny |= .[:1]' "$settings" >"$FX/s.json"
    cp "$FX/s.json" "$settings"
    ws new t1 feat/x alpha beta >/dev/null 2>&1
    assert_eq "a rerun keeps what someone added and adds each missing rule once" "[\"Bash(npm test)\"] opus $rules" \
        "$(jq -r '"\(.permissions.allow | tojson) \(.model) \(.permissions.deny | tojson)"' "$settings")"

    ws new --topic billing t2 feat/y alpha >/dev/null 2>&1
    assert_eq "the rules follow the ticket's topic" \
        "[\"Edit(/$vault/projects/work/billing/scenarios/t2.md)\",\"Edit(/$root/t2/.ws)\",\"Edit(/$vault/projects/work/billing/evidence/t2/**)\"]" \
        "$(jq -c .permissions.deny "$WS_ROOT/t2/.claude/settings.json")"

    mkdir -p "$WS_ROOT/t3/.claude"
    echo '{"permissions": "ask"}' >"$WS_ROOT/t3/.claude/settings.json"
    out=$(ws new t3 feat/z alpha 2>&1) && rc=0 || rc=$?
    assert_eq "new exits 1 when settings.json has no deny list it can extend" 1 "$rc"
    assert "it says why" grep -qxF \
        "ws: ~/work/t3/.claude/settings.json does not hold a settings object with a permissions.deny list, so ws adds no deny rules to it" \
        <<<"$out"
    assert_eq "it leaves that file as it was" '{"permissions": "ask"}' "$(cat "$WS_ROOT/t3/.claude/settings.json")"
}

test_scenarios_from_a_file() {
    local out rc file
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    printf 'As a user I can undo a save.\n' >"$FX/ticket.txt"
    cat >"$FX/claude.result" <<'EOF'
Here are the scenarios.

```markdown
## S1. Undo

Given a save
When I undo
Then it is gone

## S2. Redo

Given an undo
When I redo
Then it is back
```
EOF
    out=$(ws scenarios t1 --from "$FX/ticket.txt" 2>&1) && rc=0 || rc=$?
    file=$(scenarios_of t1)
    assert_eq "scenarios exits 0" 0 "$rc"
    assert "it says how many it wrote and where" grep -qxF "Wrote 2 scenarios to ~/vault/projects/work/t1/scenarios/t1.md" <<<"$out"
    assert_eq ".ws holds the sha256 of the file" "$(sha256sum "$file" | cut -d ' ' -f 1)" "$(ws_value t1 WS_SCENARIOS_SHA256)"
    assert_eq "the file holds the scenarios without the text around them" \
        $'## S1. Undo\n\nGiven a save\nWhen I undo\nThen it is gone\n\n## S2. Redo\n\nGiven an undo\nWhen I redo\nThen it is back' \
        "$(sed -n '/^## S1/,$p' "$file")"
    assert_eq "it starts with a header that names the ticket and the source" \
        "# Scenarios for t1|ws scenarios wrote this file on $(date +%F) from the ticket text in ~/ticket.txt. ws verify refuses to run once anything else changes it." \
        "$(sed -n '1p;3p' "$file" | paste -sd '|')"
    assert_eq "claude -p runs in the vault" "$(realpath "$WS_VAULT")" "$(cat "$FX/claude.cwd")"
    assert "with no built-in tools and no MCP server" grep -qxF -- "-p --output-format json --tools  --strict-mcp-config" "$FX/claude.log"
    assert "the prompt ends with the ticket text" test "$(tail -n 2 "$FX/claude.prompt")" = $'TICKET TEXT\nAs a user I can undo a save.'
    assert "the prompt says the session that builds the ticket cannot edit the scenarios" grep -qF \
        "A separate Claude session builds the ticket and cannot edit these scenarios." "$FX/claude.prompt"
    refute "and does not claim that session never sees them" grep -qF "never sees" "$FX/claude.prompt"
}

test_scenarios_from_jira() {
    local out rc
    new_fixture_no_ticket
    ws new --ticket KEY-7 t1 feat/x alpha >/dev/null 2>&1
    out=$(ws scenarios t1 2>&1) && rc=0 || rc=$?
    assert_eq "scenarios without --from exits 0" 0 "$rc"
    assert "claude -p may call only the read tool of the atlassian MCP server" grep -qxF -- \
        "-p --output-format json --tools  --allowedTools mcp__atlassian__getJiraIssue" "$FX/claude.log"
    assert "the prompt asks it to read the issue with that tool" grep -qF \
        "Read the Jira issue KEY-7 with the tool mcp__atlassian__getJiraIssue." "$FX/claude.prompt"
    assert "and to say when it cannot" grep -qF 'print exactly "ws: cannot read KEY-7" and nothing else' "$FX/claude.prompt"
    assert_eq "the file names the issue" "ws scenarios wrote this file on $(date +%F) from the Jira issue KEY-7. ws verify refuses to run once anything else changes it." \
        "$(sed -n 3p "$(scenarios_of t1)")"

    WS_JIRA_MCP=jira WS_JIRA_TOOL=get_issue ws scenarios t1 >/dev/null 2>&1
    assert "WS_JIRA_MCP and WS_JIRA_TOOL name another server and its read tool" grep -qxF -- \
        "-p --output-format json --tools  --allowedTools mcp__jira__get_issue" "$FX/claude.log"

    : >"$FX/claude.log"
    out=$(WS_JIRA_TOOL="getJiraIssue mcp__atlassian" ws scenarios t1 2>&1) && rc=0 || rc=$?
    assert_eq "scenarios refuses a tool name that would allow more than one tool" \
        "1 ws: WS_JIRA_MCP and WS_JIRA_TOOL take ASCII letters, digits, dashes, and underscores" "$rc $out"
    refute "it runs no claude -p then" grep -q -- "^-p " "$FX/claude.log"

    ws new t2 feat/y beta >/dev/null 2>&1
    : >"$FX/claude.log"
    out=$(ws scenarios t2 2>&1) && rc=0 || rc=$?
    assert_eq "scenarios exits 1 for a ticket with no WS_TICKET and no --from" 1 "$rc"
    assert_eq "it says to pass the text" \
        "ws: t2 has no WS_TICKET, so ws cannot ask Jira for it; pass --from <file> with the ticket text" "$out"
    refute "it runs no claude -p" grep -q -- "^-p " "$FX/claude.log"
}

test_scenarios_refuses_bad_output() {
    local out rc file sum
    new_fixture_no_ticket
    ticket_with_scenarios t1 feat/x alpha
    file=$(scenarios_of t1)
    sum=$(ws_value t1 WS_SCENARIOS_SHA256)
    cp "$file" "$FX/before.md"

    echo "ws: cannot read t1" >"$FX/claude.result"
    out=$(ws scenarios t1 --from "$FX/ticket.txt" 2>&1) && rc=0 || rc=$?
    assert_eq "scenarios exits 1 when claude writes no scenario" 1 "$rc"
    assert "it says so and shows what claude wrote" test "$out" = \
        $'ws: claude wrote no scenarios headed ## S1. to ## S<n>. in order, so t1 has no new scenarios. It wrote:\nws: cannot read t1'
    assert_eq "it keeps the earlier file" "$(cat "$FX/before.md")" "$(cat "$file")"
    assert_eq "and its hash" "$sum" "$(ws_value t1 WS_SCENARIOS_SHA256)"

    printf '## S1. One\n\nThen a\n\n## S3. Three\n\nThen c\n' >"$FX/claude.result"
    out=$(ws scenarios t1 --from "$FX/ticket.txt" 2>&1) && rc=0 || rc=$?
    assert_eq "scenarios exits 1 when the numbers skip one" 1 "$rc"
    assert_eq "it keeps the earlier file then too" "$(cat "$FX/before.md")" "$(cat "$file")"

    rm "$FX/claude.result"
    touch "$FX/claude.p-fail"
    out=$(ws scenarios t1 --from "$FX/ticket.txt" 2>&1) && rc=0 || rc=$?
    assert_eq "scenarios exits 1 when claude -p fails" 1 "$rc"
    assert "it says so" grep -qxF "ws: claude -p failed with status 1, so t1 has no new scenarios" <<<"$out"

    out=$(ws scenarios t1 --from "$FX/no-such-file" 2>&1) && rc=0 || rc=$?
    assert_eq "scenarios exits 1 for a --from file that does not exist" 1 "$rc"
    assert_eq "it says what --from takes" "ws: --from takes a readable file that holds the ticket text" "$out"
    refute "no scenarios file is left half written" compgen -G "${file%/*}/.t1.md.*"
}

test_scenarios_inside_a_claude_session() {
    local out rc file sum
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    printf 'As a user I can undo a save.\n' >"$FX/ticket.txt"
    out=$(CLAUDECODE=1 ws scenarios t1 --from "$FX/ticket.txt" 2>&1) && rc=0 || rc=$?
    assert_eq "inside a Claude session, scenarios writes the first scenarios of a ticket" 0 "$rc"
    file=$(scenarios_of t1)
    sum=$(ws_value t1 WS_SCENARIOS_SHA256)
    cp "$file" "$FX/before.md"

    printf '## S1. Page loads\n\nGiven the app\nWhen I open it\nThen it loads\n' >"$FX/claude.result"
    : >"$FX/claude.log"
    out=$(CLAUDECODE=1 ws scenarios t1 --from "$FX/ticket.txt" 2>&1) && rc=0 || rc=$?
    assert_eq "it refuses to replace them and names the flag that does" \
        "1 ws: t1 has scenarios, and CLAUDECODE says this runs inside a Claude session; pass --replace to replace them" "$rc $out"
    refute "it runs no claude -p" grep -q -- "^-p " "$FX/claude.log"
    assert_eq "it keeps the file" "$(cat "$FX/before.md")" "$(cat "$file")"
    assert_eq "and its hash" "$sum" "$(ws_value t1 WS_SCENARIOS_SHA256)"

    out=$(CLAUDECODE=1 ws scenarios t1 --from "$FX/ticket.txt" --replace 2>&1) && rc=0 || rc=$?
    assert_eq "--replace replaces them" "0 Wrote 1 scenarios to ~/vault/projects/work/t1/scenarios/t1.md" "$rc $out"
    assert_eq ".ws then holds the hash of the new file" "$(sha256sum <"$file" | cut -d ' ' -f 1)" "$(ws_value t1 WS_SCENARIOS_SHA256)"
}

test_scenarios_and_verify_through_a_vault_path_with_a_backslash() {
    local out rc file
    new_fixture_no_ticket
    ln -s "$WS_VAULT" "$FX/v\\x"
    export WS_VAULT=$FX/v\\x
    ws new t1 feat/x alpha >/dev/null 2>&1
    printf 'As a user I can undo a save.\n' >"$FX/ticket.txt"
    out=$(ws scenarios t1 --from "$FX/ticket.txt" 2>&1) && rc=0 || rc=$?
    file=$(scenarios_of t1)
    assert_eq "scenarios exits 0 when WS_VAULT holds a backslash" "0 Wrote 3 scenarios to ~/v\\x/projects/work/t1/scenarios/t1.md" "$rc $out"
    assert_eq ".ws holds the sha256 of the file's bytes" "$(sha256sum <"$file" | cut -d ' ' -f 1)" "$(ws_value t1 WS_SCENARIOS_SHA256)"

    ws up t1 >/dev/null 2>&1
    results "S1 PASS" "S2 PASS" "S3 PASS"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify accepts that hash and passes" "0 qa" "$rc $(ws_value t1 WS_STAGE)"
}

test_verify_refuses_a_ticket_it_cannot_write_deny_rules_for() {
    local out rc
    new_fixture_no_ticket
    mkdir "$FX/work[1]"
    export WS_ROOT="$FX/work[1]"
    ticket_ready
    results "S1 PASS" "S2 PASS" "S3 PASS"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify exits 1 when the ticket path holds a pattern character" 1 "$rc"
    assert "it says why" grep -qxF \
        "ws: ~/work[1]/t1/.ws holds a character that Claude Code reads as a pattern, so ws writes no deny rule for it" <<<"$out"
    refute "it starts no verify session" test -e "$FX/claude.bg-args"
    assert_eq "the stage stays" spec "$(ws_value t1 WS_STAGE)"
}

test_verify_refuses_changed_scenarios() {
    local out rc file
    new_fixture_no_ticket
    ticket_ready
    file=$(scenarios_of t1)
    echo "## S4. Added later" >>"$file"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify exits 1 when the scenarios changed" 1 "$rc"
    assert_eq "it refuses with the intake message" "ws: scenarios changed since intake" "$out"
    refute "it starts no verify session" test -e "$FX/claude.bg-args"
    assert_eq "the stage stays" spec "$(ws_value t1 WS_STAGE)"

    rm "$file"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify refuses when the scenarios file is gone" "1 ws: scenarios changed since intake" "$rc $out"

    ws new t2 feat/y beta >/dev/null 2>&1
    out=$(ws verify t2 2>&1) && rc=0 || rc=$?
    assert_eq "verify refuses a ticket with no scenarios" "1 ws: t2 has no scenarios; run ws scenarios t2 first" "$rc $out"
}

test_verify_refuses_when_the_env_is_down() {
    local out rc
    new_fixture_no_ticket
    ticket_with_scenarios t1 feat/x alpha
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify exits 1 before ws up" 1 "$rc"
    assert_eq "it names ws up" "ws: the env of t1 is down; run ws up t1 first" "$out"

    ws up t1 >/dev/null 2>&1
    ws down t1 >/dev/null 2>&1
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify refuses after ws down" "1 ws: the env of t1 is down; run ws up t1 first" "$rc $out"

    ws up t1 >/dev/null 2>&1
    echo '[]' >"$FX/docker.json"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify refuses when .ws has URLs and no container runs" "1 ws: the env of t1 is down; run ws up t1 first" \
        "$rc $out"
    refute "it starts no verify session" test -e "$FX/claude.bg-args"
}

test_verify_passes() {
    local out rc ev prompt ticket
    new_fixture_no_ticket
    ticket_ready
    results "S1 PASS" "S2 PASS" "S3 PASS"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    ev=$(evidence_of t1)
    assert_eq "verify exits 0 when every scenario passes" 0 "$rc"
    assert "it prints the count and the evidence" grep -qxF "3/3 scenarios passed, evidence at $(shown "$ev")" <<<"$out"
    assert_eq "the stage becomes qa" qa "$(ws_value t1 WS_STAGE)"
    assert "ls shows qa" grep -qE "^t1 +qa " <<<"$(ws ls)"
    assert_eq "the evidence directory holds results.md" "$(cat "$FX/verify.results")" "$(cat "$ev/results.md")"

    bg_args
    ticket=$(realpath "$WS_ROOT/t1")
    assert_eq "the session is named <id>-verify and runs the ui-tester agent" \
        "--bg -n t1-verify --agent ui-tester --permission-mode acceptEdits --allowedTools" "${BG_ARGS[*]:0:8}"
    assert_eq "it may read the scenarios file and use Playwright" \
        "Read(/$(realpath "$(scenarios_of t1)")) mcp__playwright" "${BG_ARGS[*]:8:2}"
    assert_eq "it may not edit the scenarios, the ticket's .ws, or the ticket directory, and the prompt follows --" \
        "--disallowedTools Edit(/$(realpath "$(scenarios_of t1)")) Edit(/$ticket/.ws) Edit(/$ticket/**) --" "${BG_ARGS[*]:10:5}"
    prompt=${BG_ARGS[-1]}
    assert "the prompt names the scenarios file" grep -qF -- "- Read the scenarios in $(scenarios_of t1). Never change that file." <<<"$prompt"
    assert "and the env URLs" grep -qxF -- "  - web-ui: http://localhost:4100" <<<"$prompt"
    assert "and where the results go" grep -qF "write $(realpath "$ev")/results.md" <<<"$prompt"
    assert "and the result line" grep -qxF "RESULT S2 FAIL <what the Then line expected and what happened>" <<<"$prompt"
    refute "it names no calibration file that does not exist" grep -qF qa-calibration <<<"$prompt"
    assert_eq "the session runs in the evidence directory" "$(realpath "$ev")" "$(jq -r '.[0].cwd' "$FX/agents.json")"
    assert_eq "ws stops the session once it has every result" stopped "$(jq -r '.[0].state' "$FX/agents.json")"

    mkdir -p "$WS_VAULT/global/patterns"
    echo "calibration" >"$WS_VAULT/global/patterns/qa-calibration.md"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    bg_args
    assert_eq "a second run gets its own evidence directory" "0 3/3 scenarios passed, evidence at $(shown "$ev").2" \
        "$rc $(tail -n 1 <<<"$out")"
    assert_eq "it may read qa-calibration.md" "Read(/$(realpath "$WS_VAULT/global/patterns/qa-calibration.md"))" "${BG_ARGS[10]}"
    assert "the prompt tells it to read that first" grep -qF -- \
        "- Read $(realpath "$WS_VAULT/global/patterns/qa-calibration.md") before you start." <<<"${BG_ARGS[-1]}"
}

test_verify_fails() {
    local out rc ev
    new_fixture_no_ticket
    ticket_ready
    ws stage t1 building >/dev/null
    results "S1 PASS" "S2 FAIL the Save button stayed disabled"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    ev=$(evidence_of t1)
    assert_eq "verify exits 1 when a scenario fails" 1 "$rc"
    assert "it prints the count and the evidence" grep -qxF "1/3 scenarios passed, evidence at $(shown "$ev")" <<<"$out"
    assert "it names the failed scenario and why" grep -qxF "  FAIL S2 the Save button stayed disabled" <<<"$out"
    assert "a scenario with no result line fails" grep -qxF "  FAIL S3 has no RESULT line" <<<"$out"
    assert_eq "the stage stays building" building "$(ws_value t1 WS_STAGE)"

    results "S1 PASS" "S2 FAIL the undo did nothing" "S3 PASS" "S2 PASS"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "a FAIL line then a PASS line for one scenario fails the run" "1 building" "$rc $(ws_value t1 WS_STAGE)"
    assert "it says the scenario has two RESULT lines" grep -qxF "  FAIL S2 has 2 RESULT lines" <<<"$out"

    results "S1 FAIL nope" "S2 PASS" "S3 PASS"
    printf '\nThe format was:\n\nRESULT S1 PASS\n' >>"$FX/verify.results"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "a quoted example PASS line after a real FAIL fails the run" "1 building" "$rc $(ws_value t1 WS_STAGE)"
    assert "it names that scenario" grep -qxF "  FAIL S1 has 2 RESULT lines" <<<"$out"

    results "S1 PASS but the button was missing" "S2 PASS" "S3 PASS"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "a PASS line with more words after it fails" "1 building" "$rc $(ws_value t1 WS_STAGE)"
    assert "it says the line is neither form" grep -qxF "  FAIL S1 has a RESULT line that is neither PASS nor FAIL" <<<"$out"

    results "S1 PASS" "S2 PASS" $'S3 FAIL the toast \e[2Jsaid nothing'
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert "a FAIL line shows its reason without control characters" grep -qxF "  FAIL S3 the toast [2Jsaid nothing" <<<"$out"

    printf 'RESULT\tS1\tPASS\r\nRESULT S2 PASS \r\nRESULT S3 PASS\t\n' >"$FX/verify.results"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "tabs, trailing spaces, and CRLF line ends still pass" "0 qa" "$rc $(ws_value t1 WS_STAGE)"
}

test_verify_waits_for_a_running_session() {
    local out rc ev pid
    new_fixture_no_ticket
    ticket_ready
    ev=$(evidence_of t1)
    mkdir -p "$ev"
    ev=$(realpath "$ev")
    jq --arg cwd "$ev" '. + [{id: "bg9", name: "t1-verify", cwd: $cwd, kind: "background", state: "working", status: "busy"}]' \
        "$FX/agents.json" >"$FX/agents.new" && mv "$FX/agents.new" "$FX/agents.json"
    (
        sleep 0.5
        printf 'RESULT S1 PASS\nRESULT S2 PASS\nRESULT S3 PASS\n' >"$ev/results.md"
    ) &
    pid=$!
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    wait "$pid"
    assert_eq "verify exits 0 once the running session writes every result" 0 "$rc"
    assert "it says it waits for that session" grep -qxF \
        "A verify session of t1 already runs in $(shown "$ev"), so ws waits for it." <<<"$out"
    refute "it starts no second session" test -e "$FX/claude.bg-args"
    assert_eq "the stage becomes qa" qa "$(ws_value t1 WS_STAGE)"
}

test_verify_session_without_results() {
    local out rc ev
    new_fixture_no_ticket
    ticket_ready
    ws stage t1 building >/dev/null
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    ev=$(evidence_of t1)
    assert_eq "verify exits 1 when the session ends with no results.md" 1 "$rc"
    assert "it says so" grep -qxF "ws: the verify session ended without $(shown "$ev")/results.md" <<<"$out"
    assert_eq "the stage goes back to what it was" building "$(ws_value t1 WS_STAGE)"
}

test_verify_session_that_waits_on_you() {
    local out rc
    new_fixture_no_ticket
    ticket_ready
    touch "$FX/verify.blocked"
    out=$(WS_VERIFY_TIMEOUT=2 ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify exits 1 when the session does not finish in time" 1 "$rc"
    assert "it says the session waits on you" grep -qxF "The verify session waits on you. claude attach bg0 shows what it asks." <<<"$out"
    assert "it says a rerun waits again" grep -qxF \
        "ws: the verify session wrote no result for every scenario in 2 seconds; ws verify t1 waits for it again" <<<"$out"
    assert_eq "the stage stays verifying" verifying "$(ws_value t1 WS_STAGE)"
    assert_eq "ws leaves that session running" blocked "$(jq -r '.[0].state' "$FX/agents.json")"
}

test_verify_scenarios_change_during_the_run() {
    local out rc
    new_fixture_no_ticket
    ticket_ready
    results "S1 PASS" "S2 PASS" "S3 PASS"
    touch "$FX/verify.tamper"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify exits 1 when the scenarios change during the run" 1 "$rc"
    assert_eq "it refuses with the intake message" "ws: scenarios changed since intake" "$(tail -n 1 <<<"$out")"
    assert_eq "the stage goes to building, not qa" building "$(ws_value t1 WS_STAGE)"
}

test_verify_when_claude_bg_fails() {
    local out rc
    new_fixture_no_ticket
    ticket_ready
    touch "$FX/claude.bg-fail"
    out=$(ws verify t1 2>&1) && rc=0 || rc=$?
    assert_eq "verify exits 1 when claude --bg fails" 1 "$rc"
    assert "it shows what claude said" grep -qF "Workspace not trusted." <<<"$out"
    assert "it says nothing verifies the ticket" grep -qxF "ws: claude --bg failed, so nothing verifies t1" <<<"$out"
    assert_eq "the stage goes back to what it was" spec "$(ws_value t1 WS_STAGE)"
}

test_done() {
    local out rc
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    out=$(ws "done" t1 2>&1) && rc=0 || rc=$?
    assert_eq "done exits 0" 0 "$rc"
    assert_eq "the stage becomes merged" merged "$(ws_value t1 WS_STAGE)"
    assert_eq "it runs vault-consolidate on WS_VAULT and WS_ROOT" "WS_VAULT=$WS_VAULT WS_ROOT=$WS_ROOT args=" \
        "$(cat "$FX/consolidate.log")"
    assert_eq "it prints the stage, what vault-consolidate says, and the ws rm command" \
        $'t1 is at merged\nvault-consolidate: read 0 inbox files; changed 0 files\nws rm t1 moves its worktrees and files to the trash.' \
        "$out"
    assert "it keeps the ticket when nobody answers" test -e "$WS_ROOT/t1/.ws"

    touch "$FX/consolidate.fail"
    out=$(ws "done" t1 2>&1) && rc=0 || rc=$?
    assert_eq "done exits 1 when vault-consolidate fails" 1 "$rc"
    assert "it says so" grep -qxF "ws: vault-consolidate failed" <<<"$out"
    assert "it says why it keeps the ticket and how to rerun" grep -qxF \
        "ws keeps t1, because vault-consolidate archives the learnings of a merged ticket only while its .ws is in ~/work. Run ws done t1 again once vault-consolidate works." \
        <<<"$out"
    refute "it does not print the ws rm command" grep -qF "ws rm" <<<"$out"
    assert_eq "the stage stays merged" merged "$(ws_value t1 WS_STAGE)"
}

test_done_offers_rm() {
    local out
    new_fixture_no_ticket
    ws new t1 feat/x alpha >/dev/null 2>&1
    ws_guard
    touch "$FX/consolidate.fail"
    out=$(script -qec "bash $(printf %q "$WS_TESTS/../../dotfiles/bin/ws") done t1" /dev/null <<<"y" 2>&1 | tr -d '\r')
    refute "after vault-consolidate fails, done does not ask about ws rm" grep -qF "[y/N]" <<<"$out"
    assert "so a y on its input removes nothing" test -e "$WS_ROOT/t1/.ws"
    rm "$FX/consolidate.fail"
    out=$(script -qec "bash $(printf %q "$WS_TESTS/../../dotfiles/bin/ws") done t1" /dev/null <<<"n" 2>&1 | tr -d '\r')
    assert "done asks before ws rm" grep -qF "Move the worktrees and files of t1 to the trash with ws rm t1? [y/N]" <<<"$out"
    assert "no keeps the ticket" test -e "$WS_ROOT/t1/.ws"
    out=$(script -qec "bash $(printf %q "$WS_TESTS/../../dotfiles/bin/ws") done t1" /dev/null <<<"y" 2>&1 | tr -d '\r')
    assert "yes runs ws rm" grep -qxF "Removed ticket t1. ws prune --restore t1 brings it back." <<<"$out"
    refute "the ticket is gone" test -e "$WS_ROOT/t1"
}

run_test test_new_writes_the_deny_rules
run_test test_scenarios_from_a_file
run_test test_scenarios_from_jira
run_test test_scenarios_refuses_bad_output
run_test test_scenarios_inside_a_claude_session
run_test test_scenarios_and_verify_through_a_vault_path_with_a_backslash
run_test test_verify_refuses_a_ticket_it_cannot_write_deny_rules_for
run_test test_verify_refuses_changed_scenarios
run_test test_verify_refuses_when_the_env_is_down
run_test test_verify_passes
run_test test_verify_fails
run_test test_verify_waits_for_a_running_session
run_test test_verify_session_without_results
run_test test_verify_session_that_waits_on_you
run_test test_verify_scenarios_change_during_the_run
run_test test_verify_when_claude_bg_fails
run_test test_done
run_test test_done_offers_rm
finish
