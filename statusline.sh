#!/bin/bash
data=$(cat)

# Repeat a string N times (tr mangles multi-byte UTF-8)
repeat() { local s="" i; for ((i=0; i<$2; i++)); do s+="$1"; done; printf '%s' "$s"; }

# Extract all fields in a single jq call.
# Uses ASCII Unit Separator (\x1f) instead of \t — `read` with whitespace IFS
# collapses consecutive separators, which would lose empty fields like effort.
# rate_limits.* uses -1 as a sentinel for absent (API-key users, or before first response).
IFS=$'\x1f' read -r model effort cwd ctx_used ctx_size cost lines_added lines_removed cur_input cur_cache_create cur_cache_read cur_output total_duration_ms api_duration_ms five_h five_h_reset seven_d seven_d_reset <<< \
  "$(echo "$data" | jq -r '[
    (.model.display_name // "unknown"),
    (.effort.level // ""),
    (.workspace.current_dir // .cwd // ""),
    (.context_window.used_percentage // 0 | floor),
    (.context_window.context_window_size // 0),
    (.cost.total_cost_usd // 0),
    (.cost.total_lines_added // 0),
    (.cost.total_lines_removed // 0),
    (.context_window.current_usage.input_tokens // 0),
    (.context_window.current_usage.cache_creation_input_tokens // 0),
    (.context_window.current_usage.cache_read_input_tokens // 0),
    (.context_window.current_usage.output_tokens // 0),
    (.cost.total_duration_ms // 0),
    (.cost.total_api_duration_ms // 0),
    (.rate_limits.five_hour.used_percentage // -1 | floor),
    (.rate_limits.five_hour.resets_at // -1),
    (.rate_limits.seven_day.used_percentage // -1 | floor),
    (.rate_limits.seven_day.resets_at // -1)
  ] | join("")')"

token_total=$((cur_input + cur_cache_create + cur_cache_read + cur_output))

# Color token_total based on 200k threshold
input_pct=$((token_total * 100 / 200000))
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

# Bar stays green — token count on line 2 carries the perf-pressure signal.
color='\033[32m'
reset='\033[0m'

# Run git in the actual session cwd, not wherever the script was spawned —
# matters when /add-dir or a subagent has shifted the active directory.
branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch=$(cd "$cwd" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

# Strip both forward and back slashes so this works on Windows paths.
dir_name="${cwd##*[/\\]}"
if [ -n "$branch" ]; then
  dir_branch="${dir_name} ${dim}[${reset}${branch}${dim}]${reset}"
else
  dir_branch="${dir_name}"
fi

# Append lines added/removed (git diff style colors). Hide each side when zero.
green='\033[32m'
red='\033[31m'
if [ "$lines_added" -gt 0 ] && [ "$lines_removed" -gt 0 ]; then
  dir_branch="${dir_branch} ${green}+${lines_added}${reset} ${red}-${lines_removed}${reset}"
elif [ "$lines_added" -gt 0 ]; then
  dir_branch="${dir_branch} ${green}+${lines_added}${reset}"
elif [ "$lines_removed" -gt 0 ]; then
  dir_branch="${dir_branch} ${red}-${lines_removed}${reset}"
fi

if [ -n "$effort" ]; then
  model_seg="${model} ${dim}(${effort})${reset}"
else
  model_seg="${model}"
fi
echo -e "${model_seg} | ${color}${filled_str}${dim}${empty_str}${reset} ${color}${ctx_used}%${reset} | ${cost_fmt} | ${dir_branch}"

# Shorten window size to human-readable
if [ "$ctx_size" -ge 1000000 ]; then
  ctx_label="$((ctx_size / 1000000))M"
elif [ "$ctx_size" -ge 1000 ]; then
  ctx_label="$((ctx_size / 1000))k"
else
  ctx_label="$ctx_size"
fi

# Format milliseconds to human-readable duration
fmt_duration() {
  local ms="$1"
  local s=$((ms / 1000)) h=0 m=0
  if [ "$s" -ge 3600 ]; then
    h=$((s / 3600)); s=$((s % 3600))
  fi
  m=$((s / 60)); s=$((s % 60))
  if [ "$h" -gt 0 ]; then
    printf '%dh %dm %ds' "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then
    printf '%dm %ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# Line 2: window | tokens | session | api
line2="window: ${ctx_label} | ${input_color}${token_total}${reset} tokens"
if [ "$total_duration_ms" -gt 0 ]; then
  wall=$(fmt_duration "$total_duration_ms")
  api=$(fmt_duration "$api_duration_ms")
  line2="${line2} ${dim}|${reset} session: ${wall} ${dim}|${reset} api: ${api}"
fi
echo -e "$line2"

# Line 3: cache hit rate + last timestamp
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
  cache_line="cache: ${cache_color}${cache_hit}% hit${reset} ${dim}(${cache_label})${reset}"
  cache_line="${cache_line} ${dim}| last: $(date +'%H:%M')${reset}"
  echo -e "$cache_line"
fi

# --- Usage limits (Pro/Max) ---
# Sourced from rate_limits.* in Claude Code's stdin JSON. Absent for API-key users
# and before the first API response of the session — we use -1 as the sentinel.
fmt_reset() {
  local reset_epoch="$1"
  if [ "$reset_epoch" -le 0 ]; then return; fi
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
usage_line=""

if [ "$five_h" -ge 0 ]; then
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

if [ "$seven_d" -ge 0 ]; then
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

if [ -n "$usage_line" ]; then
  echo -e "$usage_line"
fi
