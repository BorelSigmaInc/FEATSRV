#!/usr/bin/env bash
# FEATSRV – Point‑in‑Time Feature Serving CLI
# Usage: curl -s https://featsrv.q-dit.com/cli | bash
# Re-execute with terminal if stdin is not a tty (e.g., piped from curl)
if [ ! -t 0 ]; then
    TMP_SCRIPT=$(mktemp /tmp/featsrv-cli.XXXXXX.sh)
    cat > "$TMP_SCRIPT"
    exec bash "$TMP_SCRIPT" </dev/tty
fi


API="https://featsrv.q-dit.com"
API_KEY=""
RESPONSE_DIR=""

# ---------- Colours ----------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_CYAN='\033[36m'
C_YELLOW='\033[33m'
C_RED='\033[31m'

# ---------- Welcome ----------
clear
echo -e "${C_CYAN}${C_BOLD}============================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}     FEATSRV – Point‑in‑Time Feature API     ${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}============================================${C_RESET}"
echo ""
echo -e "Welcome to the FEATSRV terminal interface."
echo -e "This tool helps you generate leakage‑free training data"
echo -e "and fetch real‑time features for actuarial models."
echo ""
echo -e "Before proceeding, please note:"
echo -e " • Your data is processed securely via HTTPS"
echo -e " • Results are saved locally in a ${C_BOLD}Response-FEATSRV${C_RESET} folder"
echo -e " • We do not store your uploaded files"
echo ""
read -p "Do you consent to proceed? (Y/N): " CONSENT

if [[ "$CONSENT" != "Y" && "$CONSENT" != "y" ]]; then
    echo -e "${C_RED}Session aborted. Goodbye.${C_RESET}"
    exit 0
fi

# ---------- Authorise ----------
echo ""
echo -e "${C_GREEN}✓ Consent received.${C_RESET}"
echo -e "${C_YELLOW}Authorising with FEATSRV API...${C_RESET}"
echo ""
read -p "Please enter your API key: " API_KEY

if [ -z "$API_KEY" ]; then
    echo -e "${C_RED}No API key provided. Aborting.${C_RESET}"
    exit 1
fi

# Verify API key with server
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $API_KEY" "$API/health")
if [ "$STATUS" != "200" ]; then
    echo -e "${C_RED}Invalid API key or server unreachable. Aborting.${C_RESET}"
    exit 1
fi

echo -e "${C_GREEN}✓ API key verified.${C_RESET}"
echo ""

# ---------- Main Menu ----------
while true; do
    echo -e "${C_BOLD}Available Services:${C_RESET}"
    echo ""
    echo "  1. Point‑in‑Time Training Set (upload CSV/JSON/Excel)"
    echo "  2. Online Policy Features (real‑time from Redis)"
    echo "  3. Online Claim Features (real‑time from Redis)"
    echo "  4. Batch Offline Features (POST JSON)"
    echo "  5. Data Leakage Audit (upload CSV + report)"
    echo "  6. Feature Importance Summary"
    echo "  7. System Health Check"
    echo "  0. Exit"
    echo ""
    read -p "Select a service (0–7): " CHOICE

    case $CHOICE in
        0) echo -e "${C_GREEN}Goodbye.${C_RESET}"; exit 0 ;;
        1) service_pit_training ;;
        2) service_online_policy ;;
        3) service_online_claim ;;
        4) service_batch_offline ;;
        5) service_leakage_audit ;;
        6) service_feature_importance ;;
        7) service_health ;;
        *) echo -e "${C_RED}Invalid choice. Try again.${C_RESET}" ;;
    esac
    echo ""
    read -p "Press Enter to return to menu..."
done
# ---------- Service Functions ----------

create_response_dir() {
    TIMESTAMP=$(date +"%d-%b-%y-%H%M")
    RESPONSE_DIR="Response-FEATSRV/Response-FEATSRV-${TIMESTAMP}"
    mkdir -p "$RESPONSE_DIR"
}

print_table() {
    echo "$1" | while IFS= read -r line; do
        echo -e "  ${C_CYAN}$line${C_RESET}"
    done
}

# 1. PIT Training Set
service_pit_training() {
    echo -e "${C_YELLOW}--- Point‑in‑Time Training Set ---${C_RESET}"
    echo ""
    echo "Upload a CSV file with columns: entity_id (claim or policy), event_timestamp"
    echo "Example CSV:"
    echo "  claim_id,policy_id,event_timestamp"
    echo "  CLM-00001,POL-001,2024-06-01T00:00:00"
    echo ""
    read -p "Enter the full path to your CSV file: " FILE_PATH
    
    if [ ! -f "$FILE_PATH" ]; then
        echo -e "${C_RED}File not found: $FILE_PATH${C_RESET}"
        return
    fi
    
    create_response_dir
    echo -e "${C_YELLOW}Uploading and generating PIT training set...${C_RESET}"
    
    RESPONSE=$(curl -s -X POST "$API/pit-training" \
        -H "X-API-Key: $API_KEY" \
        -F "file=@$FILE_PATH")
    
    echo "$RESPONSE" > "$RESPONSE_DIR/pit_training_result.json"
    echo ""
    echo -e "${C_GREEN}Result saved to: $RESPONSE_DIR/pit_training_result.json${C_RESET}"
    echo ""
    echo -e "${C_BOLD}Preview (first 5 rows):${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'error' in data:
    print('Error:', data['error'])
else:
    rows = data.get('rows', [])
    cols = data.get('columns', [])
    print(' | '.join(cols[:5]))
    print('-' * 60)
    for row in rows[:5]:
        print(' | '.join(str(row.get(c, '')) for c in cols[:5]))
    print(f'Total rows: {len(rows)}')
" 2>/dev/null || echo "$RESPONSE" | head -20
}

# 2. Online Policy Features
service_online_policy() {
    echo -e "${C_YELLOW}--- Online Policy Features ---${C_RESET}"
    echo ""
    read -p "Enter policy ID (e.g., POL-0000): " PID
    if [ -z "$PID" ]; then
        echo -e "${C_RED}No policy ID provided.${C_RESET}"
        return
    fi
    
    RESPONSE=$(curl -s -H "X-API-Key: $API_KEY" "$API/online/policy/$PID")
    create_response_dir
    echo "$RESPONSE" > "$RESPONSE_DIR/policy_${PID}.json"
    
    echo ""
    echo -e "${C_BOLD}Policy Features for $PID:${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
feats = data.get('features', {})
for k, v in feats.items():
    print(f'  {k:20s}: {v}')
" 2>/dev/null || echo "$RESPONSE"
    echo ""
    echo -e "${C_GREEN}Saved: $RESPONSE_DIR/policy_${PID}.json${C_RESET}"
}

# 3. Online Claim Features
service_online_claim() {
    echo -e "${C_YELLOW}--- Online Claim Features ---${C_RESET}"
    echo ""
    read -p "Enter claim ID (e.g., CLM-00000): " CID
    if [ -z "$CID" ]; then
        echo -e "${C_RED}No claim ID provided.${C_RESET}"
        return
    fi
    
    RESPONSE=$(curl -s -H "X-API-Key: $API_KEY" "$API/online/claim/$CID")
    create_response_dir
    echo "$RESPONSE" > "$RESPONSE_DIR/claim_${CID}.json"
    
    echo ""
    echo -e "${C_BOLD}Claim Features for $CID:${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
feats = data.get('features', {})
for k, v in feats.items():
    print(f'  {k:20s}: {v}')
" 2>/dev/null || echo "$RESPONSE"
    echo ""
    echo -e "${C_GREEN}Saved: $RESPONSE_DIR/claim_${CID}.json${C_RESET}"
}

# 4. Batch Offline Features
service_batch_offline() {
    echo -e "${C_YELLOW}--- Batch Offline Features ---${C_RESET}"
    echo ""
    echo "Enter a JSON payload (paste and press Ctrl+D when done):"
    echo "Example:"
    echo '{"entities":[{"claim_id":"CLM-00000","policy_id":"POL-0050","event_timestamp":"2025-09-16T00:00:00"}],"features":["policy_features:initial_premium","claim_features:claim_amount"]}'
    echo ""
    PAYLOAD=$(cat)
    
    if [ -z "$PAYLOAD" ]; then
        echo -e "${C_RED}No payload provided.${C_RESET}"
        return
    fi
    
    create_response_dir
    RESPONSE=$(curl -s -X POST "$API/offline" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $API_KEY" \
        -d "$PAYLOAD")
    
    echo "$RESPONSE" > "$RESPONSE_DIR/batch_offline_result.json"
    echo ""
    echo -e "${C_BOLD}Result:${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list) and len(data) > 0:
    cols = list(data[0].keys())
    print(' | '.join(cols[:6]))
    print('-' * 80)
    for row in data[:5]:
        print(' | '.join(str(row.get(c, '')) for c in cols[:6]))
    print(f'Total rows: {len(data)}')
else:
    print(data)
" 2>/dev/null || echo "$RESPONSE" | head -20
    echo ""
    echo -e "${C_GREEN}Saved: $RESPONSE_DIR/batch_offline_result.json${C_RESET}"
}

# 5. Data Leakage Audit
service_leakage_audit() {
    echo -e "${C_YELLOW}--- Data Leakage Audit ---${C_RESET}"
    echo ""
    echo "Upload a CSV with columns: entity_id, timestamp, feature_value"
    read -p "Enter file path: " FILE_PATH
    
    if [ ! -f "$FILE_PATH" ]; then
        echo -e "${C_RED}File not found.${C_RESET}"
        return
    fi
    
    create_response_dir
    RESPONSE=$(curl -s -X POST "$API/leakage-audit" \
        -H "X-API-Key: $API_KEY" \
        -F "file=@$FILE_PATH")
    
    echo "$RESPONSE" > "$RESPONSE_DIR/leakage_audit.json"
    echo ""
    echo -e "${C_BOLD}Leakage Audit Report:${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for k, v in data.items():
    print(f'  {k:25s}: {v}')
" 2>/dev/null || echo "$RESPONSE"
    echo ""
    echo -e "${C_GREEN}Saved: $RESPONSE_DIR/leakage_audit.json${C_RESET}"
}

# 6. Feature Importance Summary
service_feature_importance() {
    echo -e "${C_YELLOW}--- Feature Importance Summary ---${C_RESET}"
    echo ""
    create_response_dir
    RESPONSE=$(curl -s -H "X-API-Key: $API_KEY" "$API/feature-importance")
    echo "$RESPONSE" > "$RESPONSE_DIR/feature_importance.json"
    echo -e "${C_BOLD}Feature Importance:${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'{\"Feature\":30s} {\"Importance Score\"}')
print('-' * 50)
for item in data[:10]:
    print(f'{item[\"feature\"]:30s} {item[\"importance\"]:.4f}')
" 2>/dev/null || echo "$RESPONSE"
    echo ""
    echo -e "${C_GREEN}Saved: $RESPONSE_DIR/feature_importance.json${C_RESET}"
}

# 7. System Health Check
service_health() {
    echo -e "${C_YELLOW}--- System Health Check ---${C_RESET}"
    echo ""
    RESPONSE=$(curl -s -H "X-API-Key: $API_KEY" "$API/health")
    echo -e "${C_BOLD}Server Status:${C_RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for k, v in data.items():
    print(f'  {k:15s}: {v}')
" 2>/dev/null || echo "$RESPONSE"
}


