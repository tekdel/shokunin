#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/ws/lib.sh
source "$(dirname "$0")/lib.sh"

unset CLAUDE_PROJECT_DIR

# Prints the reason when ws hook bash denies the command $2 run in the directory $1, and nothing when it allows it.
hook_of() {
    local out rc
    out=$(jq -n --arg cwd "$1" --rawfile cmd <(printf '%s' "$2") '{session_id: "s1", transcript_path: "/dev/null", cwd: $cwd,
        permission_mode: "default", hook_event_name: "PreToolUse", tool_name: "Bash",
        tool_input: {command: $cmd, description: "d"}, tool_use_id: "toolu_1"}' | ws hook bash) && rc=0 || rc=$?
    ((rc == 0)) || {
        echo "EXIT $rc"
        return
    }
    [[ -n $out ]] || return 0
    jq -er 'select(.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny")
        | .hookSpecificOutput.permissionDecisionReason' <<<"$out" || echo "NOT A DENY: $out"
}

shown_cmd() {
    local cmd=${1//$'\n'/\\n}
    ((${#cmd} <= 110)) || cmd="${cmd:0:110}..."
    printf '%s\n' "$cmd"
}

denies() {
    local reason
    reason=$(hook_of "$1" "$2")
    if [[ -n $reason && $reason == *"$3"* ]]; then
        ok "denies in ${1/#"$HOME"/\~}: $(shown_cmd "$2")"
    else
        not_ok "denies in ${1/#"$HOME"/\~}: $(shown_cmd "$2")"
        printf '      expected a reason with: %s\n      actual:   %s\n' "$3" "$reason"
    fi
}

allows() {
    local reason
    reason=$(hook_of "$1" "$2")
    if [[ -z $reason ]]; then
        ok "allows in ${1/#"$HOME"/\~}: $(shown_cmd "$2")"
    else
        not_ok "allows in ${1/#"$HOME"/\~}: $(shown_cmd "$2")"
        printf '      reason: %s\n' "$reason"
    fi
}

ticket_t1() {
    new_fixture
    T=$WS_ROOT/t1 A=$WS_ROOT/t1/alpha B=$WS_ROOT/t1/beta
    {
        printf 'WS_ID=t1\nWS_BRANCH=feat/ticket\nWS_REPOS=alpha beta\nWS_TICKET=ABC-12\n' >"$T/.ws" &&
            jq -n '{scripts: {test: "jest --forceExit", "test:unit": "node -r dotenv/config ./node_modules/.bin/jest tests/unit --maxWorkers=50%",
                "test:e2e": "jest tests/e2e", typecheck: "tsc --noEmit", lint: "eslint .", check: "npm run typecheck",
                "test:ci": "cross-env NODE_ENV=test jest --ci", "test:env": "dotenv -e .env.test -- jest"}}' >"$A/package.json" &&
            jq -n '{scripts: {test: "vitest run"}}' >"$B/package.json" &&
            mkdir -p "$A/src" "$WS_ROOT/plain/alpha" "$HOME/elsewhere"
    } || abort "cannot write the ticket t1"
}

test_host_runs_in_a_worktree() {
    ticket_t1
    denies "$A" "npx jest tests/unit" "ws exec alpha npx jest tests/unit -w 4"
    denies "$A" "jest -w 4" "ws exec alpha jest -w 4"
    denies "$A" "npx vitest run" "ws exec alpha npx vitest run"
    denies "$A" "npx tsc --noEmit" "ws exec alpha npx tsc --noEmit"
    denies "$A" "tsc -b" "ws exec alpha tsc -b"
    denies "$A" "./node_modules/.bin/tsc --noEmit -p tsconfig.build.json" "ws exec alpha ./node_modules/.bin/tsc"
    denies "$A" "npm test" "ws exec alpha npm test -- -w 4"
    denies "$A" "npm t" "ws exec alpha npm t -- -w 4"
    denies "$A" "npm test -- -w 4" "ws exec alpha npm test -- -w 4"
    denies "$A" "npm run test:unit" "ws exec alpha npm run test:unit"
    denies "$A" "npm run test:e2e -- --runInBand" "ws exec alpha npm run test:e2e -- --runInBand"
    denies "$A" "npm run typecheck" "ws exec alpha npm run typecheck"
    denies "$A" "npm run check" "ws exec alpha npm run check"
    denies "$A" "yarn test -w 4" "ws exec alpha yarn test -w 4"
    denies "$A" "pnpm test:unit" "ws exec alpha pnpm test:unit"
    denies "$A" "npx nx test api" "ws exec alpha npx nx test api"
    denies "$A" "nx run-many -t lint" "ws exec alpha nx run-many -t lint"
    denies "$A" "npm exec -- jest -i" "ws exec alpha npm exec -- jest -i"
    denies "$A" "npx --yes jest@29 --runInBand" "ws exec alpha npx --yes jest@29 --runInBand"
    denies "$A" "node -r dotenv/config ./node_modules/.bin/jest tests/unit --runInBand" \
        "ws exec alpha node -r dotenv/config ./node_modules/.bin/jest tests/unit --runInBand"
    denies "$A" "node --max-old-space-size=12288 node_modules/typescript/bin/tsc --noEmit" \
        "ws exec alpha node --max-old-space-size=12288 node_modules/typescript/bin/tsc --noEmit"
    denies "$A/src" "npx jest foo.test.ts -w 2" "ws exec alpha npx jest foo.test.ts -w 2"
    denies "$B" "npm test" "ws exec beta npm test"
}

test_wrappers_and_targets() {
    ticket_t1
    denies "$A" "NODE_OPTIONS=--max-old-space-size=8192 npx jest tests/unit" "ws exec alpha npx jest tests/unit -w 4"
    denies "$A" "systemd-run --user --scope -p MemoryMax=16G npx jest -w 4" "ws exec alpha npx jest -w 4"
    denies "$A" "timeout 600 env CI=1 npx tsc --noEmit" "ws exec alpha npx tsc --noEmit"
    denies "$A" "nice -n 10 time npx jest -i" "ws exec alpha npx jest -i"
    denies "$A" "command npx tsc" "ws exec alpha npx tsc"
    denies "$T" "cd alpha && npx jest -w 4" "ws exec alpha npx jest -w 4"
    denies "$T" $'cd alpha\nnpx tsc --noEmit' "ws exec alpha npx tsc --noEmit"
    denies "$T" "cd alpha; cd src; npx jest -i" "ws exec alpha npx jest -i"
    denies "$T" "(cd beta && npx vitest run)" "ws exec beta npx vitest run"
    denies "$HOME" "cd ~/work/t1/beta && NODE_OPTIONS=--max-old-space-size=8192 npx jest -w 2" "ws exec beta npx jest -w 2"
    denies "$HOME" "cd \"\$HOME/work/t1/alpha\" && npx tsc" "ws exec alpha npx tsc"
    denies "$HOME" "cd $A/src && cd .. && npx tsc" "ws exec alpha npx tsc"
    denies "$HOME" "pushd $A >/dev/null && npm test -- -i" "ws exec alpha npm test -- -i"
    denies "$T" "npm --prefix alpha test -- -w 4" "ws exec alpha npm test -- -w 4"
    denies "$T" "npm --prefix=alpha run typecheck" "ws exec alpha npm run typecheck"
    denies "$T" "pnpm -C alpha run test:unit" "ws exec alpha pnpm run test:unit"
    denies "$T" "yarn --cwd beta test" "ws exec beta yarn test"
    denies "$T" "npx tsc -p alpha/tsconfig.json --noEmit" "ws exec alpha npx tsc -p alpha/tsconfig.json --noEmit"
    denies "$T" "env -C beta npx vitest run" "ws exec beta npx vitest run"
    denies "$T" "bash -c 'cd alpha && npx tsc --noEmit'" "ws exec alpha npx tsc --noEmit"
    denies "$T" "sh -lc \"cd beta; npx vitest\"" "ws exec beta npx vitest"
    denies "$T" "git status && cd alpha && npx jest -w 4 2>&1 | tail -20" "ws exec alpha npx jest -w 4"
    denies "$A" "echo start; npx tsc --noEmit > /tmp/tsc.log 2>&1 || true" "ws exec alpha npx tsc --noEmit"
    denies "$A" "for t in a b; do npx jest \"\$t\" -w 1; done" "ws exec alpha npx jest '\$t' -w 1"
    denies "$A" "if npx tsc; then echo ok; fi" "ws exec alpha npx tsc"
    denies "$A" "out=\$(npx tsc --noEmit)" "ws exec alpha npx tsc --noEmit"
    denies "$A" "watch -n 5 ls; npx jest -i" "ws exec alpha npx jest -i"
    denies "$A" $'case "$1" in\n  (jest|tsc) echo x ;;\n  *) npx tsc --noEmit ;;\nesac' "ws exec alpha npx tsc --noEmit"
    denies "$A" "case \$x in a) case \$y in b) echo ;; esac ;; c) npx jest -w 2 ;; esac" "ws exec alpha npx jest -w 2"
}

test_jest_needs_a_worker_limit() {
    ticket_t1
    denies "$T" "ws exec alpha npx jest" "ws exec alpha npx jest -w 4"
    denies "$HOME/elsewhere" "ws exec t1 alpha npx jest tests/unit" "ws exec t1 alpha npx jest tests/unit -w 4"
    denies "$HOME/elsewhere" "ws exec ABC-12 alpha jest" "ws exec ABC-12 alpha jest -w 4"
    denies "$T" "ws exec alpha npm test" "ws exec alpha npm test -- -w 4"
    denies "$T" "ws exec alpha npm test -- --coverage" "ws exec alpha npm test -- --coverage -w 4"
    denies "$T" "ws exec alpha npx jest --watchAll=false --coverage" "ws exec alpha npx jest --watchAll=false --coverage -w 4"
    denies "$T" "ws exec alpha sh -c 'npx jest --coverage'" "npx jest --coverage -w 4"
    denies "$T" "docker compose -p dockyard-feat-ticket exec -T alpha npx jest" \
        "docker compose -p dockyard-feat-ticket exec -T alpha npx jest -w 4"
    denies "$T" "docker compose exec -T alpha npm test" "docker compose exec -T alpha npm test -- -w 4"
    denies "$T" "docker exec -it -e CI=1 dockyard-feat-ticket-alpha-1 npx jest tests" \
        "docker exec -it -e CI=1 dockyard-feat-ticket-alpha-1 npx jest tests -w 4"
    denies "$WS_PROJECTS/alpha" "npx jest" "npx jest -w 4"
    denies "$A" "npx jest" "(jest needs -w 4, or it starts one worker per CPU)"
    denies "$A" "npx tsc && ws exec alpha npx jest" \
        "Run it in the ticket's container instead: ws exec alpha npx tsc ws hook: jest needs a worker limit, or it starts one worker per CPU. Run this instead: ws exec alpha npx jest -w 4"
    allows "$T" "ws exec alpha npx jest -w 4"
    allows "$T" "ws exec alpha npx jest --maxWorkers=2"
    allows "$T" "ws exec alpha npx jest --maxWorkers 50%"
    allows "$T" "ws exec alpha npx jest --runInBand"
    allows "$T" "ws exec alpha npx jest -i tests/unit"
    allows "$T" "ws exec alpha npm test -- -w 4"
    allows "$T" "ws exec alpha npm run test:unit"
    allows "$T" "ws exec alpha npx tsc --noEmit"
    allows "$T" "ws exec beta npm test"
    allows "$T" "docker compose -p dockyard-feat-ticket exec -T alpha npx jest -w 4"
    allows "$WS_PROJECTS/alpha" "npx tsc --noEmit"
    allows "$WS_PROJECTS/alpha" "npx jest --version"
}

test_links_in_the_ticket() {
    ticket_t1
    denies "$A" "ln -s ~/projects/alpha/node_modules node_modules" "symlink named node_modules in a ticket, at ~/work/t1/alpha/node_modules"
    denies "$A" "ln -s ~/projects/alpha/node_modules node_modules" "ws exec alpha <command>"
    denies "$T" "ln -sfn $WS_PROJECTS/alpha/node_modules alpha/" "at ~/work/t1/alpha/node_modules"
    denies "$T" "ln -sfn $WS_PROJECTS/alpha/node_modules alpha/node_modules" "at ~/work/t1/alpha/node_modules"
    denies "$A" "ln -s ../../../projects/alpha/prisma-client src/prisma-client" "symlink named prisma-client"
    denies "$A" "ln --symbolic --force ~/projects/alpha/src/prisma-client src" "at ~/work/t1/alpha/src/prisma-client"
    denies "$HOME" "ln -s -t ~/work/t1/beta ~/projects/beta/node_modules" "at ~/work/t1/beta/node_modules"
    denies "$HOME" "ln -st ~/work/t1/beta ~/projects/beta/node_modules" "at ~/work/t1/beta/node_modules"
    denies "$T" "ln -s $WS_PROJECTS/alpha/node_modules" "at ~/work/t1/node_modules"
    denies "$T" "ln -s $WS_PROJECTS/alpha/node_modules" "ws exec <repo> <command>"
    denies "$A" "cd src && ln -s ~/projects/alpha/node_modules/.prisma/client prisma-client" "at ~/work/t1/alpha/src/prisma-client"
    allows "$A" "ln -s ../x y"
    allows "$A" "ln -s ~/projects/alpha/node_modules node_modules.old"
    allows "$A" "ln ~/projects/alpha/README node_modules"
    allows "$WS_PROJECTS/alpha" "ln -s ../alpha-open/node_modules node_modules"
    allows "$WS_ROOT/plain" "ln -s ~/projects/alpha/node_modules alpha/node_modules"
    allows "$A" "ls node_modules; find . -name node_modules -prune -o -print | head"
}

test_ordinary_commands() {
    ticket_t1
    local cmd
    local -a cmds=(
        "git status"
        "git log --oneline -5 --grep=tsc"
        "git diff -- src/app.test.ts"
        "git commit -m \"fix: make npx jest and tsc pass\""
        $'git commit -m "$(cat <<\'EOF\'\nfix: tsc passes now\n\nnpx jest -w 4 now\nnpm test\nRun "npm run typecheck" (and jest) first.\nEOF\n)"'
        $'cat > notes.md <<\'EOF\'\nnpx jest\ntsc --noEmit\nln -s ~/projects/alpha/node_modules node_modules\nEOF'
        $'cat <<-EOF > x.sh\n\tnpx tsc\n\tEOF\necho done'
        $'python3 - <<\'PY\'\nimport subprocess\nsubprocess.run(["npx", "jest"])\nPY'
        "grep -rn jest src"
        "rg -n 'npx jest|tsc' ."
        "echo \"npm test\"; echo tsc; printf '%s\\n' jest"
        "cat package.json | jq .scripts.test"
        "which jest; man tsc; type -a npx"
        "npm install"
        "npm ci"
        "npm run lint"
        "npm view jest version"
        "npx prisma generate"
        "npx eslint . --fix"
        "npx tsc --version"
        "npx jest --help"
        "npx jest --listTests"
        "yarn install --frozen-lockfile"
        "pnpm i"
        "gh pr create --title 'fix: tsc' --body \"Run \\\`npm test\\\` and \\\`npx tsc\\\`.\""
        "for f in src/*.ts; do echo \"\$f\"; done"
        "x=\$(git rev-parse HEAD); echo \"\$x\""
        "cmd=(npx jest); echo \"\${cmd[@]}\""
        "echo \$((1 + 2)) # npx jest later"
        "ls -la ~/projects/alpha/node_modules | head"
        "find . -name '*.test.ts' | xargs grep -l describe"
        "docker compose -p dockyard-feat-ticket logs --tail 50 alpha"
        "docker exec dockyard-feat-ticket-alpha-1 ls"
        "ws exec alpha npm ci"
        "ws exec alpha sh -c 'npx prisma migrate deploy && npx tsc --noEmit'"
        "ws up --wait"
        "nx graph"
        "test -f package.json && echo yes"
        "case \$kind in jest) echo j ;; tsc | vitest) echo t ;;& npm) echo n ;; esac"
        "[[ \$x =~ (^|/)(jest|tsc)(\\.js)?\$ ]] && echo runner"
        "[[ -n \$x && ( \$y == a || \$y == b ) ]] || npx eslint ."
        $'case "$1" in\n  (jest | tsc)\n    echo runner ;;\nesac'
        "[[ -d node_modules ]] || echo missing"
        "sleep 1"
    )
    for cmd in "${cmds[@]}"; do
        allows "$A" "$cmd"
    done
    allows "$T" "git -C alpha log --oneline -5"
    allows "$T" "ls alpha/node_modules beta"
    allows "$HOME/elsewhere" "npx tsc --noEmit"
    allows "$WS_ROOT/plain/alpha" "npx tsc --noEmit"
}

test_hook_input() {
    local out rc
    ticket_t1
    out=$(jq -n --arg cwd "$A" '{cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Edit",
        tool_input: {file_path: "x", command: "npx tsc"}}' | ws hook bash) && rc=0 || rc=$?
    assert_eq "hook bash allows a tool that is not Bash, with status 0 and no output" "0:" "$rc:$out"
    out=$(printf 'not json' | ws hook bash) && rc=0 || rc=$?
    assert_eq "it allows input that is not JSON" "0:" "$rc:$out"
    out=$(ws hook bash </dev/null) && rc=0 || rc=$?
    assert_eq "it allows empty input" "0:" "$rc:$out"
    out=$(jq -n '{tool_name: "Bash", tool_input: {command: "npx tsc"}}' | ws hook bash) && rc=0 || rc=$?
    assert_eq "it allows a host run when the input has no cwd, since it cannot know where it runs" "0:" "$rc:$out"
    allows "relative/dir" "npx tsc"
    out=$(jq -n --arg cwd "$A" '{cwd: $cwd, tool_name: "Bash", tool_input: {command: "npx tsc"}}' | ws hook bash)
    assert_eq "a deny is the JSON that Claude Code reads, with the reason for Claude" \
        '{"hookEventName":"PreToolUse","permissionDecision":"deny"}' \
        "$(jq -c '.hookSpecificOutput | del(.permissionDecisionReason)' <<<"$out")"
    out=$(cd "$A" && jq -n '{cwd: "", tool_name: "Bash", tool_input: {command: "ws exec alpha npx jest"}}' | ws hook bash)
    assert "inside ws exec it denies jest without a limit also when the input has no cwd" \
        grep -qF "ws exec alpha npx jest -w 4" <<<"$out"
    out=$(cd / && jq -n '{cwd: "/", tool_name: "Bash", tool_input: {command: "ws exec alpha npm test"}}' |
        CLAUDE_PROJECT_DIR=$T ws hook bash)
    assert "ws exec without an id reads the npm scripts of the ticket in CLAUDE_PROJECT_DIR" \
        grep -qF "ws exec alpha npm test -- -w 4" <<<"$out"
    out=$(ws hook 2>&1) && rc=0 || rc=$?
    assert_eq "hook without bash prints the usage and exits 1" 1 "$rc"
    out=$(ws hook bash extra 2>&1) && rc=0 || rc=$?
    assert_eq "hook bash with another word exits 1" 1 "$rc"
}

test_hook_is_fast_on_a_long_heredoc() {
    local body start ms
    ticket_t1
    body=$(for ((i = 0; i < 3000; i++)); do printf 'it("runs jest %s", () => expect(tsc(%s)).toBe(1));\n' "$i" "$i"; done)
    start=$(date +%s%N)
    allows "$A" "cat > src/big.test.ts <<'EOF'"$'\n'"$body"$'\nEOF\nnpx eslint src/big.test.ts'
    ms=$((($(date +%s%N) - start) / 1000000))
    assert "it reads a 3000-line here-document in under 3 seconds ($ms ms)" test "$ms" -lt 3000
}

test_help() {
    local help
    new_fixture_no_ticket
    help=$(ws hook --help)
    assert "hook --help gives the usage line" grep -qxF "       ws hook bash" <<<"$help"
    assert "it says the hook is a speed bump, not a sandbox" grep -qF "speed" <<<"$help"
    assert "it names what gets past it" grep -qF "alias, a variable, or eval gets past it" <<<"$help"
    help=$(ws -h)
    assert "ws -h lists hook" grep -qE '^  hook +the Claude Code hook that sends the test runs of a ticket to ws exec$' <<<"$help"
}

# shellcheck disable=SC2016
test_review_findings() {
    local deep
    ticket_t1
    allows "$A" $'git add -A && \\\n  git commit -m "fix: npm test"'
    denies "$T" $'cd alpha && \\\n  npx tsc' "ws exec alpha npx tsc"
    denies "$A" $'NODE_OPTIONS=--max-old-space-size=8192 \\\n  npx jest -w 2' "ws exec alpha npx jest -w 2"
    denies "$T" $'ws exec alpha \\\n  npx jest' "ws exec alpha npx jest -w 4"
    denies "$A" $'npx jest \\\n  -w 4 tests' "ws exec alpha npx jest -w 4 tests"
    allows "$A" '"" npm test'
    allows "$A" "command -v jest"
    allows "$A" "command -v tsc >/dev/null || npm i -D typescript"
    allows "$A" 'if [[ $cmd =~ ^(jest|vitest)$ ]]; then echo yes; fi'
    allows "$A" '! [[ $x =~ (jest|tsc) ]]'
    allows "$A" 'for r in a b; do case $r in jest|vitest) echo;; esac; done'
    denies "$A" 'if [[ -f package.json ]]; then npx tsc; fi' "ws exec alpha npx tsc"
    denies "$A" 'case "$x" in a) echo a ;; *) echo b ;; esac; npx tsc --noEmit' "ws exec alpha npx tsc --noEmit"
    allows "$A" $'case $1 in a) echo a ;; esac\ncat > notes.md <<\'EOF\'\n1) npx tsc --noEmit\nEOF'
    allows "$T" "ws exec alpha npx jest --clearCache"
    allows "$A" "npx jest --clearCache"
    allows "$WS_PROJECTS/alpha" "cd $A && git log -1 && cd - && npx tsc --noEmit"
    allows "$WS_PROJECTS/alpha" "pushd $A >/dev/null && git status -s && popd >/dev/null && npx tsc --noEmit"
    allows "$A" $'[[ -f a ]]&& echo y; cat <<EOF\nnpx tsc\nEOF'
    allows "$HOME" 'ls !(jest).config.js'
    denies "$T" "npm test --prefix alpha" "ws exec alpha npm test -- -w 4"
    denies "$T" "npm run typecheck --prefix=alpha" "ws exec alpha npm run typecheck"
    denies "$A" "npm run -w api test" "ws exec alpha npm run -w api test"
    denies "$A" "pnpm run --filter api test" "ws exec alpha pnpm run --filter api test"
    denies "$A" "yarn run tsc --noEmit" "ws exec alpha yarn run tsc --noEmit"
    denies "$A" "yarn run jest -i" "ws exec alpha yarn run jest -i"
    denies "$A" $'x=$((1<<3))\nnpx tsc --noEmit' "ws exec alpha npx tsc --noEmit"
    denies "$T" "ws exec alpha npm run test:ci" "ws exec alpha npm run test:ci -- -w 4"
    denies "$T" "ws exec alpha npm run test:env" "ws exec alpha npm run test:env -- -w 4"
    deep=$(printf 'echo "$(%.0s' {1..1500})
    allows "$A" "${deep}npm test"
}

run_test test_host_runs_in_a_worktree
run_test test_review_findings
run_test test_wrappers_and_targets
run_test test_jest_needs_a_worker_limit
run_test test_links_in_the_ticket
run_test test_ordinary_commands
run_test test_hook_input
run_test test_hook_is_fast_on_a_long_heredoc
run_test test_help
finish
