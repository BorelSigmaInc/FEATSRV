#!/usr/bin/env bash
# Early definition to avoid re-exec timing issues
confirm() {
    local prompt="$1"
    read -r -p "$prompt (y/N): " reply
    [[ "$reply" =~ ^[Yy] ]]
}

# ==============================================================================
#  FEATSRV — Point-in-Time Feature Serving CLI
#  A terminal client for the FEATSRV actuarial feature store API.
#
#  Usage:
#     curl -s https://featsrv.q-dit.com/static/cli.sh | bash
#     ./cli.sh                      (interactive menu)
#     ./cli.sh --health             (non-interactive health check)
#     ./cli.sh --policy POL-0000    (non-interactive lookup)
#     ./cli.sh --claim  CLM-00000   (non-interactive lookup)
#     FEATSRV_API_KEY=xxxx ./cli.sh (skip the key prompt)
#
#  Version: 2.0.0
# ==============================================================================

set -o pipefail
# Note: intentionally NOT using `set -e`. This is a long-lived interactive
# session — a single failed curl or bad keystroke should return the user to
# the menu, not kill the whole program.

VERSION="2.0.0"
API="https://featsrv.q-dit.com"
API_KEY="${FEATSRV_API_KEY:-}"
RESPONSE_DIR=""
LOG_FILE=""
CURL_TIMEOUT=15
CURL_RETRIES=2
JSON_TOOL=""   # "jq" or "python3", detected at startup

# ---------- Colours ----------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_GREEN='\033[32m'
C_CYAN='\033[36m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_BLUE='\033[34m'
C_MAGENTA='\033[35m'

# Disable colour codes automatically when output isn't a terminal
# (e.g. piped to a file or another program).
if [ ! -t 1 ]; then
    C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_CYAN=''
    C_YELLOW=''; C_RED=''; C_BLUE=''; C_MAGENTA=''
fi

# ---------- Cleanup / signal handling ----------
cleanup() {
    echo -e "\n${C_YELLOW}Session interrupted. Partial results (if any) remain in${C_RESET} ${RESPONSE_DIR:-Response-FEATSRV}."
    exit 130
}
trap cleanup INT TERM

# ---------- Logging ----------
log() {
    # $1 = level (INFO/WARN/ERROR), $2 = message
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    [ -n "$LOG_FILE" ] && echo "[$ts] [$1] $2" >> "$LOG_FILE"
}

# ---------- Section headers ----------
section() {
    echo ""
    echo -e "${C_CYAN}${C_BOLD}── $1 ${C_RESET}${C_DIM}$(printf '─%.0s' $(seq 1 $((50 - ${#1}))))${C_RESET}"
}

die() {
    echo -e "${C_RED}✗ $1${C_RESET}" >&2
    log "ERROR" "$1"
    exit "${2:-1}"
}

warn() {
    echo -e "${C_YELLOW}⚠ $1${C_RESET}"
    log "WARN" "$1"
}

ok() {
    echo -e "${C_GREEN}✓ $1${C_RESET}"
}

# ---------- Dependency check ----------
detect_json_tool() {
    if command -v jq &>/dev/null; then
        JSON_TOOL="jq"
    elif command -v python3 &>/dev/null; then
        JSON_TOOL="python3"
    else
        warn "Neither 'jq' nor 'python3' found — output will be shown as raw JSON."
        JSON_TOOL=""
    fi
}

# ---------- Spinner for long-running requests ----------
spinner() {
    local pid=$1 msg=$2
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#frames} ))
        printf "\r${C_CYAN}%s${C_RESET} %s" "${frames:$i:1}" "$msg"
        sleep 0.1
    done
    printf "\r\033[K"
    tput cnorm 2>/dev/null
}

# ---------- Resilient curl wrapper ----------
# api_call METHOD URL [extra curl args...]
# Writes response body to stdout, HTTP status code to $HTTP_STATUS.
api_call() {
    local method="$1" url="$2"
    shift 2
    local attempt=1
    local tmp_body
    tmp_body=$(mktemp)
    local status="000"

    while [ "$attempt" -le "$((CURL_RETRIES + 1))" ]; do
        status=$(curl -s -o "$tmp_body" -w "%{http_code}" \
            --connect-timeout "$CURL_TIMEOUT" --max-time $((CURL_TIMEOUT * 4)) \
            -X "$method" -H "X-API-Key: $API_KEY" "$@" "$url")
        [ "$status" != "000" ] && break
        attempt=$((attempt + 1))
        [ "$attempt" -le "$((CURL_RETRIES + 1))" ] && sleep 1
    done

    HTTP_STATUS="$status"
    cat "$tmp_body"
    rm -f "$tmp_body"
}

# ---------- Pretty-print JSON (fallback chain: jq -> python3 -> raw) ----------
pretty_json() {
    local input="$1"
    case "$JSON_TOOL" in
        jq)      echo "$input" | jq . 2>/dev/null || echo "$input" ;;
        python3) echo "$input" | python3 -m json.tool 2>/dev/null || echo "$input" ;;
        *)       echo "$input" ;;
    esac
}

# ---------- Render a dict of features as an aligned table ----------
render_feature_table() {
    local input="$1"
    echo "$input" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
feats = d.get('features', d if isinstance(d, dict) else {})
if not feats:
    print('  (no features returned)')
    sys.exit(0)
key_w = max(len(str(k)) for k in feats) + 2
print(f\"  {'FEATURE'.ljust(key_w)} VALUE\")
print('  ' + '-' * (key_w + 30))
for k, v in feats.items():
    print(f'  {str(k).ljust(key_w)} {v}')
" 2>/dev/null
}

# ---------- Render a list of dict rows as an aligned table ----------
render_row_table() {
    local input="$1" max_rows="${2:-10}" max_cols="${3:-6}"
    echo "$input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

rows = data.get('rows', data) if isinstance(data, dict) else data
if not isinstance(rows, list) or not rows:
    print('  (no rows returned)')
    sys.exit(0)

cols = list(rows[0].keys())[:$max_cols]
widths = [max(len(c), max((len(str(r.get(c, ''))) for r in rows[:$max_rows]), default=0)) for c in cols]

header = '  ' + ' | '.join(c.ljust(w) for c, w in zip(cols, widths))
print(header)
print('  ' + '-' * (len(header) - 2))
for r in rows[:$max_rows]:
    print('  ' + ' | '.join(str(r.get(c, '')).ljust(w) for c, w in zip(cols, widths)))

total = len(rows)
shown = min(total, $max_rows)
print(f'\n  Showing {shown} of {total} row(s).')
" 2>/dev/null
}

# ---------- Save + present a JSON response ----------
save_response() {
    # save_response <filename> <content>
    local fname="$1" content="$2"
    local path="$RESPONSE_DIR/$fname"
    echo "$content" > "$path"
    ok "Saved to $path"
    log "INFO" "Saved response to $path"
    open_saved_file "$path"
}

# ---------- Open saved file (cross-platform) ----------
open_saved_file() {
    local file="$1"
    [ ! -f "$file" ] && { warn "File not found: $file"; return; }
    read -r -p "Open saved file now? (y/N): " OPEN_CHOICE
    case "$OPEN_CHOICE" in
        [Yy]*)
            if command -v xdg-open &>/dev/null; then xdg-open "$file" &>/dev/null &
            elif command -v open &>/dev/null; then open "$file"
            elif command -v start &>/dev/null; then start "" "$file"
            else warn "Can't open automatically on this system — open '$file' manually."
            fi
            ;;
    esac
}

# ---------- Helpers ----------
create_response_dir() {
    local timestamp
    timestamp=$(date +"%d-%b-%y-%H%M%S")
    RESPONSE_DIR="Response-FEATSRV/Response-FEATSRV-${timestamp}"
    mkdir -p "$RESPONSE_DIR" || die "Could not create output directory $RESPONSE_DIR"
    LOG_FILE="$RESPONSE_DIR/session.log"
}

# Validate an HTTP status and surface a clear message for common failure modes.
check_status() {
    local status="$1" context="$2"
    case "$status" in
        2??) return 0 ;;
        401|403) die "$context: authentication rejected (HTTP $status). Your API key may be invalid or expired." ;;
        404) warn "$context: not found (HTTP $status)."; return 1 ;;
        408|000) warn "$context: request timed out or the server is unreachable (HTTP $status)."; return 1 ;;
        429) warn "$context: rate limited (HTTP $status). Wait a moment and try again."; return 1 ;;
        5??) warn "$context: server error (HTTP $status). This is likely transient — try again shortly."; return 1 ;;
        *) warn "$context: unexpected response (HTTP $status)."; return 1 ;;
    esac
}

require_file() {
    local path="$1"
    if [ -z "$path" ]; then echo -e "${C_RED}No path entered.${C_RESET}"; return 1; fi
    if [ ! -f "$path" ]; then echo -e "${C_RED}File not found: $path${C_RESET}"; return 1; fi
    return 0
}

confirm() {
    local prompt="$1"
    read -r -p "$prompt (y/N): " reply
    [[ "$reply" =~ ^[Yy] ]]
}

# ==============================================================================
#  Services
# ==============================================================================

service_pit_training() {
    section "Point-in-Time Training Set"
    echo "Upload a CSV with columns such as: entity_id (claim or policy), event_timestamp"
    echo -e "${C_DIM}Example header: claim_id,policy_id,event_timestamp${C_RESET}"
    echo ""
    read -r -p "Path to CSV file: " FILE_PATH
    require_file "$FILE_PATH" || return

    create_response_dir
    echo -e "${C_YELLOW}Uploading and generating PIT training set...${C_RESET}"
    api_call POST "$API/pit-training" -F "file=@$FILE_PATH" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "PIT training set" || { save_response "pit_training_error.json" "$RESPONSE"; return; }

    save_response "pit_training_result.json" "$RESPONSE"
    echo -e "${C_BOLD}Preview:${C_RESET}"
    render_row_table "$RESPONSE" 5 5
}

service_online_policy() {
    section "Online Policy Features"
    read -r -p "Policy ID (e.g., POL-0000): " PID
    [ -z "$PID" ] && { echo -e "${C_RED}No policy ID provided.${C_RESET}"; return; }

    api_call GET "$API/online/policy/$PID" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "Policy $PID" || { create_response_dir; save_response "policy_${PID}_error.json" "$RESPONSE"; return; }

    create_response_dir
    echo -e "${C_BOLD}Policy Features for $PID:${C_RESET}"
    render_feature_table "$RESPONSE"
    save_response "policy_${PID}.json" "$RESPONSE"
}

service_online_claim() {
    section "Online Claim Features"
    read -r -p "Claim ID (e.g., CLM-00000): " CID
    [ -z "$CID" ] && { echo -e "${C_RED}No claim ID provided.${C_RESET}"; return; }

    api_call GET "$API/online/claim/$CID" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "Claim $CID" || { create_response_dir; save_response "claim_${CID}_error.json" "$RESPONSE"; return; }

    create_response_dir
    echo -e "${C_BOLD}Claim Features for $CID:${C_RESET}"
    render_feature_table "$RESPONSE"
    save_response "claim_${CID}.json" "$RESPONSE"
}

service_batch_offline() {
    section "Batch Offline Features"
    echo 'Paste your JSON payload and press Ctrl+D when done.'
    echo -e "${C_DIM}Example: {\"entities\":[...],\"features\":[...]}${C_RESET}"
    PAYLOAD=$(cat)
    [ -z "$PAYLOAD" ] && { echo -e "${C_RED}No payload provided.${C_RESET}"; return; }

    if command -v python3 &>/dev/null; then
        echo "$PAYLOAD" | python3 -c "import sys,json;json.load(sys.stdin)" 2>/dev/null \
            || { echo -e "${C_RED}That doesn't look like valid JSON — aborting.${C_RESET}"; return; }
    fi

    create_response_dir
    api_call POST "$API/offline" -H "Content-Type: application/json" -d "$PAYLOAD" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "Batch offline features" || { save_response "batch_offline_error.json" "$RESPONSE"; return; }

    echo -e "${C_BOLD}Result:${C_RESET}"
    render_row_table "$RESPONSE" 5 6
    save_response "batch_offline_result.json" "$RESPONSE"
}

service_leakage_audit() {
    section "Data Leakage Audit"
    echo "Upload a CSV with columns: entity_id, event_timestamp, feature_timestamp, feature_value"
    read -r -p "File path: " FILE_PATH
    require_file "$FILE_PATH" || return

    create_response_dir
    api_call POST "$API/leakage-audit" -F "file=@$FILE_PATH" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "Leakage audit" || { save_response "leakage_audit_error.json" "$RESPONSE"; return; }

    echo -e "${C_BOLD}Leakage Audit Report:${C_RESET}"
    render_feature_table "$RESPONSE"
    save_response "leakage_audit.json" "$RESPONSE"
}

service_feature_importance() {
    section "Feature Importance Summary"
    create_response_dir
    api_call GET "$API/feature-importance" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "Feature importance" || { save_response "feature_importance_error.json" "$RESPONSE"; return; }

    echo -e "${C_BOLD}Top Features by Importance:${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not data:
    print('  (no data returned)')
    sys.exit(0)
print(f\"  {'FEATURE'.ljust(30)} IMPORTANCE  {'BAR'}\")
print('  ' + '-' * 65)
max_imp = max(item.get('importance', 0) for item in data) or 1
for item in data[:10]:
    name = str(item.get('feature', '?'))[:30]
    imp = item.get('importance', 0)
    bar_len = int((imp / max_imp) * 20)
    bar = '█' * bar_len
    print(f'  {name.ljust(30)} {imp:>9.4f}  {bar}')
" 2>/dev/null || pretty_json "$RESPONSE"
    save_response "feature_importance.json" "$RESPONSE"
}

service_health() {
    section "System Health Check"
    api_call GET "$API/health" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    if check_status "$HTTP_STATUS" "Health check"; then
        echo -e "${C_BOLD}Server Status:${C_RESET}"
        render_feature_table "{\"features\": $RESPONSE}" 2>/dev/null
        echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k, v in d.items():
    print(f'  {str(k).ljust(15)}: {v}')
" 2>/dev/null
    fi
    create_response_dir
    save_response "health.json" "$RESPONSE"
}

# ==============================================================================
#  Non-interactive mode (flags)
# ==============================================================================
run_noninteractive() {
    case "$1" in
        --health) service_health ;;
        --policy) [ -n "${2:-}" ] || die "Usage: --policy <POLICY_ID>"; echo "$2" | { read -r PID; service_online_policy_direct "$2"; } ;;
        --claim)  [ -n "${2:-}" ] || die "Usage: --claim <CLAIM_ID>"; service_online_claim_direct "$2" ;;
        --version) echo "FEATSRV CLI v$VERSION"; exit 0 ;;
        --help|-h) show_help; exit 0 ;;
        *) die "Unknown flag: $1. Use --help for usage." ;;
    esac
    exit 0
}

service_online_policy_direct() {
    PID="$1"
    api_call GET "$API/online/policy/$PID" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "Policy $PID" || exit 1
    create_response_dir
    render_feature_table "$RESPONSE"
    echo "$RESPONSE" > "$RESPONSE_DIR/policy_${PID}.json"
    ok "Saved to $RESPONSE_DIR/policy_${PID}.json"
}

service_online_claim_direct() {
    CID="$1"
    api_call GET "$API/online/claim/$CID" > "/tmp/featsrv_resp_$$" && RESPONSE=$(cat "/tmp/featsrv_resp_$$"); rm -f "/tmp/featsrv_resp_$$"
    check_status "$HTTP_STATUS" "Claim $CID" || exit 1
    create_response_dir
    render_feature_table "$RESPONSE"
    echo "$RESPONSE" > "$RESPONSE_DIR/claim_${CID}.json"
    ok "Saved to $RESPONSE_DIR/claim_${CID}.json"
}

show_help() {
    cat <<EOF
FEATSRV CLI v$VERSION — Point-in-Time Feature Serving

Usage:
  ./cli.sh                      Launch interactive menu
  ./cli.sh --health             Run a health check and exit
  ./cli.sh --policy <ID>        Fetch policy features and exit
  ./cli.sh --claim  <ID>        Fetch claim features and exit
  ./cli.sh --version            Print version
  ./cli.sh --help               Show this message

Environment:
  FEATSRV_API_KEY   Set this to skip the interactive key prompt.
EOF
}

# ==============================================================================
#  Entry point
# ==============================================================================
detect_json_tool

if [ "$#" -gt 0 ]; then
    # Non-interactive flag mode requires the API key up front.
    if [ -z "$API_KEY" ]; then
        read -r -s -p "FEATSRV API key: " API_KEY; echo ""
    fi
    [ -z "$API_KEY" ] && die "No API key provided."
    run_noninteractive "$@"
fi

# Re-execute with a terminal if stdin is not a tty (e.g. curl | bash)
if [ ! -t 0 ]; then
    TMP_SCRIPT=$(mktemp /tmp/featsrv-cli.XXXXXX.sh)
    cat > "$TMP_SCRIPT"
    chmod +x "$TMP_SCRIPT"
    exec bash "$TMP_SCRIPT" </dev/tty
fi

clear
echo -e "${C_CYAN}${C_BOLD}=================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}     FEATSRV — Point-in-Time Feature API  v${VERSION}${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}=================================================${C_RESET}"
echo ""
echo "This tool generates leakage-free training data and fetches"
echo "real-time features for actuarial models."
echo ""
echo -e "Before proceeding, please note:"
echo -e "  • Data is transmitted over HTTPS"
echo -e "  • Results are saved locally under ${C_BOLD}Response-FEATSRV/${C_RESET}"
echo -e "  • Uploaded files are not retained by the server"
echo ""

if ! confirm "Do you consent to proceed?"; then
    echo -e "${C_RED}Session aborted.${C_RESET}"
    exit 0
fi
ok "Consent received."

if [ -z "$API_KEY" ]; then
    read -r -s -p "FEATSRV API key (input hidden): " API_KEY
    echo ""
fi
[ -z "$API_KEY" ] && die "No API key provided."

echo -e "${C_YELLOW}Verifying credentials...${C_RESET}"
STATUS_CHECK=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_TIMEOUT" -H "X-API-Key: $API_KEY" "$API/health")
case "$STATUS_CHECK" in
    200) ok "API key verified." ;;
    401|403) die "Invalid API key (HTTP $STATUS_CHECK)." ;;
    000) die "Could not reach $API — check your network connection." ;;
    *) die "Unexpected response verifying key (HTTP $STATUS_CHECK)." ;;
esac
echo ""

REQUEST_COUNT=0

while true; do
    echo -e "${C_BOLD}Available Services${C_RESET} ${C_DIM}(session requests: $REQUEST_COUNT)${C_RESET}"
    echo ""
    echo "  1. Point-in-Time Training Set    — upload CSV, get leakage-free training rows"
    echo "  2. Online Policy Features        — real-time lookup by policy ID"
    echo "  3. Online Claim Features         — real-time lookup by claim ID"
    echo "  4. Batch Offline Features        — POST a JSON payload of entities"
    echo "  5. Data Leakage Audit            — upload CSV, get a leakage report"
    echo "  6. Feature Importance Summary    — ranked feature importances"
    echo "  7. System Health Check           — server status"
    echo "  0. Exit"
    echo ""
    read -r -p "Select a service (0-7): " CHOICE

    case "$CHOICE" in
        0) echo -e "${C_GREEN}Goodbye.${C_RESET}"; exit 0 ;;
        1) service_pit_training; REQUEST_COUNT=$((REQUEST_COUNT + 1)) ;;
        2) service_online_policy; REQUEST_COUNT=$((REQUEST_COUNT + 1)) ;;
        3) service_online_claim; REQUEST_COUNT=$((REQUEST_COUNT + 1)) ;;
        4) service_batch_offline; REQUEST_COUNT=$((REQUEST_COUNT + 1)) ;;
        5) service_leakage_audit; REQUEST_COUNT=$((REQUEST_COUNT + 1)) ;;
        6) service_feature_importance; REQUEST_COUNT=$((REQUEST_COUNT + 1)) ;;
        7) service_health; REQUEST_COUNT=$((REQUEST_COUNT + 1)) ;;
        *) echo -e "${C_RED}Invalid choice — enter a number from 0 to 7.${C_RESET}" ;;
    esac
    echo ""
    read -r -p "Press Enter to return to menu..." _
done
