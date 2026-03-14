# Agents Guide

## Working with this Codebase

### Shell Scripts
- All scripts use `bash` (not `sh`) with `set -euo pipefail`
- `worker.sh` is the main entry point for sync logic — all changes to sync behavior go here
- `entrypoint.sh` handles container lifecycle only — validation and cron setup

### Error Logging
- Use `log_error` for any failure that should be persisted to the JSON error log
- Signature: `log_error <level> <repo> <pr> <message>`
- Levels: `fatal`, `error`, `warning`
- Use `log` for informational stdout output (not persisted)

### Adding New Features
- New config fields go in `config.yml` — parse with `yq` in worker.sh
- New secrets go in `.env` — validate in `entrypoint.sh` at startup
- Update `.env.example` and `config.example.yml` when adding new fields
- Keep webhook notification logic in the `notify` function

### Testing Changes
- `docker compose build` to verify Dockerfile
- `docker compose up` to verify cron + worker execution
- Check `/workspace/sync-bot-errors.json` in the container for logged errors

### Constraints
- Do not add `--force` to any git push
- Do not modify or checkout base/default branches for writing
- All network git operations must be wrapped in `timeout`
- Each repo must be processed in its own subshell
