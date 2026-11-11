#!/usr/bin/env bash
set -euo pipefail

cd "${1:-${WS_PROJECTS:-$HOME/projects}}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for d in */; do
    d=${d%/}
    [ -f "$d/.git" ] || continue
    b=$(git -C "$d" branch --show-current)
    n=$(git -C "$d" status --porcelain | wc -l)
    main=$(dirname "$(git -C "$d" rev-parse --path-format=absolute --git-common-dir)")
    echo "$d ${b:--} $n $main"
done >"$tmp/rows"

awk '{ print $4 }' "$tmp/rows" | sort -u | while read -r main; do
    slug=$(git -C "$main" config --get remote.origin.url | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
    gh pr list -R "$slug" --state all --limit 300 --json headRefName,state,number </dev/null >"$tmp/$(basename "$main").json"
done

while read -r d b n main; do
    if [ "$b" = - ]; then
        pr=DETACHED
    else
        pr=$(jq -r --arg b "$b" 'map(select(.headRefName == $b)) | first // empty | "\(.state) #\(.number)"' \
            "$tmp/$(basename "$main").json")
    fi
    echo "$d $b $n ${pr:-NONE}"
done <"$tmp/rows"
