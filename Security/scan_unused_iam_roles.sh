#!/bin/bash

set -euo pipefail

# Configuration
readonly INACTIVE_THRESHOLD_DAYS="${INACTIVE_THRESHOLD_DAYS:-90}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-./reports}"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly OUTPUT_FILE="$OUTPUT_DIR/iam_unused_roles_$TIMESTAMP.csv"
readonly SCAN_PROFILE="iam-scan-temp"
readonly SCAN_ROLE="MdlzPlatformReader"

log_info() { echo "ℹ️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }
log_success() { echo "✅ $*" >&2; }

check_dependencies() {
    for cmd in aws jq awslogin; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "$cmd is required but not installed"
            exit 1
        fi
    done
}

get_accounts() {
    local token=$(jq -r '.accessToken' ~/.aws/sso/cache/*.json 2>/dev/null | head -1)
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "No valid SSO token found. Please run 'awslogin' first."
        exit 1
    fi
    
    aws sso list-accounts --access-token "$token" | jq -r '.accountList[] | "\(.accountId):\(.accountName)"'
}

scan_account_roles() {
    local account_id="$1"
    local account_name="$2"
    
    log_info "Scanning account: $account_name ($account_id)"
    
    # Use awslogin to configure profile for this account with MdlzPlatformReader role
    echo "$account_id" | awslogin --profile "$SCAN_PROFILE" --role "$SCAN_ROLE" >/dev/null 2>&1 || {
        log_error "Failed to login to account $account_id with role $SCAN_ROLE"
        return
    }
    
    local roles=$(aws iam list-roles --profile "$SCAN_PROFILE" 2>/dev/null | jq -r '.Roles[].RoleName' || echo "")
    
    if [[ -z "$roles" ]]; then
        log_error "Failed to list roles for account $account_id"
        return
    fi
    
    while IFS= read -r role; do
        [[ -z "$role" ]] && continue
        
        local role_info=$(aws iam get-role --role-name "$role" --profile "$SCAN_PROFILE" 2>/dev/null || echo "")
        [[ -z "$role_info" ]] && continue
        
        local last_used=$(echo "$role_info" | jq -r '.Role.RoleLastUsed.LastUsedDate // "Never"')
        local days_inactive="N/A"
        
        if [[ "$last_used" != "Never" && "$last_used" != "null" ]]; then
            local last_used_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_used%Z*}" +%s 2>/dev/null || echo "0")
            local now_epoch=$(date +%s)
            days_inactive=$(( (now_epoch - last_used_epoch) / 86400 ))
        else
            last_used="Never"
            days_inactive="∞"
        fi
        
        echo "$account_id,$account_name,$role,$last_used,$days_inactive"
    done <<< "$roles"
}

generate_report() {
    mkdir -p "$OUTPUT_DIR"
    
    echo "AccountID,AccountName,RoleName,LastUsed,DaysInactive" > "$OUTPUT_FILE"
    
    local total_roles=0
    local inactive_roles=0
    
    while IFS=: read -r account_id account_name; do
        [[ -z "$account_id" ]] && continue
        
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo "$line" >> "$OUTPUT_FILE"
            
            ((total_roles++))
            
            local days=$(echo "$line" | cut -d, -f5)
            if [[ "$days" == "∞" ]] || [[ "$days" =~ ^[0-9]+$ && "$days" -ge "$INACTIVE_THRESHOLD_DAYS" ]]; then
                ((inactive_roles++))
            fi
        done < <(scan_account_roles "$account_id" "$account_name")
    done < <(get_accounts)
    
    log_success "Report generated: $OUTPUT_FILE"
    echo ""
    echo "Summary Statistics:"
    echo "  Total Roles: $total_roles"
    echo "  Inactive Roles (>$INACTIVE_THRESHOLD_DAYS days): $inactive_roles"
    [[ $total_roles -gt 0 ]] && echo "  Percentage Inactive: $(( inactive_roles * 100 / total_roles ))%"
}

main() {
    check_dependencies
    log_info "Starting IAM unused roles scan (threshold: $INACTIVE_THRESHOLD_DAYS days)"
    generate_report
}

main "$@"
