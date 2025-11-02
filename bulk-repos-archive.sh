#!/usr/bin/env bash
set -euo pipefail

# -----------------
# Config (env overrides)
# -----------------
MONTHS_OLD="${MONTHS_OLD:-24}"        # Pre-select repos not pushed in >= this many months
OWNER="${OWNER:-}"                     # e.g. OWNER=Brownster ; auto-detect if empty
INCLUDE_FORKS="${INCLUDE_FORKS:-false}" # true/false
LIMIT="${LIMIT:-1000}"                 # How many repos to fetch
DRY_RUN="${DRY_RUN:-false}"           # true => print actions only

# -----------------
# Requirements
# -----------------
command -v gh >/dev/null || { echo "gh is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# -----------------
# Resolve owner
# -----------------
if [[ -z "$OWNER" ]]; then
  OWNER="$(gh api user -q .login)"
fi

# -----------------
# Cutoff (UTC ISO-8601)
# -----------------
CUTOFF="$(date -u -d "$MONTHS_OLD months ago" +%Y-%m-%dT%H:%M:%SZ)"

# -----------------
# Fetch repos as a proper JSON array (no --jq here!)
# -----------------
RAW="$(
  gh repo list "$OWNER" --limit "$LIMIT" \
    --json name,owner,pushedAt,isArchived,isFork,visibility,url
)"

# Shape into clean array of fields we care about
JSON="$(
  echo "$RAW" | jq '[.[] | {
    fullName: (.owner.login + "/" + .name),
    pushedAt, isArchived, isFork, visibility, url
  }]'
)"

# Optionally drop forks
if [[ "$INCLUDE_FORKS" != "true" ]]; then
  JSON="$(jq '[.[] | select(.isFork==false)]' <<<"$JSON")"
fi

# Consider only unarchived repos (we are archiving here)
JSON_ACTIVE="$(jq '[.[] | select(.isArchived==false)]' <<<"$JSON")"

COUNT="$(jq 'length' <<<"$JSON_ACTIVE")"
if (( COUNT == 0 )); then
  echo "No unarchived repositories found for $OWNER (after filters)."
  exit 0
fi

# -----------------
# Build selection list with default picks (>= MONTHS_OLD)
# -----------------
PICKS_TSV="$(jq -r --arg C "$CUTOFF" '
  .[] |
  .as $r |
  (if (.pushedAt == null or .pushedAt < $C) then "DEFAULT" else "KEEP" end) as $flag |
  [$r.fullName, ($r.pushedAt // "never"), $flag, $r.visibility, $r.url] | @tsv
' <<<"$JSON_ACTIVE")"

# -----------------
# Interactive selection
# -----------------
if command -v whiptail >/dev/null; then
  TITLE="Archive Repositories"
  MSG="Select repositories to ARCHIVE (space to toggle, enter to confirm).
Pre-checked = no updates in the last ${MONTHS_OLD} months.
Total candidates: ${COUNT}"

  WT_ARGS=()
  while IFS=$'\t' read -r full pushed flag vis url; do
    tag="$full"
    item="$pushed • $vis • $url"
    status="off"
    [[ "$flag" == "DEFAULT" ]] && status="on"
    WT_ARGS+=("$tag" "$item" "$status")
  done <<<"$PICKS_TSV"

  SELECTED="$(
    whiptail --title "$TITLE" --checklist "$MSG" 25 100 18 \
      "${WT_ARGS[@]}" 3>&1 1>&2 2>&3 || true
  )"

  if [[ -z "$SELECTED" ]]; then
    echo "No repositories selected. Nothing to do."
    exit 0
  fi

  mapfile -t TO_ARCHIVE < <(sed 's/"//g' <<<"$SELECTED" | tr ' ' '\n' | sed '/^$/d')

else
  command -v fzf >/dev/null || { echo "Install 'newt' (whiptail) or 'fzf' for interactive picker."; exit 1; }
  echo "whiptail not found; using fzf."
  echo "TIP: Type 'DEFAULT' then press Alt-a (toggle all matches) and Enter to quickly select all old repos."
  echo

  SELECTED="$(echo "$PICKS_TSV" | \
    fzf --multi \
        --with-nth=1,2,3,4 \
        --delimiter=$'\t' \
        --header="Select repos to ARCHIVE. 'DEFAULT' = older than ${MONTHS_OLD} months. TAB to mark, Enter to confirm. Tip: search 'DEFAULT' then Alt-a." \
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

# -----------------
# Archive
# -----------------
for repo in "${TO_ARCHIVE[@]}"; do
  echo "Archiving $repo ..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN: gh repo edit \"$repo\" --archived"
  else
    gh repo edit "$repo" --archived
  fi
done

echo "Done.
List non-archived: gh repo list \"$OWNER\" --limit 200
List archived:     gh repo list \"$OWNER\" --limit 200 --archived"
