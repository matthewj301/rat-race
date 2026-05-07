#!/usr/bin/env bash
#
# klipper-disconnect-analyzer.sh — Diagnose Klipper MCU disconnects from klippy.log
#
# Usage:
#   ./klipper-disconnect-analyzer.sh [klippy.log path]
#   ssh pi@printer "cat /path/to/klippy.log" | ./klipper-disconnect-analyzer.sh -
#
# Default: /home/pi/printer_data/logs/klippy.log (or /tmp/printer_data/logs/klippy.log)

set -euo pipefail

BOLD='\033[1m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
warn()   { echo -e "${YELLOW}⚠  $1${NC}"; }
err()    { echo -e "${RED}✗  $1${NC}"; }
ok()     { echo -e "${GREEN}✓  $1${NC}"; }
info()   { echo -e "   $1"; }

# --- Locate log file ---
if [[ "${1:-}" == "-" ]]; then
  LOGFILE=$(mktemp)
  cat > "$LOGFILE"
  trap "rm -f '$LOGFILE'" EXIT
elif [[ -n "${1:-}" ]]; then
  LOGFILE="$1"
else
  for candidate in \
    /home/pi/printer_data/logs/klippy.log \
    /tmp/printer_data/logs/klippy.log \
    "$HOME/printer_data/logs/klippy.log"; do
    if [[ -f "$candidate" ]]; then
      LOGFILE="$candidate"
      break
    fi
  done
fi

if [[ -z "${LOGFILE:-}" ]] || [[ ! -f "$LOGFILE" ]]; then
  echo "Usage: $0 [klippy.log path | -]"
  echo "Could not find klippy.log automatically. Provide the path as an argument."
  exit 1
fi

echo -e "${BOLD}Analyzing: ${LOGFILE}${NC}"
echo -e "Log size: $(du -h "$LOGFILE" | cut -f1)"

# --- Find all sessions ---
header "Session Index"

declare -a SESSION_STARTS=()
declare -a SESSION_LINES=()
declare -a SESSION_TIMES=()

while IFS= read -r line; do
  lineno=$(echo "$line" | cut -d: -f1)
  timestamp=$(echo "$line" | sed 's/^[0-9]*:Start printer at //')
  SESSION_LINES+=("$lineno")
  SESSION_TIMES+=("$timestamp")
done < <(grep -n 'Start printer at' "$LOGFILE")

TOTAL_SESSIONS=${#SESSION_LINES[@]}
if [[ $TOTAL_SESSIONS -eq 0 ]]; then
  err "No sessions found in log file."
  exit 1
fi

echo "Found $TOTAL_SESSIONS session(s)."
for i in "${!SESSION_LINES[@]}"; do
  echo "  Session $((i+1)): line ${SESSION_LINES[$i]} — ${SESSION_TIMES[$i]}"
done

# --- Find sessions that ended in disconnects ---
header "Disconnect Analysis"

DISCONNECT_COUNT=0

for i in "${!SESSION_LINES[@]}"; do
  START_LINE="${SESSION_LINES[$i]}"
  if [[ $((i+1)) -lt $TOTAL_SESSIONS ]]; then
    END_LINE=$(( ${SESSION_LINES[$((i+1))]} - 1 ))
  else
    END_LINE=$(wc -l < "$LOGFILE")
  fi

  SESSION_TEXT=$(sed -n "${START_LINE},${END_LINE}p" "$LOGFILE")

  # Check for disconnect signatures
  HAS_TIMEOUT=$(echo "$SESSION_TEXT" | grep -c 'Timeout with MCU' || true)
  HAS_EOF=$(echo "$SESSION_TEXT" | grep -c "Got EOF when reading from device" || true)
  HAS_LOST=$(echo "$SESSION_TEXT" | grep -c 'Lost communication with MCU' || true)
  HAS_SHUTDOWN=$(echo "$SESSION_TEXT" | grep -c 'Transition to shutdown state' || true)

  if [[ $HAS_TIMEOUT -eq 0 && $HAS_EOF -eq 0 && $HAS_LOST -eq 0 ]]; then
    continue
  fi

  DISCONNECT_COUNT=$((DISCONNECT_COUNT + 1))

  echo ""
  echo -e "${BOLD}Session $((i+1)): ${SESSION_TIMES[$i]}${NC}"
  echo -e "  Lines: ${START_LINE}–${END_LINE}"

  # Compute wall-clock time of disconnect from monotonic timestamps
  SESSION_EPOCH=$(echo "${SESSION_TIMES[$i]}" | sed 's/ *(.*//; s/  */ /g')
  SESSION_MONO=$(echo "${SESSION_TIMES[$i]}" | grep -oP '\(\K[0-9.]+' | head -1 || true)

  # Find the first timeout/EOF event's monotonic time
  TIMEOUT_LINE=$(echo "$SESSION_TEXT" | grep -m1 'Timeout with MCU' || true)
  if [[ -n "$TIMEOUT_LINE" ]]; then
    TIMEOUT_EVENTTIME=$(echo "$TIMEOUT_LINE" | grep -oP 'eventtime=\K[0-9.]+' || true)
    if [[ -n "$TIMEOUT_EVENTTIME" && -n "$SESSION_MONO" ]]; then
      DELTA=$(echo "$TIMEOUT_EVENTTIME - $SESSION_MONO" | bc 2>/dev/null || true)
      if [[ -n "$DELTA" && -n "$SESSION_EPOCH" ]]; then
        EPOCH_SECS=$(date -d "$SESSION_EPOCH" +%s 2>/dev/null || date -j -f "%a %b %d %H:%M:%S %Y" "$SESSION_EPOCH" +%s 2>/dev/null || true)
        if [[ -n "$EPOCH_SECS" ]]; then
          DISCONNECT_EPOCH=$(echo "$EPOCH_SECS + $DELTA" | bc | cut -d. -f1)
          DISCONNECT_WALL=$(date -d "@$DISCONNECT_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$DISCONNECT_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
          if [[ -n "$DISCONNECT_WALL" ]]; then
            info "Disconnect wall-clock time: ${BOLD}${DISCONNECT_WALL}${NC}"
          fi
        fi
      fi
      info "Session uptime at disconnect: ${DELTA}s"
    fi
  fi

  # Which MCU(s) disconnected
  echo ""
  info "${BOLD}Affected MCUs:${NC}"
  echo "$SESSION_TEXT" | grep 'Timeout with MCU\|Lost communication with MCU\|MCU .* disconnected' | while IFS= read -r mline; do
    MCU_NAME=$(echo "$mline" | grep -oP "MCU '\K[^']+" || true)
    REASON=$(echo "$mline" | sed "s/.*MCU '[^']*' //" || true)
    err "  $MCU_NAME — $REASON"
  done

  # Shutdown reason
  SHUTDOWN_MSG=$(echo "$SESSION_TEXT" | grep -m1 'Transition to shutdown state:' | sed 's/.*Transition to shutdown state: //' || true)
  if [[ -n "$SHUTDOWN_MSG" ]]; then
    echo ""
    info "Shutdown reason: ${RED}${SHUTDOWN_MSG}${NC}"
  fi

  # Check for EOF (USB disconnect)
  if [[ $HAS_EOF -gt 0 ]]; then
    echo ""
    warn "Got EOF on serial device ($HAS_EOF occurrences) — USB device disconnected"
  fi

  # Last stats before disconnect — extract temperatures and key info
  LAST_STATS=$(echo "$SESSION_TEXT" | grep '^Stats ' | tail -1)
  if [[ -n "$LAST_STATS" ]]; then
    echo ""
    info "${BOLD}Last stats before disconnect:${NC}"

    # MCU temps
    for mcu_temp in $(echo "$LAST_STATS" | grep -oP '\w+: temp=[0-9.]+' || true); do
      NAME=$(echo "$mcu_temp" | cut -d: -f1)
      TEMP=$(echo "$mcu_temp" | grep -oP 'temp=\K[0-9.]+')
      if (( $(echo "$TEMP > 80" | bc -l 2>/dev/null || echo 0) )); then
        err "  $NAME temp: ${TEMP}°C (HIGH)"
      elif (( $(echo "$TEMP > 60" | bc -l 2>/dev/null || echo 0) )); then
        warn "  $NAME temp: ${TEMP}°C (warm)"
      else
        ok "  $NAME temp: ${TEMP}°C"
      fi
    done

    # Retransmit counts
    echo ""
    info "${BOLD}Communication health (from last stats):${NC}"
    for mcu_block in $(echo "$LAST_STATS" | grep -oP '(mcu|toolboard_t0|expander|mmu|beacon): [^ ]+ [^ ]+ [^ ]+ bytes_write=[0-9]+ bytes_read=[0-9]+ bytes_retransmit=[0-9]+ bytes_invalid=[0-9]+' || true); do
      RETRANSMIT=$(echo "$mcu_block" | grep -oP 'bytes_retransmit=\K[0-9]+' || true)
      INVALID=$(echo "$mcu_block" | grep -oP 'bytes_invalid=\K[0-9]+' || true)
      MCU_ID=$(echo "$mcu_block" | cut -d: -f1)
      if [[ "${RETRANSMIT:-0}" -gt 100 ]]; then
        err "  $MCU_ID: retransmit=$RETRANSMIT invalid=${INVALID:-0} (excessive retransmits)"
      elif [[ "${INVALID:-0}" -gt 0 ]]; then
        warn "  $MCU_ID: retransmit=${RETRANSMIT:-0} invalid=$INVALID (has invalid bytes)"
      else
        ok "  $MCU_ID: retransmit=${RETRANSMIT:-0} invalid=${INVALID:-0}"
      fi
    done

    # Sysload / memavail
    SYSLOAD=$(echo "$LAST_STATS" | grep -oP 'sysload=\K[0-9.]+' || true)
    MEMAVAIL=$(echo "$LAST_STATS" | grep -oP 'memavail=\K[0-9]+' || true)
    if [[ -n "$SYSLOAD" ]]; then
      echo ""
      if (( $(echo "$SYSLOAD > 3" | bc -l 2>/dev/null || echo 0) )); then
        err "  System load: $SYSLOAD (HIGH — possible host overload)"
      else
        ok "  System load: $SYSLOAD"
      fi
    fi
    if [[ -n "$MEMAVAIL" ]]; then
      MEMAVAIL_MB=$((MEMAVAIL / 1024))
      if [[ $MEMAVAIL_MB -lt 100 ]]; then
        err "  Available memory: ${MEMAVAIL_MB}MB (LOW — possible OOM)"
      else
        ok "  Available memory: ${MEMAVAIL_MB}MB"
      fi
    fi

    # Print stalls
    STALLS=$(echo "$LAST_STATS" | grep -oP 'print_stall=\K[0-9]+' || true)
    if [[ "${STALLS:-0}" -gt 0 ]]; then
      warn "  Print stalls: $STALLS"
    fi
  fi

  # Check the send queue dump for which MCU it was
  SEND_QUEUE=$(echo "$SESSION_TEXT" | grep -A1 'Dumping send queue' | head -2)
  if [[ -n "$SEND_QUEUE" ]]; then
    QUEUE_COUNT=$(echo "$SEND_QUEUE" | head -1 | grep -oP '[0-9]+ messages' || true)
    echo ""
    info "Send queue at disconnect: $QUEUE_COUNT unanswered"
  fi
done

if [[ $DISCONNECT_COUNT -eq 0 ]]; then
  ok "No disconnects found in any session."
fi

# --- Check for recurring patterns ---
header "Recurring Disconnect Patterns"

# Count all MCU timeouts by MCU name
echo -e "${BOLD}MCU timeout frequency:${NC}"
grep -oP "Timeout with MCU '\K[^']+" "$LOGFILE" | sort | uniq -c | sort -rn | while IFS= read -r line; do
  info "  $line"
done
if ! grep -q 'Timeout with MCU' "$LOGFILE"; then
  ok "  No MCU timeouts in log."
fi

echo ""
echo -e "${BOLD}Shutdown reasons:${NC}"
grep -oP 'Transition to shutdown state: \K.*' "$LOGFILE" | sort | uniq -c | sort -rn | while IFS= read -r line; do
  info "  $line"
done
if ! grep -q 'Transition to shutdown state' "$LOGFILE"; then
  ok "  No shutdowns in log."
fi

# --- Kernel log check (if running on the printer host) ---
if command -v journalctl &>/dev/null; then
  header "Kernel USB Events (last 24h)"

  OC_COUNT=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep -c 'over-current' || true)
  USB_DISCONNECT=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep -c 'USB disconnect' || true)
  USB_RESET_FAIL=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep -c 'cannot reset\|Cannot enable' || true)

  if [[ $OC_COUNT -gt 0 ]]; then
    err "USB over-current events: $OC_COUNT (power delivery problem on USB bus)"
    journalctl -k --since "24 hours ago" 2>/dev/null | grep 'over-current' | \
      awk '{print $1, $2, $3, $NF}' | sort -u | head -10 | while IFS= read -r line; do
      info "    $line"
    done
  else
    ok "No USB over-current events."
  fi

  if [[ $USB_DISCONNECT -gt 0 ]]; then
    warn "USB disconnects: $USB_DISCONNECT"
  fi

  if [[ $USB_RESET_FAIL -gt 0 ]]; then
    err "USB reset failures: $USB_RESET_FAIL"
  fi

  # Check for kernel OOM
  OOM_COUNT=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep -c 'Out of memory\|oom-kill\|oom_reaper' || true)
  if [[ $OOM_COUNT -gt 0 ]]; then
    err "OOM killer events: $OOM_COUNT"
  fi

  # Check for MCU-related USB devices
  echo ""
  info "${BOLD}Current USB Klipper devices:${NC}"
  if command -v lsusb &>/dev/null; then
    lsusb 2>/dev/null | grep -iE 'klipper|stm32|beacon|1d50:614e|04d8:e72b' | while IFS= read -r line; do
      ok "  $line"
    done
  fi
elif [[ -f /var/log/kern.log ]]; then
  header "Kernel USB Events (from kern.log)"
  OC_COUNT=$(grep -c 'over-current' /var/log/kern.log 2>/dev/null || true)
  if [[ $OC_COUNT -gt 0 ]]; then
    err "USB over-current events in kern.log: $OC_COUNT"
  else
    ok "No USB over-current events in kern.log."
  fi
fi

# --- Summary ---
header "Summary"

TOTAL_TIMEOUTS=$(grep -c 'Timeout with MCU' "$LOGFILE" || true)
TOTAL_EOFS=$(grep -c 'Got EOF when reading from device' "$LOGFILE" || true)
TOTAL_SHUTDOWNS=$(grep -c 'Transition to shutdown state' "$LOGFILE" || true)

echo "  Sessions:    $TOTAL_SESSIONS"
echo "  Disconnects: $DISCONNECT_COUNT"
echo "  MCU timeouts: $TOTAL_TIMEOUTS"
echo "  EOF events:  $TOTAL_EOFS"
echo "  Shutdowns:   $TOTAL_SHUTDOWNS"

if [[ $TOTAL_EOFS -gt 0 ]]; then
  echo ""
  warn "EOF events indicate USB-level disconnects (not firmware crashes)."
  info "Common causes:"
  info "  • USB over-current / insufficient power delivery"
  info "  • Loose USB cables or failing hub"
  info "  • EMI from stepper motors / heaters on nearby wiring"
  info "  • Host USB controller driver issues"
  info "  • USB hub power cycling under load"
fi

echo ""
