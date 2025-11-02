#!/usr/bin/env bash
set -euo pipefail

# ----------
# Settings
# ----------
MONTHS_OLD="${MONTHS_OLD:-24}"       # Repos older than this (no pushes) are pre-selected
OWNER="${OWNER:-}"                   # Optional: set OWNER=yourusername (else auto-detect)
INCLUDE_FORKS="${INCLUDE_FORKS:-false}" # true/false
LIMIT="${LIMIT:-1000}"               # Max repos to fetch
DRY_RUN="${DRY_RUN:-false}"          # true to only print actions

# ----------
# Requirements
# ----------
command -v gh >/dev/null || { echo "gh is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# ----------
# Resolve owner (username) if not provided
# ----------
if [[ -z "$OWNER" ]]; then
  OWNER="$(gh api user -q .login)"
fi

# ----------
# Cutoff date (ISO-8601, UTC) for "old" repos
# ----------
# GNU date (Fedora) supports this:
CUTOFF="$(date -u -d "$MONTHS_OLD months ago" +%Y-%m-%dT%H:%M:%SZ)"

# ----------
# Fetch repositories
# ----------
# Fields: fullName (owner/name), pushedAt, isArchived, isFork
JSON="$(gh repo list "$OWNER" --limit "$LIMIT" \
  --json name,owner,pushedAt,isArchived,isFork,visibility,url \
  --jq '
    .[] | {
      fullName: (.owner.login + "/" + .name),
      pushedAt, isArchived, isFork, visibility, url
    }
  ')"

# Convert to a JSON array if single object
if [[ "$(jq -r type <<<"$JSON")" != "array" ]]; then
  JSON="[$JSON]"
fi

# Optionally drop forks
if [[ "$INCLUDE_FORKS" != "true" ]]; then
  JSON="$(jq '[.[] | select(.isFork==false)]' <<<"$JSON")"
fi

# Filter out already-archived (we only *archive* here)
JSON_ACTIVE="$(jq '[.[] | select(.isArchived==false)]' <<<"$JSON")"

COUNT="$(jq 'length' <<<"$JSON_ACTIVE")"
if (( COUNT == 0 )); then
  echo "No unarchived repositories found for $OWNER (after filters)."
  exit 0
fi

# ----------
# Build selection list with default picks
# ----------
# We'll mark items as "DEFAULT" if pushedAt < CUTOFF or pushedAt == null
# Also, handle repos with no pushes (null)
PICKS_TSV="$(jq -r --arg C "$CUTOFF" '
  .[] |
  .as $r |
  (if (.pushedAt == null or .pushedAt < $C) then "DEFAULT" else "KEEP" end) as $flag |
  [$r.fullName, ($r.pushedAt // "never"), $flag, $r.visibility, $r.url] | @tsv
' <<<"$JSON_ACTIVE")"

# ----------
# Try whiptail first (pre-checked old repos)
# ----------
if command -v whiptail >/dev/null; then
  TITLE="Archive Repositories"
  MSG="Select repositories to ARCHIVE (space to toggle, enter to confirm).
Pre-checked = no updates in the last ${MONTHS_OLD} months.
Total candidates: ${COUNT}"

  # Build whiptail args: triplets: TAG ITEM STATUS(on/off)
  # TAG = full name; ITEM = 'last_push • vis • url'; STATUS = on/off
  WT_ARGS=()
  while IFS=$'\t' read -r full pushed flag vis url; do
    tag="$full"
    item="$pushed • $vis • $url"
    status="off"
    [[ "$flag" == "DEFAULT" ]] && status="on"
    WT_ARGS+=("$tag" "$item" "$status")
  done <<<"$PICKS_TSV"

  # whiptail cannot handle too many options on *very* small terminals; but 140 is ok typically.
  SELECTED="$(
    whiptail --title "$TITLE" --checklist "$MSG" 25 100 18 \
      "${WT_ARGS[@]}" 3>&1 1>&2 2>&3 || true
  )"

  # whiptail returns a space-separated list in quotes, e.g. "owner/repo1" "owner/repo2"
  # Normalize to lines
  if [[ -z "$SELECTED" ]]; then
    echo "No repositories selected. Nothing to do."
    exit 0
  fi
  mapfile -t TO_ARCHIVE < <(sed 's/"//g' <<<"$SELECTED" | tr ' ' '\n' | sed '/^$/d')

else
  # ----------
  # Fallback to fzf (cannot pre-select, but we make default items easy to grab)
  # ----------
  command -v fzf >/dev/null || { echo "Install either 'whiptail' (newt) or 'fzf' for interactive picker."; exit 1; }

  echo "whiptail not found; using fzf."
  echo "TIP: Type 'DEFAULT' then press Alt-a (toggle-all) and Enter to quickly select all old repos."
  echo

  # Build fzf list: "FULLNAME<TAB>PUSHED<TAB>FLAG<TAB>VIS<TAB>URL"
  # Show preview and allow multi-pick
  SELECTED="$(echo "$PICKS_TSV" | \
    fzf --multi \
        --with-nth=1,2,3,4 \
        --delimiter='\t' \
        --header="Select repos to ARCHIVE. 'DEFAULT' are older than ${MONTHS_OLD} months. Press TAB to mark, Enter to confirm. TIP: query 'DEFAULT' then Alt-a." \
        --preview='printf "Repo: %s\nLast Push: %s\nFlag: %s\nVisibility: %s\nURL: %s\n" {1} {2} {3} {4} {5}' \
        --preview-window=down,wrap \
    || true
  )"

  if [[ -z "$SELECTED" ]]; then
    echo "No repositories selected. Nothing to do."
    exit 0
  fi
  mapfile -t TO_ARCHIVE < <(awk -F'\t' '{print $1}' <<<"$SELECTED")
fi

echo
echo "You selected ${#TO_ARCHIVE[@]} repositories to ARCHIVE:"
printf '  - %s\n' "${TO_ARCHIVE[@]}"
echo

read -r -p "Proceed to ARCHIVE these repos? [y/N] " ok
if [[ ! "$ok" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ----------
# Archive loop
# ----------
for repo in "${TO_ARCHIVE[@]}"; do
  echo "Archiving $repo ..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN: gh repo edit \"$repo\" --archived"
  else
    gh repo edit "$repo" --archived
  fi
done

echo "Done. Tip:"
echo "  gh repo list \"$OWNER\" --limit 200            # non-archived"
echo "  gh repo list \"$OWNER\" --limit 200 --archived # archived only"
