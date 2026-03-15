# sync-bot

A Docker-based automation tool that periodically merges base branches into open PR branches, keeping them up-to-date.

## Setup

1. Copy and fill in your secrets:
   ```
   cp .env.example .env
   ```

2. Create a `config.yml`:
   ```yaml
   repos:
     - name: owner/repo
       enabled: true
       default_base: master
       cron: "0 0 * * *"
   ```

3. Build and run:
   ```
   docker compose build
   docker compose up -d
   ```

## Configuration

| Variable | Location | Description |
|---|---|---|
| `GH_TOKEN` | `.env` | GitHub personal access token |
| `WEBHOOK_URL` | `.env` | Google Chat webhook URL |
| `CONFIG_PATH` | `.env` | Path to config.yml on host |

### Per-repo settings (`config.yml`)

| Key | Required | Description |
|---|---|---|
| `name` | yes | GitHub repo in `owner/repo` format |
| `enabled` | no | `true` (default) or `false` to skip |
| `default_base` | yes | Default branch to merge into PR branches (e.g. `master`, `main`) |
| `cron` | yes | Cron schedule expression (UTC) — each repo runs independently |

## Error Logs

Failures are written to `/workspace/sync-bot-errors.json` (persistent volume) as a JSON array.
