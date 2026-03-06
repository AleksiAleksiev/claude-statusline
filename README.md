# claude-statusline

A bash statusline for Claude Code. Shows context usage, token counts, cost, git branch, and subscription rate limits — all in a single script.

## Screenshot

```
Opus 4.6 (1M context) | █░░░░░░░░░ 10% | $4.56 | AA-generators*
window: 1000000 | 104051 tokens | >200k: false
cache: 99% hit (warm)
5h: ██████████ 100% (32m) | 7d: █████░░░░░ 52% (14h 32m)
```

## What it shows

| Line | Content |
|------|---------|
| **1** | Model name, context bar with color, session cost, git branch (with dirty indicator) |
| **2** | Context window size, total input tokens (colored by 200k threshold), >200k flag. The 200k tracking is useful when running 1M context models but wanting to stay under 200k for faster responses and lower cache costs. |
| **3** | Cache hit rate with warm/warming/cold indicator |
| **4** | 5-hour and 7-day rate limit usage with bars, percentages, and reset countdowns (Pro/Max/Team only) |

### Context bar colors
- Green: < 70%
- Yellow: 70–84%
- Red: 85%+

### Cache hit colors
- Green (warm): 80%+ of input from cache reads
- Yellow (warming): 40–79% cache reads
- Red (cold): < 40% cache reads

### Usage bar colors
- Blue: < 75%
- Magenta: 75–89%
- Red: 90%+

## Requirements

- Bash (Git Bash on Windows)
- `jq`
- `curl` (for usage API)

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
       "command": "bash ~/.claude/statusline.sh"
     }
   }
   ```

## Usage API

Rate limit data is fetched from `https://api.anthropic.com/api/oauth/usage` using the OAuth token from `~/.claude/.credentials.json`. Results are cached to `~/.claude/.usage-cache.json` with a 125s TTL. Only available for Pro/Max/Team subscriptions — API key users see no usage line.

The usage API is prone to returning HTTP 429 (rate limiting). When this happens, the last successful response is preserved and displayed with a `(stale - api error)` disclaimer.

## Platform

Tested on Windows (Git Bash). Uses GNU `stat -c` and `date -d` which are not available on macOS.

## License

MIT
