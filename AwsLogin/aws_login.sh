#!/bin/bash

set -euo pipefail

# =============================================================================
# AWS SSO Login Script - Refactored Version
# 
# NOTE: This script is not owned or authored by the repository owner.
# It is included here for reference and integration purposes only.
# =============================================================================

# Global Configuration
readonly SSO_START_URL="${SSO_START_URL:-}"
readonly SSO_REGION="us-east-2"
readonly DEFAULT_REGION="us-east-2"
readonly DEFAULT_OUTPUT="json"
readonly LAST_USED_FILE="$HOME/.aws/last-sso-selection"
readonly CACHE_DIR="/tmp"
readonly ACCOUNTS_CACHE_TTL=900  # 15 minutes

# Global Variables
FILTER=""
PROFILE_NAME="default"
SELECTED_ROLE=""
SSO_ALREADY_LOGGED_IN=false
OS_TYPE="unknown"
ACCESS_TOKEN=""
CACHE_FILE_PATH=""

# Cleanup array for temp files
declare -a TEMP_FILES=()

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo "ℹ️  $*" >&2
}

log_warn() {
    echo "⚠️  $*" >&2
}

log_error() {
    echo "❌ $*" >&2
}

log_success() {
    echo "✅ $*" >&2
}

cleanup() {
    # Wait for any background processes to complete, but don't fail if there are none
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    
    # Clean up temp files
    for f in "${TEMP_FILES[@]:-}"; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
    done
}

# =============================================================================
# System Detection and Dependencies
# =============================================================================

detect_os() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        OS_TYPE="wsl"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
    fi
    log_info "Detected OS: $OS_TYPE"
}

validate_config() {
    if [[ -z "$SSO_START_URL" ]]; then
        log_error "SSO_START_URL environment variable is not set"
        log_error "Please set it in your environment or .env file"
        exit 1
    fi
}

check_or_install_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_warn "$tool is required but not installed."
        read -p "Do you want to install $tool? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            install_tool "$tool"
        else
            log_error "Aborting. Please install $tool and re-run the script."
            exit 1
        fi
    fi
}

install_tool() {
    local tool="$1"
    case "$OS_TYPE" in
        wsl)
            sudo apt update && sudo apt install -y "$tool"
            ;;
        macos)
            brew install "$tool"
            ;;
        *)
            log_error "Unsupported OS for automatic installation."
            exit 1
            ;;
    esac
}

check_dependencies() {
    # Check AWS CLI version
    if ! aws --version | grep -q 'aws-cli/2'; then
        log_error "aws-cli v2 is required. Please install or upgrade to AWS CLI version 2."
        exit 1
    fi
    
    # Check other dependencies
    for cmd in jq fzf; do
        check_or_install_tool "$cmd"
    done
}

# =============================================================================
# Environment Management
# =============================================================================

unset_conflicting_env_vars() {
    local unset_vars=()
    for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE; do
        if [[ -n "${!var:-}" ]]; then
            unset "$var"
            unset_vars+=("$var")
        fi
    done

    if [[ ${#unset_vars[@]} -gt 0 ]]; then
        log_warn "The following environment variables were set and have been unset to avoid conflicts:"
        for v in "${unset_vars[@]}"; do 
            echo "  - $v"
        done
    fi
}

# =============================================================================
# SSO Token Management
# =============================================================================

get_latest_cache_file() {
    CACHE_FILE_PATH=$(ls -t ~/.aws/sso/cache/*.json 2>/dev/null | head -1 || true)
}

extract_access_token() {
    if [[ -n "$CACHE_FILE_PATH" && -f "$CACHE_FILE_PATH" ]]; then
        ACCESS_TOKEN=$(jq -r '.accessToken' "$CACHE_FILE_PATH" 2>/dev/null || echo "")
    fi
}

validate_sso_token() {
    if [[ -z "$CACHE_FILE_PATH" || ! -f "$CACHE_FILE_PATH" ]]; then
        return 1
    fi

    local expires_at=$(jq -r '.registrationExpiresAt' "$CACHE_FILE_PATH" 2>/dev/null || echo "")
    local now_epoch=$(date +%s)
    local expires_at_epoch=""

    if [[ -n "$expires_at" && "$expires_at" != "null" ]]; then
        if [[ "$OS_TYPE" == "macos" ]]; then
            expires_at_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null || echo "")
        else
            expires_at_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo "")
        fi
    fi

    [[ -n "$expires_at_epoch" && "$now_epoch" -lt "$expires_at_epoch" ]]
}

perform_sso_login() {
    log_info "Logging in to AWS SSO..."
    
    case "$OS_TYPE" in
        wsl)
            local sso_output_file="/tmp/sso-output.txt"
            TEMP_FILES+=("$sso_output_file")
            
            log_info "Attempting optimized WSL SSO login..."
            
            # Strategy 1: Try to trick AWS CLI into generating full URL by setting BROWSER
            # This might make it generate the full URL even though we'll capture it
            export BROWSER="echo"  # Set browser to echo so it doesn't actually open
            
            # Capture the output from a normal login attempt
            timeout 15s aws sso login --profile "$PROFILE_NAME" > "$sso_output_file" 2>&1 || true
            
            # Look for the full authorization URL with all parameters
            local full_auth_url=$(grep -o 'https://[^[:space:]]*authorize[^[:space:]]*' "$sso_output_file" | head -1)
            
            # Unset the BROWSER variable
            unset BROWSER
            
            if [[ -n "$full_auth_url" && "$full_auth_url" == *"authorize"* ]]; then
                log_success "Found complete authorization URL!"
                log_info "Opening browser with full authorization URL..."
                powershell.exe -Command "Start-Process '$full_auth_url'"
                log_info "Authentication should complete automatically - no code entry needed!"
                
                # Wait for authentication to complete
                local max_wait=90
                local wait_count=0
                log_info "Waiting for authentication to complete..."
                
                while [[ $wait_count -lt $max_wait ]]; do
                    sleep 2
                    get_latest_cache_file
                    extract_access_token
                    if [[ -n "$ACCESS_TOKEN" ]]; then
                        log_success "Authentication completed successfully!"
                        return 0
                    fi
                    ((wait_count += 2))
                    if [[ $((wait_count % 10)) -eq 0 ]]; then
                        log_info "Still waiting for authentication... ($wait_count/${max_wait}s)"
                    fi
                done
                
                log_warn "Authentication taking longer than expected, but continuing..."
            else
                # Strategy 2: Enhanced device code flow with smart URL construction
                log_info "Full URL not available, using enhanced device code flow..."
                
                # Clear the output file and try device code flow
                > "$sso_output_file"
                aws sso login --no-browser --profile "$PROFILE_NAME" > "$sso_output_file" 2>&1 &
                local sso_pid=$!
                
                sleep 3
                
                local device_url=$(grep -o 'https://[^[:space:]]*' "$sso_output_file" | head -1)
                local device_code=$(grep -o '[A-Z0-9]\{4\}-[A-Z0-9]\{4\}' "$sso_output_file" | head -1)
                
                if [[ -n "$device_url" && -n "$device_code" ]]; then
                    # Try multiple enhanced URL formats that might auto-fill the code
                    local enhanced_urls=(
                        "${device_url}?user_code=${device_code}"
                        "${device_url}?code=${device_code}"
                        "${device_url}#${device_code}"
                        "${device_url}/${device_code}"
                    )
                    
                    log_info "Device URL: $device_url"
                    log_info "Device code: $device_code"
                    log_info "Trying enhanced URL with embedded code..."
                    
                    # Copy code to clipboard as backup
                    echo "$device_code" | clip.exe
                    
                    # Try the first enhanced URL format
                    powershell.exe -Command "Start-Process '${enhanced_urls[0]}'"
                    
                    log_success "Enhanced URL opened: ${enhanced_urls[0]}"
                    log_info "If the code isn't auto-filled, it's copied to your clipboard: $device_code"
                else
                    log_warn "Could not extract device URL or code. Showing full output:"
                    cat "$sso_output_file"
                fi
                
                wait $sso_pid
            fi
            ;;
        *)
            # For non-WSL systems, use standard login
            aws sso login --profile "$PROFILE_NAME" || true
            ;;
    esac
    
    SSO_ALREADY_LOGGED_IN=true
    get_latest_cache_file
    extract_access_token
    
    # Verify the login actually worked
    if [[ -z "$ACCESS_TOKEN" ]]; then
        log_error "SSO login failed - no access token found"
        exit 1
    fi
}

ensure_valid_sso_token() {
    get_latest_cache_file
    
    if [[ -n "$CACHE_FILE_PATH" ]]; then
        extract_access_token
        if validate_sso_token; then
            log_success "SSO token is still valid."
            return 0
        else
            log_info "SSO token missing or expired. Re-authenticating..."
        fi
    else
        log_info "No cached token found. Performing initial login..."
    fi
    
    perform_sso_login
}

# =============================================================================
# Account Management
# =============================================================================

get_accounts_cache_file() {
    echo "$CACHE_DIR/aws-sso-accounts-cache.json"
}

is_accounts_cache_stale() {
    local cache_file="$1"
    if [[ ! -f "$cache_file" ]]; then
        return 0  # No cache file means stale
    fi
    
    local cache_age
    if [[ "$OS_TYPE" == "macos" ]]; then
        cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || echo "0") ))
    else
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo "0") ))
    fi
    
    [[ $cache_age -gt $ACCOUNTS_CACHE_TTL ]]
}

fetch_accounts() {
    local output_file="$1"
    if ! aws sso list-accounts --access-token "$ACCESS_TOKEN" > "$output_file" 2>/tmp/sso-error.log; then
        if grep -q 'UnauthorizedException' /tmp/sso-error.log; then
            log_warn "SSO token is invalid. Re-authenticating..."
            perform_sso_login
            aws sso list-accounts --access-token "$ACCESS_TOKEN" > "$output_file"
        else
            log_error "Unexpected error during list-accounts. Check /tmp/sso-error.log"
            cat /tmp/sso-error.log
            exit 1
        fi
    fi
}

get_accounts_list() {
    local cache_file=$(get_accounts_cache_file)
    local temp_cache_file="/tmp/aws-sso-accounts-cache-tmp.json"
    TEMP_FILES+=("$temp_cache_file")

    if [[ -s "$cache_file" ]]; then
        log_info "Using cached AWS account list..."
        # Always use the existing cache file, never invalidate it
        cp "$cache_file" "$temp_cache_file" || {
            log_error "Failed to copy cache file, but continuing with original cache"
            temp_cache_file="$cache_file"  # Use cache file directly if copy fails
        }

        # Only refresh in background if cache is stale, never block or invalidate
        if is_accounts_cache_stale "$cache_file"; then
            log_info "Refreshing account cache in background..."
            (
                sleep 1
                # Create a temporary file for the refresh to avoid corrupting the cache
                local refresh_temp="/tmp/aws-sso-accounts-refresh-$$.json"
                if fetch_accounts "$refresh_temp" 2>/dev/null; then
                    mv "$refresh_temp" "$cache_file" && log_info "AWS account cache updated."
                else
                    rm -f "$refresh_temp" 2>/dev/null
                fi
            ) >/dev/null 2>&1 &
        fi
    else
        log_info "Building account cache for the first time..."
        # Only create cache if it doesn't exist at all
        if fetch_accounts "$temp_cache_file"; then
            cp "$temp_cache_file" "$cache_file" 2>/dev/null || true
        else
            log_error "Failed to fetch accounts on first run"
            exit 1
        fi
    fi

    # Verify the temp file exists and has content
    if [[ ! -s "$temp_cache_file" ]]; then
        log_error "Failed to create accounts cache file"
        exit 1
    fi

    echo "$temp_cache_file"
}

select_account() {
    local accounts_file="$1"
    local account_selection_raw=$(jq -r '.accountList[] | [.accountName, .accountId] | @tsv' "$accounts_file" | sort)

    if [[ -z "$account_selection_raw" ]]; then
        log_error "No accounts available. Exiting."
        exit 1
    fi

    local account_matches=$(echo "$account_selection_raw" | grep -i "$FILTER" || true)
    local account_selection=""

    if [[ $(echo "$account_matches" | wc -l) -eq 1 && -n "$account_matches" ]]; then
        account_selection="$account_matches"
        log_success "One account matched filter '$FILTER': auto-selected."
    else
        account_selection=$(echo "$account_selection_raw" \
            | awk -F $'\t' '{ printf "%-40s\t%s\n", $1, $2 }' \
            | fzf --query "$FILTER" \
                  --delimiter $'\t' \
                  --preview "
                      ID=\$(echo {} | cut -f2)
                      jq -r --arg ID \"\$ID\" \".accountList[] | select(.accountId == \\\$ID)\" \"$accounts_file\"
                  ")
    fi

    if [[ -z "$account_selection" ]]; then
        log_error "No account selected. Exiting."
        exit 1
    fi

    local account_id=$(echo "$account_selection" | cut -f2)
    local account_name=$(echo "$account_selection_raw" | grep "$account_id" | cut -f1)
    
    echo "$account_id:$account_name"
}

# =============================================================================
# Role Management
# =============================================================================

get_roles_cache_file() {
    local account_id="$1"
    echo "$CACHE_DIR/aws-sso-roles-$account_id.json"
}

fetch_roles() {
    local account_id="$1"
    local output_file="$2"
    
    if ! aws sso list-account-roles --account-id "$account_id" --access-token "$ACCESS_TOKEN" > "$output_file" 2>/tmp/sso-roles-error.log; then
        if grep -q 'UnauthorizedException' /tmp/sso-roles-error.log; then
            log_warn "Role lookup failed: invalid SSO token. Re-authenticating..."
            perform_sso_login
            aws sso list-account-roles --account-id "$account_id" --access-token "$ACCESS_TOKEN" > "$output_file"
        else
            log_error "Unexpected error fetching roles. See /tmp/sso-roles-error.log"
            cat /tmp/sso-roles-error.log
            exit 1
        fi
    fi
}

get_roles_list() {
    local account_id="$1"
    
    if [[ -z "$account_id" ]]; then
        log_error "Account ID is required for role lookup"
        exit 1
    fi
    
    local cache_file=$(get_roles_cache_file "$account_id")
    local temp_cache_file="/tmp/aws-sso-roles-$account_id-tmp.json"
    TEMP_FILES+=("$temp_cache_file")

    if [[ -f "$cache_file" && -s "$cache_file" ]]; then
        log_info "Using cached roles for account $account_id..."
        # Always use existing cache, never invalidate it
        cp "$cache_file" "$temp_cache_file" || {
            log_error "Failed to copy roles cache, but continuing with original cache"
            temp_cache_file="$cache_file"  # Use cache file directly if copy fails
        }
        
        # Always refresh roles in background (roles change less frequently than accounts)
        (
            local refresh_temp="/tmp/aws-sso-roles-refresh-$account_id-$$.json"
            if fetch_roles "$account_id" "$refresh_temp" 2>/dev/null; then
                mv "$refresh_temp" "$cache_file" && log_info "Role cache updated for account $account_id."
            else
                rm -f "$refresh_temp" 2>/dev/null
            fi
        ) >/dev/null 2>&1 &
    else
        log_info "No cached roles found for account $account_id. Fetching..."
        # Only fetch fresh data if no cache exists at all
        if fetch_roles "$account_id" "$temp_cache_file"; then
            cp "$temp_cache_file" "$cache_file" 2>/dev/null || true
        else
            log_error "Failed to fetch roles for account $account_id"
            exit 1
        fi
    fi

    # Verify the temp file exists and has content
    if [[ ! -s "$temp_cache_file" ]]; then
        log_error "Failed to get roles for account $account_id"
        exit 1
    fi

    echo "$temp_cache_file"
}

prioritize_roles() {
    awk '
        $0 == "MdlzDevOpsOwner" { print "1 " $0; next }
        $0 == "MdlzPlatformOperator" { print "2 " $0; next }
        $0 == "MdlzPlatformReader" { print "3 " $0; next }
        { print "9 " $0 }
    ' | sort | cut -d" " -f2-
}

select_role() {
    local roles_file="$1"
    local role_list=$(jq -r '.roleList[].roleName' "$roles_file")
    
    if [[ -z "$role_list" ]]; then
        log_error "No roles available for this account."
        exit 1
    fi

    # If role was specified via command line, try to match it
    if [[ -n "$SELECTED_ROLE" ]]; then
        local matched_role=$(echo "$role_list" | grep -i "$SELECTED_ROLE" | head -1 || true)
        if [[ -n "$matched_role" ]]; then
            log_success "Using fuzzy matched role: $matched_role"
            echo "$matched_role"
            return
        else
            log_error "No matching role found for '$SELECTED_ROLE'. Exiting."
            exit 1
        fi
    fi

    # If only one role available, auto-select it
    if [[ $(echo "$role_list" | wc -l) -eq 1 ]]; then
        log_success "Only one role available: $role_list. Auto-selected."
        echo "$role_list"
        return
    fi

    # Interactive selection with prioritization
    local selected_role=$(echo "$role_list" | prioritize_roles | fzf --preview '
        role=$(echo {} | sed "s/[^A-Za-z0-9_.-]//g")
        doc="docs/$role.txt"
        if [[ -f "$doc" ]]; then
            cat "$doc"
        else
            echo "No documentation available for role: $role"
        fi
    ')

    if [[ -z "$selected_role" ]]; then
        log_error "No role selected. Exiting."
        exit 1
    fi

    echo "$selected_role"
}

# =============================================================================
# Profile Configuration
# =============================================================================

check_existing_token_match() {
    local account_id="$1"
    local role_name="$2"
    
    local token_file=$(ls -t ~/.aws/sso/cache/*.json 2>/dev/null | head -1 || true)
    
    if [[ -n "$token_file" ]]; then
        local token_account=$(jq -r '.accountId // empty' "$token_file")
        local token_role=$(jq -r '.roleName // empty' "$token_file")
        local token_start=$(jq -r '.startUrl // empty' "$token_file")

        if [[ "$token_account" == "$account_id" && "$token_role" == "$role_name" && "$token_start" == "$SSO_START_URL" ]]; then
            return 0  # Match found
        fi
    fi
    
    return 1  # No match
}

configure_profile_from_existing() {
    log_success "Token matches target account, role, and start URL. Reusing config for '$PROFILE_NAME'."
    for key in sso_start_url sso_region region output; do
        local value=$(aws configure get "$key" --profile default 2>/dev/null || echo "")
        [[ -n "$value" ]] && aws configure set "$key" "$value" --profile "$PROFILE_NAME"
    done
}

configure_profile_fresh() {
    local account_id="$1"
    local role_name="$2"
    
    aws configure set sso_start_url "$SSO_START_URL" --profile "$PROFILE_NAME"
    aws configure set sso_region "$SSO_REGION" --profile "$PROFILE_NAME"
    aws configure set sso_account_id "$account_id" --profile "$PROFILE_NAME"
    aws configure set sso_role_name "$role_name" --profile "$PROFILE_NAME"
    aws configure set region "$DEFAULT_REGION" --profile "$PROFILE_NAME"
    aws configure set output "$DEFAULT_OUTPUT" --profile "$PROFILE_NAME"

    if [[ "$SSO_ALREADY_LOGGED_IN" != true ]]; then
        perform_sso_login
    fi
}

configure_aws_profile() {
    local account_id="$1"
    local role_name="$2"
    
    if check_existing_token_match "$account_id" "$role_name"; then
        configure_profile_from_existing
    else
        configure_profile_fresh "$account_id" "$role_name"
    fi
    
    # Save last used selection
    echo "$account_id:$role_name" > "$LAST_USED_FILE"
}

# =============================================================================
# Main Workflow Functions
# =============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                PROFILE_NAME="$2"
                shift 2
                ;;
            --role)
                SELECTED_ROLE="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                FILTER="$1"
                shift
                ;;
        esac
    done
}

show_help() {
    cat << EOF
AWS SSO Login Script

Usage: $0 [OPTIONS] [FILTER]

OPTIONS:
    --profile PROFILE    Use specified AWS profile (default: default)
    --role ROLE         Pre-select role (fuzzy matching)
    --help, -h          Show this help message

ARGUMENTS:
    FILTER              Filter accounts by name (optional)

Examples:
    $0                          # Interactive login
    $0 prod                     # Filter accounts containing 'prod'
    $0 --profile myprofile      # Use specific profile
    $0 --role operator prod     # Pre-select role and filter accounts
EOF
}

show_session_summary() {
    local account_id="$1"
    local account_name="$2"
    local role_name="$3"
    
    echo ""
    log_success "Profile '$PROFILE_NAME' is now configured:"
    echo "  Account    : $account_name ($account_id)"
    echo "  Role       : $role_name"
    echo "  Region     : $DEFAULT_REGION"
    echo ""

    if [[ "$PROFILE_NAME" == "default" ]]; then
        echo "Try a command like:"
        echo "  aws sts get-caller-identity"
    else
        echo "Try a command like:"
        echo "  aws sts get-caller-identity --profile $PROFILE_NAME"
    fi
}

main() {
    # Setup
    trap cleanup EXIT
    parse_arguments "$@"
    detect_os
    validate_config
    check_dependencies
    unset_conflicting_env_vars
    
    # Authentication
    ensure_valid_sso_token
    
    # Account Selection
    local accounts_file=$(get_accounts_list)
    if [[ ! -f "$accounts_file" || ! -s "$accounts_file" ]]; then
        log_error "Failed to get accounts list"
        exit 1
    fi
    
    local account_info=$(select_account "$accounts_file")
    if [[ -z "$account_info" || "$account_info" == ":" ]]; then
        log_error "Failed to select account"
        exit 1
    fi
    
    local account_id=$(echo "$account_info" | cut -d: -f1)
    local account_name=$(echo "$account_info" | cut -d: -f2)
    
    if [[ -z "$account_id" ]]; then
        log_error "Invalid account selection"
        exit 1
    fi
    
    # Role Selection
    local roles_file=$(get_roles_list "$account_id")
    if [[ ! -f "$roles_file" || ! -s "$roles_file" ]]; then
        log_error "Failed to get roles list for account $account_id"
        exit 1
    fi
    
    local role_name=$(select_role "$roles_file")
    if [[ -z "$role_name" ]]; then
        log_error "Failed to select role"
        exit 1
    fi
    
    # Configuration
    configure_aws_profile "$account_id" "$role_name"
    
    # Summary
    show_session_summary "$account_id" "$account_name" "$role_name"
}

# =============================================================================
# Script Entry Point
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    # Explicit success exit after main completes
    exit 0
fi
