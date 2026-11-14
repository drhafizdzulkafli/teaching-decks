#!/bin/bash
# Double-click this file in Finder (or run it in Terminal) to:
#   1. rebuild index.html from the decks/ folder
#   2. upload any new or changed decks to your public website
cd "$(dirname "$0")" || exit 1
export PATH="$HOME/.local/bin:$PATH"

echo "── Rebuilding the deck list ──"
python3 build_index.py || { echo "Build failed."; read -n1 -p "Press any key to close"; exit 1; }

# GitHub refuses single files over 100 MB
BIG=$(find decks -type f -size +95M 2>/dev/null)
if [ -n "$BIG" ]; then
  echo
  echo "These files are too large for GitHub (limit 100 MB). Compress them or export to PDF, then try again:"
  echo "$BIG"
  read -n1 -p "Press any key to close"; exit 1
fi

git add -A
if git diff --cached --quiet; then
  echo "Nothing new to publish."
else
  git commit -q -m "Update decks $(date '+%Y-%m-%d %H:%M')"
  echo "── Uploading ──"
  if git push -q; then
    URL=$(gh api "repos/{owner}/{repo}/pages" --jq .html_url 2>/dev/null)
    echo "✓ Published. The site refreshes within about a minute: ${URL}"
  else
    echo "Upload failed — check your internet connection and try again."
  fi
fi
echo
read -n1 -t 15 -p "Press any key to close (closes itself in 15 s)"
