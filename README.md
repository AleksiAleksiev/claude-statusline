# claude-statusline

A bash statusline for Claude Code. Shows context usage, token counts, cost, working directory, git branch, lines changed, cache temperature, and subscription rate limits — all in a single script.

## Screenshot

```
Opus 4.7 (xhigh) | ████░░░░░░ 42% | $4.56 | claude-statusline [master] +156 -23
window: 1M | 109700 tokens | session: 42m 30s | api: 6m 47s
cache: 87% hit (warm) | last: 19:21
5h: ███░░░░░░░ 32% (1h 32m) | 7d: ████████░░ 88% (14h 32m)
```

## What it shows

| Line | Content |
|------|---------|
| **1** | Model + reasoning effort, context bar, session cost, working dir + git branch, lines added/removed |
| **2** | Context window size, total tokens (colored by perf threshold), session wall-clock and API duration |
| **3** | Cache hit rate with warm/warming/cold indicator, timestamp of last interaction (useful for checking the 1h prompt-cache TTL when returning after a break) |
| **4** | 5-hour and 7-day rate limit usage with bars, percentages, and reset countdowns (Pro/Max only) |

### Token count colors
- Green: < 140k
- Yellow: 140k–180k
- Red: 180k+

### Cache hit colors
- Green (warm): 80%+ of input from cache reads
- Yellow (warming): 40–79% cache reads
- Red (cold): < 40% cache reads

### Usage bar colors
- Blue: < 75%
- Magenta: 75–89%
- Red: 90%+

## Requirements

- Bash (Git Bash on Windows works)
- `jq`
- `git` (optional — branch indicator is skipped outside repos)

## Install

1. Copy the script:
   ```bash
   cp statusline.sh ~/.claude/statusline.sh
   ```

2. Set it in `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash $HOME/.claude/statusline.sh"
     }
   }
   ```

## Data sources

All fields come from the JSON Claude Code pipes to the script on stdin (see [statusline docs](https://code.claude.com/docs/en/statusline)). No external API calls, no credentials, no cache files. Rate limit data uses `rate_limits.*` and is populated for Pro/Max accounts after the first API response of the session — API-key users see no usage line.

## Platform

Tested on Windows (Git Bash) and Linux/WSL. Uses only POSIX-portable `date` and `stat` invocations (no GNU-specific `date -d` / `stat -c` flags), so should work on macOS too.

## License

MIT
