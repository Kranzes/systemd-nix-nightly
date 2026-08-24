#!/usr/bin/env bash
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
patches_dir=$repo/patches
base=$(cat "$patches_dir/.base-revision")
target=$(jq -r '.sources.systemd.revision' "$repo/lon.lock")

if [ "$base" = "$target" ]; then
  echo "patches are already based on $target"
  exit 0
fi

tmp=$(mktemp -d)
on_err() {
  echo "rebase failed; work tree left at $tmp/systemd" >&2
  echo "resolve the conflict, then run:" >&2
  echo "  git am --continue # or git rebase --continue, whichever stage failed" >&2
  echo "  git -c format.signoff=false format-patch $target --no-numbered --zero-commit --no-signature -o $patches_dir" >&2
  echo "  echo $target > $patches_dir/.base-revision" >&2
}
trap on_err ERR

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=rebase-patches GIT_AUTHOR_EMAIL=rebase-patches@localhost
export GIT_COMMITTER_NAME=rebase-patches GIT_COMMITTER_EMAIL=rebase-patches@localhost

git init -q -b main "$tmp/systemd"
cd "$tmp/systemd"
git fetch -q --depth=1 https://github.com/systemd/systemd "$base" "$target"
git switch -qc patched "$base"
git am -3 "$patches_dir"/*.patch
git rebase --onto "$target" "$base"

export_dir=$tmp/patches
git -c format.signoff=false format-patch "$target" --no-numbered --zero-commit --no-signature -o "$export_dir" > /dev/null

if diff -r -q --exclude=.base-revision "$patches_dir" "$export_dir" > /dev/null; then
  echo "patches apply unchanged on $target; keeping base at $base"
else
  rm -f "$patches_dir"/*.patch
  cp "$export_dir"/*.patch "$patches_dir"
  echo "$target" > "$patches_dir/.base-revision"
fi

cd /
rm -rf "$tmp"
