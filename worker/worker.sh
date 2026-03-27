#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/config.yml"
WORKSPACE="/workspace/repos"
LOG_FILE="/workspace/sync-bot-errors.json"
RESULTS_DIR="$(mktemp -d)"

# --- Git identity (in case entrypoint was skipped) ---

if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi

# --- Git auth via GH_TOKEN for HTTPS operations ---

if [[ -n "${GH_TOKEN:-}" ]]; then
  git config --global url."https://${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi
git config --global http.postBuffer 524288000

# --- Helpers ---

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
  local level="${1:-error}"
  local repo="${2:-}"
  local pr="${3:-}"
  local message="${4:-}"
  [[ -f "$LOG_FILE" ]] || echo '[]' > "$LOG_FILE"
  local tmp
  tmp=$(jq \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg level "$level" \
    --arg repo "$repo" \
    --arg pr "$pr" \
    --arg message "$message" \
    '. += [{timestamp: $ts, level: $level, repo: $repo, pr: $pr, message: $message}]' "$LOG_FILE")
  echo "$tmp" > "$LOG_FILE"
  log "$message"
}

notify() {
  local message="$1"
  if [[ -z "${WEBHOOK_URL:-}" ]]; then
    log "WEBHOOK_URL not set, skipping notification"
    return 0
  fi
  local payload http_code
  payload=$(jq -n --arg text "$message" '{"text": $text}')
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    -d "$payload" "$WEBHOOK_URL" 2>&1) || {
    log_error "error" "" "" "Webhook request failed (connection error)"
    return 0
  }
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    log_error "error" "" "" "Webhook returned HTTP $http_code"
  fi
}

# --- Config loading ---

if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "error" "" "" "Config file $CONFIG_FILE not found"
  notify "sync-bot: config file not found, aborting run"
  exit 1
fi

REPO_INDEX="${1:-}"

repo_count=$(yq '.repos | length' "$CONFIG_FILE")

if [[ -z "$repo_count" || "$repo_count" -eq 0 ]]; then
  log "No repos configured, nothing to do"
  exit 0
fi

# Build list of repo indices to process
if [[ -n "$REPO_INDEX" ]]; then
  repo_indices=("$REPO_INDEX")
  log "Starting sync for repo index $REPO_INDEX"
else
  repo_indices=($(seq 0 $((repo_count - 1))))
  log "Starting sync cycle — $repo_count repo(s) configured"
fi

mkdir -p "$WORKSPACE"

# --- Repo loop ---

for i in "${repo_indices[@]}"; do
  repo_name=$(yq ".repos[$i].name" "$CONFIG_FILE")
  enabled=$(yq ".repos[$i].enabled" "$CONFIG_FILE")

  if [[ "$repo_name" == "null" || -z "$repo_name" ]]; then
    log_error "warning" "index-$i" "" "Repo has no name, skipping"
    echo "invalid-repo-$i|skipped|no name configured" >> "$RESULTS_DIR/summary"
    continue
  fi

  if [[ "$enabled" != "true" && "$enabled" != "false" ]]; then
    log_error "warning" "$repo_name" "" "Invalid 'enabled' value: '$enabled' (must be true or false), skipping"
    echo "$repo_name|skipped|invalid enabled value" >> "$RESULTS_DIR/summary"
    continue
  fi

  if [[ "$enabled" == "false" ]]; then
    log "Repo $repo_name is disabled, skipping"
    echo "$repo_name|skipped|disabled" >> "$RESULTS_DIR/summary"
    continue
  fi

  default_base=$(yq ".repos[$i].default_base // \"\"" "$CONFIG_FILE")

  if [[ -z "$default_base" || "$default_base" == "null" ]]; then
    log_error "warning" "$repo_name" "" "default_base not set, skipping"
    echo "$repo_name|skipped|no default_base" >> "$RESULTS_DIR/summary"
    continue
  fi

  # Process each repo in a subshell for isolation
  (
    repo_dir="$WORKSPACE/$(echo "$repo_name" | tr '/' '_')"
    repo_results="$RESULTS_DIR/$(echo "$repo_name" | tr '/' '_')"

    log "Processing $repo_name"

    # Clone once or fetch
    if [[ -d "$repo_dir/.git" ]]; then
      log "  Fetching $repo_name"
      local fetch_out
      if ! fetch_out=$(timeout 120 git -C "$repo_dir" fetch --all --prune 2>&1); then
        log_error "error" "$repo_name" "" "Fetch failed: $fetch_out"
        echo "fetch-failed" > "$repo_results"
        exit 1
      fi
    else
      log "  Cloning $repo_name (first run)"
      local clone_out
      if ! clone_out=$(timeout 300 gh repo clone "$repo_name" "$repo_dir" 2>&1); then
        log_error "error" "$repo_name" "" "Clone failed: $clone_out"
        echo "clone-failed" > "$repo_results"
        exit 1
      fi
    fi

    cd "$repo_dir"

    # List open PRs authored by the authenticated user (not from forks)
    pr_data=$(timeout 60 gh pr list --author "@me" --state open --json number,headRefName,baseRefName,headRepositoryOwner,isCrossRepository 2>&1) || {
      log_error "error" "$repo_name" "" "Failed to list PRs"
      echo "pr-list-failed" > "$repo_results"
      exit 1
    }

    pr_count=$(echo "$pr_data" | jq 'map(select(.isCrossRepository == false)) | length')

    if [[ "$pr_count" -eq 0 ]]; then
      log "  No open PRs to sync for $repo_name"
      echo "no-prs" > "$repo_results"
      exit 0
    fi

    log "  Found $pr_count open PR(s) for $repo_name"

    # Process each non-fork PR
    echo "$pr_data" | jq -c 'map(select(.isCrossRepository == false)) | .[]' | while read -r pr; do
      pr_number=$(echo "$pr" | jq -r '.number')
      head_branch=$(echo "$pr" | jq -r '.headRefName')
      base_branch=$(echo "$pr" | jq -r '.baseRefName')

      log "  PR #$pr_number: $head_branch <- $base_branch"

      # Checkout the PR branch
      if ! git checkout "$head_branch" -- 2>&1; then
        log_error "error" "$repo_name" "#$pr_number" "Checkout failed for $head_branch"
        echo "fail|#$pr_number $head_branch|checkout failed" >> "$repo_results"
        continue
      fi

      # Pull latest changes for the PR branch
      if ! timeout 60 git pull --ff-only origin "$head_branch" 2>&1; then
        # If ff-only fails, try a regular pull (branch may have been rebased)
        if ! timeout 60 git reset --hard "origin/$head_branch" 2>&1; then
          log_error "error" "$repo_name" "#$pr_number" "Pull failed for $head_branch"
          echo "fail|#$pr_number $head_branch|pull failed" >> "$repo_results"
          continue
        fi
      fi

      # Determine which branches need merging into head
      merge_branches=("$base_branch")

      # If base is not the default branch, also merge it
      if [[ "$base_branch" != "$default_base" ]]; then
        if git rev-parse --verify "origin/$default_base" >/dev/null 2>&1; then
          merge_branches+=("$default_base")
        fi
      fi

      merged_any=false

      for merge_branch in "${merge_branches[@]}"; do
        # Check if branch is already an ancestor of head
        if git merge-base --is-ancestor "origin/$merge_branch" HEAD 2>&1; then
          log "    $merge_branch already up-to-date"
          continue
        fi

        # Merge the branch
        log "    Merging origin/$merge_branch into $head_branch"
        if ! git merge "origin/$merge_branch" --no-edit -m "Merge $merge_branch into $head_branch (sync-bot)" 2>&1; then
          log_error "error" "$repo_name" "#$pr_number" "Merge conflict on $head_branch with $merge_branch"
          git merge --abort 2>/dev/null || true
          echo "conflict|#$pr_number $head_branch|conflict merging $merge_branch" >> "$repo_results"
          continue 2
        fi

        merged_any=true
      done

      if [[ "$merged_any" == "false" ]]; then
        echo "uptodate|#$pr_number $head_branch|already contains ${merge_branches[*]}" >> "$repo_results"
        continue
      fi

      # Push the merged result
      if ! timeout 60 git push origin "$head_branch" 2>&1; then
        log_error "error" "$repo_name" "#$pr_number" "Push failed for $head_branch"
        echo "fail|#$pr_number $head_branch|push failed" >> "$repo_results"
        continue
      fi

      log "    Successfully merged and pushed"
      echo "merged|#$pr_number $head_branch|merged ${merge_branches[*]}" >> "$repo_results"
    done
  ) || log_error "error" "$repo_name" "" "Repo processing failed unexpectedly"
done

# --- Build notification summary ---

log "Building summary"

summary=""
overall_status="ok"

for i in "${repo_indices[@]}"; do
  repo_name=$(yq ".repos[$i].name" "$CONFIG_FILE")
  enabled=$(yq ".repos[$i].enabled" "$CONFIG_FILE")
  repo_key="$(echo "$repo_name" | tr '/' '_')"
  repo_results="$RESULTS_DIR/$repo_key"

  if [[ "$enabled" == "false" ]]; then
    continue
  fi

  summary+="*${repo_name}*"$'\n'

  if [[ ! -f "$repo_results" ]]; then
    # Check the summary file for skip entries
    if grep -q "^${repo_name}|skipped" "$RESULTS_DIR/summary" 2>/dev/null; then
      reason=$(grep "^${repo_name}|skipped" "$RESULTS_DIR/summary" | cut -d'|' -f3)
      summary+="  - skipped ($reason)"$'\n'
    else
      summary+="  - no results recorded"$'\n'
    fi
    continue
  fi

  content=$(cat "$repo_results")

  if [[ "$content" == "no-prs" ]]; then
    summary+="  - no open PRs"$'\n'
    continue
  fi

  if [[ "$content" == "fetch-failed" || "$content" == "clone-failed" || "$content" == "pr-list-failed" ]]; then
    summary+="  - error: $content"$'\n'
    overall_status="error"
    continue
  fi

  while IFS='|' read -r status pr_ref detail; do
    case "$status" in
      merged)    icon="+" ;;
      uptodate)  icon="~" ;;
      conflict)  icon="!" ; overall_status="warning" ;;
      fail)      icon="x" ; overall_status="error" ;;
      *)         icon="?" ;;
    esac
    summary+="  ${icon} ${pr_ref}: ${detail}"$'\n'
  done < "$repo_results"
done

# Send notification
timestamp=$(date '+%Y-%m-%d %H:%M')
message="sync-bot [$timestamp]"$'\n'"$summary"

log "--- Summary ---"
echo "$summary"
log "--- End Summary ---"

notify "$message"

# Cleanup
rm -rf "$RESULTS_DIR"

log "Sync cycle complete (status: $overall_status)"
