#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Prints a Markdown changeset for PREV_TAG..HEAD_REF.
#
# Most commits here come from GitHub's web upload ("Add files via upload"), so the commit list
# says little. The real record is CHANGELOG.md: the bullets added to it in the range are listed
# first, then the commits (web-upload defaults counted, not listed), then the files touched.
#
# Usage: changeset.sh [PREV_TAG] [HEAD_REF]
#   PREV_TAG  default: the most recent v* tag before HEAD_REF; "-" = whole history
set -euo pipefail

head_ref="${2:-HEAD}"
prev="${1:-}"
if [ -z "$prev" ]; then
  prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${head_ref}^" 2>/dev/null || echo "-")
fi

if [ "$prev" = "-" ]; then
  base=$(git hash-object -t tree /dev/null)
  log_range="$head_ref"
  echo "### Changes (full history)"
else
  base="$prev"
  log_range="$prev..$head_ref"
  echo "### Changes since \`$prev\`"
fi
echo

changelog=$(git diff --unified=0 "$base" "$head_ref" -- CHANGELOG.md | sed -n 's/^+\([[:space:]]*[-*] \)/\1/p' || true)
if [ -n "$changelog" ]; then
  echo "#### From CHANGELOG.md"
  echo
  printf '%s\n' "$changelog"
  echo
fi

uploads=0
commits=""
while IFS=$'\t' read -r subject sha; do
  [ -n "$sha" ] || continue
  if [ "$subject" = "Add files via upload" ]; then
    uploads=$((uploads + 1))
  else
    commits+="- ${subject} (${sha})"$'\n'
  fi
done < <(git log --no-merges --format='%s%x09%h' "$log_range")

if [ -n "$commits" ] || [ "$uploads" -gt 0 ]; then
  echo "#### Commits"
  echo
  printf '%s' "$commits"
  [ "$uploads" -gt 0 ] && echo "- ${uploads} × \"Add files via upload\""
  echo
fi

echo "<details><summary>Files changed</summary>"
echo
echo '```'
git diff --stat=100 "$base" "$head_ref" | tail -n 60
echo '```'
echo
echo "</details>"
