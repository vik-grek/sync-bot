# sync-bot

A Docker-based automation tool that periodically merges base branches into open PR branches, keeping them up-to-date.

## Setup

1. Copy and fill in your secrets:
   ```
   cp .env.example .env
   ```

2. Create a `config.yml`:
   ```yaml
   cron: "0 0 * * *"

   repos:
     - name: owner/repo
       enabled: true
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
| `cron` | `config.yml` | Cron schedule expression |
| `repos` | `config.yml` | List of repos to sync |

## Error Logs

Failures are written to `/workspace/sync-bot-errors.json` (persistent volume) as a JSON array.
