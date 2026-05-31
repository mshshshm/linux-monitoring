#!/usr/bin/env bash

set -u

APP_PORT="${AGENT_PORT:-15034}"
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="${LOG_DIR}/monitor.log"
MAX_LOG_SIZE=$((10 * 1024 * 1024))
MAX_LOG_FILES=10

CPU_THRESHOLD=20
MEM_THRESHOLD=10
DISK_THRESHOLD=80

APP_CANDIDATES=(
  "${AGENT_HOME}/agent-app"
  "${AGENT_HOME}/agent_app"
  "agent-app"
  "agent_app"
  "agent_app.py"
)

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

print_warning() {
  echo "[WARNING] $1"
}

find_app_pid() {
  local candidate
  local pid

  for candidate in "${APP_CANDIDATES[@]}"; do
    pid="$(pgrep -f -- "$candidate" | head -n 1 || true)"
    if [[ -n "$pid" && "$pid" != "$$" ]]; then
      echo "$pid"
      return 0
    fi
  done

  return 1
}

check_port() {
  ss -tuln | awk -v port=":${APP_PORT}" '$1 == "tcp" && $0 ~ port { found=1 } END { exit found ? 0 : 1 }'
}

check_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | grep -qi '^Status: active'
    return $?
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --state >/dev/null 2>&1
    return $?
  fi

  return 1
}

cpu_usage() {
  awk '
    /cpu / {
      idle1=$5
      total1=0
      for (i=2; i<=NF; i++) total1 += $i
    }
    END {
      print idle1, total1
    }
  ' /proc/stat | {
    read -r idle1 total1
    sleep 1
    awk -v idle1="$idle1" -v total1="$total1" '
      /cpu / {
        idle2=$5
        total2=0
        for (i=2; i<=NF; i++) total2 += $i
        total_delta=total2-total1
        idle_delta=idle2-idle1
        if (total_delta <= 0) {
          printf "0.0"
        } else {
          printf "%.1f", (100 * (total_delta-idle_delta) / total_delta)
        }
      }
    ' /proc/stat
  }
}

mem_usage() {
  awk '
    /MemTotal:/ { total=$2 }
    /MemAvailable:/ { available=$2 }
    END {
      if (total <= 0) {
        printf "0.0"
      } else {
        printf "%.1f", (100 * (total-available) / total)
      }
    }
  ' /proc/meminfo
}

disk_usage() {
  df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
}

rotate_log_if_needed() {
  [[ -f "$LOG_FILE" ]] || return 0

  local size
  size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)"
  [[ "$size" -lt "$MAX_LOG_SIZE" ]] && return 0

  local i
  for ((i=MAX_LOG_FILES-1; i>=1; i--)); do
    if [[ -f "${LOG_FILE}.${i}" ]]; then
      mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    fi
  done

  mv "$LOG_FILE" "${LOG_FILE}.1"
  : > "$LOG_FILE"
}

compare_greater_than() {
  awk -v value="$1" -v threshold="$2" 'BEGIN { exit !(value > threshold) }'
}

mkdir -p "$LOG_DIR"
rotate_log_if_needed

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

APP_PID="$(find_app_pid || true)"
if [[ -z "${APP_PID:-}" ]]; then
  echo "Checking process 'agent-app'... [FAIL]"
  echo "[ERROR] Application process is not running."
  exit 1
fi
echo "Checking process 'agent-app'... [OK] (PID: ${APP_PID})"

if check_port; then
  echo "Checking port ${APP_PORT}... [OK]"
else
  echo "Checking port ${APP_PORT}... [FAIL]"
  echo "[ERROR] TCP ${APP_PORT} is not LISTEN."
  exit 1
fi


echo
echo "[RESOURCE MONITORING]"

CPU_USAGE="$(cpu_usage)"
MEM_USAGE="$(mem_usage)"
DISK_USED="$(disk_usage)"

echo "CPU Usage : ${CPU_USAGE}%"
echo "MEM Usage : ${MEM_USAGE}%"
echo "DISK Used  : ${DISK_USED}%"

if compare_greater_than "$CPU_USAGE" "$CPU_THRESHOLD"; then
  print_warning "CPU threshold exceeded (${CPU_USAGE}% > ${CPU_THRESHOLD}%)"
fi

if compare_greater_than "$MEM_USAGE" "$MEM_THRESHOLD"; then
  print_warning "MEM threshold exceeded (${MEM_USAGE}% > ${MEM_THRESHOLD}%)"
fi

if compare_greater_than "$DISK_USED" "$DISK_THRESHOLD"; then
  print_warning "DISK threshold exceeded (${DISK_USED}% > ${DISK_THRESHOLD}%)"
fi

LOG_LINE="[$(timestamp)] PID:${APP_PID} CPU:${CPU_USAGE}% MEM:${MEM_USAGE}% DISK_USED:${DISK_USED}%"
echo "$LOG_LINE" >> "$LOG_FILE"

echo
echo "[INFO] Log appended: ${LOG_FILE}"
