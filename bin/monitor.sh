#!/usr/bin/env bash

# 정의되지 않은 변수를 사용하면 바로 실패하게 해서 오타를 빠르게 확인한다.
set -u

# 환경 변수가 없을 때는 과제 기본값을 사용한다.
APP_PORT="${AGENT_PORT:-15034}"
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="${LOG_DIR}/monitor.log"

# 과제에서 요구한 경고 기준이다. 초과 시 종료하지 않고 WARNING만 출력한다.
CPU_THRESHOLD=20
MEM_THRESHOLD=10
DISK_THRESHOLD=80

# 제공 앱 이름이 환경마다 다를 수 있어 가능한 프로세스 이름을 함께 확인한다.
APP_CANDIDATES=(
  "${AGENT_HOME}/agent-app"
  "${AGENT_HOME}/agent_app"
  "agent-app"
  "agent_app"
  "agent_app.py"
)

timestamp() {
  # 로그 파일에 남길 시간을 과제 요구 포맷에 맞춰 생성한다.
  date '+%Y-%m-%d %H:%M:%S'
}

print_warning() {
  # 경고 메시지 형식을 한 곳에서 통일한다.
  echo "[WARNING] $1"
}

find_app_pid() {
  # 실행 중인 앱 프로세스를 후보 이름으로 찾고, 첫 번째 PID를 반환한다.
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
  # TCP LISTEN 소켓 중 앱 포트가 열려 있는지 확인한다.
  ss -tuln | awk -v port=":${APP_PORT}" '$1 == "tcp" && $0 ~ port { found=1 } END { exit found ? 0 : 1 }'
}

check_firewall() {
  # UFW 또는 firewalld 중 설치된 도구를 기준으로 방화벽 활성화 여부를 확인한다.
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
  # /proc/stat 값을 1초 간격으로 두 번 읽어서 CPU 사용률을 계산한다.
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
  # 전체 메모리와 사용 가능 메모리를 이용해 현재 메모리 사용률을 계산한다.
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
  # 루트 파티션(/)의 사용률을 숫자만 추출한다.
  df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
}

compare_greater_than() {
  # Bash는 소수점 비교가 약하므로 awk로 임계값 초과 여부를 판단한다.
  awk -v value="$1" -v threshold="$2" 'BEGIN { exit !(value > threshold) }'
}

# 로그 디렉토리를 보장한다. 로그 용량 관리는 별도 logrotate 설정에서 담당한다.
mkdir -p "$LOG_DIR"

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

# Health Check 1: 앱 프로세스가 없으면 운영 대상이 없으므로 실패 처리한다.
APP_PID="$(find_app_pid || true)"
if [[ -z "${APP_PID:-}" ]]; then
  echo "Checking process 'agent-app'... [FAIL]"
  echo "[ERROR] Application process is not running."
  exit 1
fi
echo "Checking process 'agent-app'... [OK] (PID: ${APP_PID})"

# Health Check 2: 앱 포트가 LISTEN 상태가 아니면 외부 요청을 받을 수 없으므로 실패 처리한다.
if check_port; then
  echo "Checking port ${APP_PORT}... [OK]"
else
  echo "Checking port ${APP_PORT}... [FAIL]"
  echo "[ERROR] TCP ${APP_PORT} is not LISTEN."
  exit 1
fi

# 방화벽은 꺼져 있어도 스크립트를 종료하지 않고 WARNING만 출력한다.
if check_firewall; then
  echo "Checking firewall... [OK]"
else
  print_warning "Firewall is inactive or unavailable."
fi

echo
echo "[RESOURCE MONITORING]"

# 운영 상태 기록에 사용할 자원 사용률을 수집한다.
CPU_USAGE="$(cpu_usage)"
MEM_USAGE="$(mem_usage)"
DISK_USED="$(disk_usage)"

echo "CPU Usage : ${CPU_USAGE}%"
echo "MEM Usage : ${MEM_USAGE}%"
echo "DISK Used  : ${DISK_USED}%"

# 임계값 초과는 장애로 종료하지 않고, 운영자가 볼 수 있도록 경고만 남긴다.
if compare_greater_than "$CPU_USAGE" "$CPU_THRESHOLD"; then
  print_warning "CPU threshold exceeded (${CPU_USAGE}% > ${CPU_THRESHOLD}%)"
fi

if compare_greater_than "$MEM_USAGE" "$MEM_THRESHOLD"; then
  print_warning "MEM threshold exceeded (${MEM_USAGE}% > ${MEM_THRESHOLD}%)"
fi

if compare_greater_than "$DISK_USED" "$DISK_THRESHOLD"; then
  print_warning "DISK threshold exceeded (${DISK_USED}% > ${DISK_THRESHOLD}%)"
fi

# 요구사항의 로그 포맷에 맞춰 monitor.log에 한 줄을 누적 기록한다.
LOG_LINE="[$(timestamp)] PID:${APP_PID} CPU:${CPU_USAGE}% MEM:${MEM_USAGE}% DISK_USED:${DISK_USED}%"
echo "$LOG_LINE" >> "$LOG_FILE"

echo
echo "[INFO] Log appended: ${LOG_FILE}"
