#!/bin/bash
data=$(cat)

# Repeat a string N times (tr mangles multi-byte UTF-8)
repeat() { local s="" i; for ((i=0; i<$2; i++)); do s+="$1"; done; printf '%s' "$s"; }

model=$(echo "$data" | jq -r '.model.display_name // "unknown"')
ctx_used=$(echo "$data" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

ctx_size=$(echo "$data" | jq -r '.context_window.context_window_size // 0')
exceeds_200k=$(echo "$data" | jq -r '.exceeds_200k_tokens // false')
cost=$(echo "$data" | jq -r '.cost.total_cost_usd // 0')

# Sum of input token fields
cur_input=$(echo "$data" | jq -r '.context_window.current_usage.input_tokens // 0')
cur_cache_create=$(echo "$data" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cur_cache_read=$(echo "$data" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
input_total=$((cur_input + cur_cache_create + cur_cache_read))

# Color input_total based on 200k threshold
input_pct=$((input_total * 100 / 200000))
if [ "$input_pct" -ge 90 ]; then
  input_color='\033[31m'
elif [ "$input_pct" -ge 70 ]; then
  input_color='\033[33m'
else
  input_color='\033[32m'
fi

cost_fmt=$(printf '$%.2f' "$cost")

# Context bar (10 segments) using block characters
filled=$((ctx_used / 10))
empty=$((10 - filled))
filled_str=$(repeat '█' $filled)
empty_str=$(repeat '░' $empty)
dim='\033[2m'

# Color: green <70, yellow 70-84, red 85+
if [ "$ctx_used" -ge 85 ]; then
  color='\033[31m'
elif [ "$ctx_used" -ge 70 ]; then
  color='\033[33m'
else
  color='\033[32m'
fi
reset='\033[0m'

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -n "$branch" ]; then
  if ! git diff --quiet 2>/dev/null; then
    branch="${branch}*"
  fi
fi

echo -e "${model} | ${color}${filled_str}${dim}${empty_str}${reset} ${color}${ctx_used}%${reset} | ${cost_fmt} | ${branch}"
# >200k color
if [ "$exceeds_200k" = "true" ]; then
  exceed_color='\033[31m'
else
  exceed_color="$reset"
fi

echo -e "window: ${ctx_size} | ${input_color}${input_total}${reset} tokens | ${exceed_color}>200k: ${exceeds_200k}${reset}"

# Cache hit rate
cache_total=$((cur_cache_read + cur_cache_create + cur_input))
if [ "$cache_total" -gt 0 ]; then
  cache_hit=$((cur_cache_read * 100 / cache_total))
  if [ "$cache_hit" -ge 80 ]; then
    cache_color='\033[32m'
    cache_label="warm"
  elif [ "$cache_hit" -ge 40 ]; then
    cache_color='\033[33m'
    cache_label="warming"
  else
    cache_color='\033[31m'
    cache_label="cold"
  fi
  echo -e "cache: ${cache_color}${cache_hit}% hit${reset} ${dim}(${cache_label})${reset}"
fi

# --- Usage limits (Pro/Max/Team) ---
creds_file="$HOME/.claude/.credentials.json"
usage_cache="$HOME/.claude/.usage-cache.json"
cache_ttl=125
fail_ttl=125

usage_line=""
if [ -f "$creds_file" ]; then
  sub_type=$(jq -r '.claudeAiOauth.subscriptionType // ""' "$creds_file")
  plan=""
  case "$sub_type" in
    *max*|*Max*) plan="Max" ;;
    *pro*|*Pro*) plan="Pro" ;;
    *team*|*Team*) plan="Team" ;;
  esac

  if [ -n "$plan" ]; then
    # Check cache age — use longer TTL for failed responses
    fetch=true
    if [ -f "$usage_cache" ]; then
      cache_age=$(( $(date +%s) - $(stat -c %Y "$usage_cache" 2>/dev/null || echo 0) ))
      is_error=$(jq -r '.error // empty' "$usage_cache" 2>/dev/null)
      ttl=$cache_ttl
      if [ -n "$is_error" ]; then
        ttl=$fail_ttl
      fi
      if [ "$cache_age" -lt "$ttl" ]; then
        fetch=false
      fi
    fi

    if [ "$fetch" = true ]; then
      token=$(jq -r '.claudeAiOauth.accessToken // ""' "$creds_file")
      if [ -n "$token" ]; then
        resp=$(curl -s --max-time 5 \
          -H "Authorization: Bearer $token" \
          -H "anthropic-beta: oauth-2025-04-20" \
          https://api.anthropic.com/api/oauth/usage 2>/dev/null)
        if echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
          echo "$resp" | jq '{five_hour, seven_day, extra_usage}' > "$usage_cache"
        else
          # Mark stale but preserve last good data
          if [ -f "$usage_cache" ]; then
            jq '. + {error: true}' "$usage_cache" > "${usage_cache}.tmp" && mv "${usage_cache}.tmp" "$usage_cache"
          else
            echo '{"error":true}' > "$usage_cache"
          fi
        fi
      fi
    fi

    if [ -f "$usage_cache" ]; then
      five_h=$(jq -r '.five_hour.utilization // empty' "$usage_cache" 2>/dev/null | cut -d. -f1)
      seven_d=$(jq -r '.seven_day.utilization // empty' "$usage_cache" 2>/dev/null | cut -d. -f1)
      five_h_reset=$(jq -r '.five_hour.resets_at // empty' "$usage_cache" 2>/dev/null)
      seven_d_reset=$(jq -r '.seven_day.resets_at // empty' "$usage_cache" 2>/dev/null)

      # Format reset time as countdown
      fmt_reset() {
        local reset_at="$1"
        if [ -z "$reset_at" ]; then return; fi
        local reset_epoch=$(date -d "$reset_at" +%s 2>/dev/null)
        if [ -z "$reset_epoch" ]; then return; fi
        local diff=$(( reset_epoch - $(date +%s) ))
        if [ "$diff" -le 0 ]; then printf 'now'; return; fi
        local h=$((diff / 3600)) m=$(( (diff % 3600) / 60 ))
        if [ "$h" -gt 0 ]; then
          printf '%dh %dm' "$h" "$m"
        else
          printf '%dm' "$m"
        fi
      }

      bright_blue='\033[94m'
      bright_magenta='\033[95m'

      if [ -n "$five_h" ]; then
        if [ "$five_h" -ge 90 ]; then
          uc='\033[31m'
        elif [ "$five_h" -ge 75 ]; then
          uc="$bright_magenta"
        else
          uc="$bright_blue"
        fi
        uf=$((five_h / 10))
        ue=$((10 - uf))
        uf_str=$(repeat '█' $uf)
        ue_str=$(repeat '░' $ue)
        five_reset_str=$(fmt_reset "$five_h_reset")
        usage_line="5h: ${uc}${uf_str}${dim}${ue_str}${reset} ${uc}${five_h}%${reset}"
        if [ -n "$five_reset_str" ]; then
          usage_line="${usage_line} ${dim}(${five_reset_str})${reset}"
        fi
      fi

      if [ -n "$seven_d" ]; then
        if [ "$seven_d" -ge 90 ]; then
          sc='\033[31m'
        elif [ "$seven_d" -ge 75 ]; then
          sc="$bright_magenta"
        else
          sc="$bright_blue"
        fi
        sf=$((seven_d / 10))
        se=$((10 - sf))
        sf_str=$(repeat '█' $sf)
        se_str=$(repeat '░' $se)
        seven_reset_str=$(fmt_reset "$seven_d_reset")
        seven_part="7d: ${sc}${sf_str}${dim}${se_str}${reset} ${sc}${seven_d}%${reset}"
        if [ -n "$seven_reset_str" ]; then
          seven_part="${seven_part} ${dim}(${seven_reset_str})${reset}"
        fi
        usage_line="${usage_line:+$usage_line | }${seven_part}"
      fi
    fi
  fi
fi

if [ -n "$usage_line" ]; then
  is_stale=$(jq -r '.error // empty' "$usage_cache" 2>/dev/null)
  if [ -n "$is_stale" ]; then
    usage_line="${usage_line} ${dim}(stale - api error)${reset}"
  fi
  echo -e "$usage_line"
elif [ -f "$usage_cache" ] && [ -n "$(jq -r '.error // empty' "$usage_cache" 2>/dev/null)" ]; then
  echo -e "${dim}usage: api error${reset}"
fi
