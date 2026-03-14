#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/config.yml"
LOG_FILE="/workspace/sync-bot-errors.json"

log_fatal() {
  local message="$1"
  echo "FATAL: $message"
  [[ -f "$LOG_FILE" ]] || echo '[]' > "$LOG_FILE"
  local tmp
  tmp=$(jq \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg message "$message" \
    '. += [{timestamp: $ts, level: "fatal", repo: "", pr: "", message: $message}]' "$LOG_FILE")
  echo "$tmp" > "$LOG_FILE"
  exit 1
}

# --- Validate env vars ---

if [[ -z "${GH_TOKEN:-}" ]]; then
  log_fatal "GH_TOKEN is not set in .env"
fi

if [[ -z "${WEBHOOK_URL:-}" ]]; then
  log_fatal "WEBHOOK_URL is not set in .env"
fi

if [[ -z "${GIT_USER_NAME:-}" ]]; then
  log_fatal "GIT_USER_NAME is not set in .env"
fi

if [[ -z "${GIT_USER_EMAIL:-}" ]]; then
  log_fatal "GIT_USER_EMAIL is not set in .env"
fi

# --- Configure git identity ---

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# --- Validate config ---

if [[ ! -f "$CONFIG_FILE" ]]; then
  log_fatal "Config file $CONFIG_FILE not found"
fi

CRON_SCHEDULE=$(yq '.cron' "$CONFIG_FILE")

if [[ -z "$CRON_SCHEDULE" || "$CRON_SCHEDULE" == "null" ]]; then
  log_fatal "No cron schedule found in $CONFIG_FILE"
fi

echo "Starting sync-bot with schedule: $CRON_SCHEDULE"

# Dump env vars into a file that cron can source
env | grep -E '^(GH_TOKEN|WEBHOOK_URL|GIT_USER_NAME|GIT_USER_EMAIL|PATH)=' > /worker/env.sh
sed -i 's/^/export /' /worker/env.sh

# Build crontab entry — source env, then run worker
CRON_LINE="$CRON_SCHEDULE . /worker/env.sh && bash /worker/worker.sh > /proc/1/fd/1 2>/proc/1/fd/2"

# Install crontab
echo "$CRON_LINE" | crontab -

echo "Crontab installed:"
crontab -l

# Run cron in the foreground
exec crond -f -l 2
