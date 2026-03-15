# Sync Bot

## Overview
Docker-based cron tool that merges base branches into open PR branches to keep them up-to-date. Runs on Alpine with bash, git, jq, curl, yq, and GitHub CLI.

## Project Structure
```
├── worker/
│   ├── worker.sh        # Core sync logic — config parsing, repo loop, merge, notify
│   └── entrypoint.sh    # Container startup — validates env/config, installs crontab, runs crond
├── Dockerfile           # Alpine 3.19 image with dependencies
├── docker-compose.yml   # Single syncbot service with bind-mounted config and persistent volume
├── config.yml           # Runtime config (gitignored) — per-repo cron, default_base, enabled
├── config.example.yml   # Example config for reference
├── .env                 # Secrets (gitignored) — GH_TOKEN, WEBHOOK_URL, CONFIG_PATH
├── .env.example         # Example env for reference
└── CLAUDE.md
```

## Key Design Decisions
- Config is bind-mounted (not copied) so edits are live without rebuilds
- `CONFIG_PATH` in `.env` controls the host-side mount path in docker-compose
- Per-repo cron schedules — each repo gets its own crontab entry and runs independently
- `default_base` is per-repo (e.g. `master` vs `main`)
- Worker accepts optional repo index argument; without it processes all repos
- Each repo processed in a subshell for failure isolation
- Empty repos list is a no-op, not an error
- Error log is a JSON array at `/workspace/sync-bot-errors.json` (persistent volume)
- Webhook notifications include HTTP status code validation (non-2xx logged)

## Safety Constraints
- `gh pr list --author @me` — only own PRs
- `isCrossRepository == false` — skip fork PRs
- No `--force` on any push
- `git merge --abort` on conflict, then continue
- `timeout` on all network git operations
- Never modifies base/default branches

## Build & Run
```
docker compose build
docker compose up -d
```
