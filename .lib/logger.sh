#!/bin/bash
# Enhanced Logger System v3.0
# Production-quality logging framework for Bash scripts
# Provides comprehensive logging with colors, formatting, timers, progress bars,
# tables, banners, key-value output, step tracking, and session summaries.
#
# Dependencies: settings.cfg, palette.sh
# Requires: Bash 4+ (associative arrays, declare -g)
#
# Source Dependency Chain (must be sourced in order):
#   1. .config/settings.cfg  -- exports LOG_LEVEL, ENABLE_COLORS, LOG_FILE, feature flags
#   2. .config/palette.sh    -- provides COLOR_PALETTE associative array
#   3. .lib/logger.sh        -- this file; call initiate_logger after sourcing

#===============================================================================
# GLOBAL VARIABLES AND STATE
#===============================================================================

# Logger state tracking
declare -g  LOGGER_INITIALIZED=false
declare -g  LOGGER_VERSION="3.0"
declare -g  LOGGER_START_TIME=""

# Session counters -- incremented by _log_event on every qualifying call
declare -g  LOG_ERROR_COUNT=0
declare -g  LOG_WARNING_COUNT=0
declare -g  LOG_ENTRY_COUNT=0

# Named timers for profiling (associative: name -> epoch seconds)
declare -gA LOG_TIMERS=()

# Structured logging (JSONL dual-write)
declare -g JSONL_LOG_FILE=""
declare -g JSONL_ENABLED=false

#===============================================================================
# DEPENDENCY DETECTION
#===============================================================================

# Locate settings.cfg and palette.sh using flexible path detection.
# Sets FOUND_SETTINGS_PATH and FOUND_PALETTE_PATH on success.
_check_dependencies() {
    local settings_found=false
    local palette_found=false

    # Candidate paths for settings.cfg
    local possible_settings=(
        "${BASE_DIR}/.config/settings.cfg"
        "${BASE_DIR}/.scripts/settings.cfg"
        "${COMPOSE_DIR}/../.config/settings.cfg"
        "${COMPOSE_DIR}/settings.cfg"
        "./settings.cfg"
        "./.config/settings.cfg"
    )

    # Candidate paths for palette.sh
    local possible_palettes=(
        "${BASE_DIR}/.config/palette.sh"
        "${BASE_DIR}/.scripts/palette.sh"
        "${COMPOSE_DIR}/../.config/palette.sh"
        "${COMPOSE_DIR}/palette.sh"
        "./palette.sh"
        "./.config/palette.sh"
    )

    for config in "${possible_settings[@]}"; do
        if [[ -f "$config" ]]; then
            export FOUND_SETTINGS_PATH="$config"
            settings_found=true
            break
        fi
    done

    for palette in "${possible_palettes[@]}"; do
        if [[ -f "$palette" ]]; then
            export FOUND_PALETTE_PATH="$palette"
            palette_found=true
            break
        fi
    done

    local missing_deps=()
    [[ "$settings_found" != "true" ]] && missing_deps+=("settings.cfg")
    [[ "$palette_found"  != "true" ]] && missing_deps+=("palette.sh")
    [[ -z "${LOG_FILE:-}" ]]          && missing_deps+=("LOG_FILE variable")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "Logger Error: Missing dependencies: ${missing_deps[*]}" >&2
        echo "  Searched paths for settings.cfg: ${possible_settings[*]}" >&2
        echo "  Searched paths for palette.sh:   ${possible_palettes[*]}" >&2
        return 1
    fi

    return 0
}

#===============================================================================
# DURATION FORMATTING UTILITY
#===============================================================================

# Convert a number of seconds into a human-readable duration string.
# Examples:
#   _format_duration 0       -> "0s"
#   _format_duration 45      -> "45s"
#   _format_duration 930     -> "15m 30s"
#   _format_duration 8130    -> "2h 15m 30s"
#   _format_duration 90061   -> "1d 1h 1m 1s"
_format_duration() {
    local total_seconds="${1:-0}"

    # Guard against non-numeric input
    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]]; then
        echo "0s"
        return 0
    fi

    local days=$(( total_seconds / 86400 ))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))

    local result=""
    (( days    > 0 )) && result+="${days}d "
    (( hours   > 0 )) && result+="${hours}h "
    (( minutes > 0 )) && result+="${minutes}m "

    # Always show seconds (even "0s" for zero-length durations)
    result+="${seconds}s"

    echo "$result"
}

#===============================================================================
# LOGGER INITIALIZATION AND MANAGEMENT
#===============================================================================

# Initialize the logger system.
# Must be called once before any log_* function.  Safe to call multiple times
# (subsequent calls are no-ops).
initiate_logger() {
    # Prevent double initialization
    if [[ "$LOGGER_INITIALIZED" == "true" ]]; then
        return 0
    fi

    # Check dependencies before initialization
    if ! _check_dependencies; then
        echo "Logger initialization failed due to missing dependencies" >&2
        return 1
    fi

    # Source required files using discovered paths
    export PALETTE_QUIET=true
    source "${FOUND_SETTINGS_PATH}" || {
        echo "Failed to source settings.cfg from ${FOUND_SETTINGS_PATH}" >&2
        return 1
    }
    source "${FOUND_PALETTE_PATH}" || {
        echo "Failed to source palette.sh from ${FOUND_PALETTE_PATH}" >&2
        return 1
    }
    unset PALETTE_QUIET

    # Create log directory if it doesn't exist
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"

    # Create archive directory if it doesn't exist
    local archive_dir="${LOG_DIR}/archive"
    [[ ! -d "$archive_dir" ]] && mkdir -p "$archive_dir"

    # Archive existing log file if it exists and has content
    if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
        local timestamp
        timestamp=$(date '+%Y%m%d_%H%M%S')
        local archive_file="${archive_dir}/docker-services_${timestamp}.log"

        mv "$LOG_FILE" "$archive_file"

        if command -v gzip >/dev/null 2>&1; then
            gzip "$archive_file"
            log_nodate_info "Previous log archived to: ${archive_file}.gz" >&2
        else
            log_nodate_info "Previous log archived to: $archive_file" >&2
        fi
    fi

    # Initialize fresh log file with header
    {
        echo "==============================================================================="
        echo "Logger System v${LOGGER_VERSION} - Session Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Application: ${APPLICATION_TITLE:-Unknown Application}"
        echo "Script Version: ${SCRIPT_VERSION:-Unknown Version}"
        echo "Log Level: ${LOG_LEVEL:-INFO}"
        echo "Verbose Mode: ${VERBOSE_MODE:-false}"
        echo "==============================================================================="
        echo ""
    } > "$LOG_FILE"

    # Reset counters and timers for this session
    LOG_ERROR_COUNT=0
    LOG_WARNING_COUNT=0
    LOG_ENTRY_COUNT=0
    LOG_TIMERS=()

    # Set global variables
    export LOGGER_INITIALIZED=true
    export LOGGER_START_TIME="$(date '+%s')"

    # Initialize structured JSONL logging if enabled
    if [[ "${ENABLE_STRUCTURED_LOGGING:-true}" == "true" ]]; then
        JSONL_LOG_FILE="${LOG_FILE%.log}.jsonl"
        JSONL_ENABLED=true
        touch "$JSONL_LOG_FILE" 2>/dev/null
    fi

    _log_event "SUCCESS" "Logger System v${LOGGER_VERSION} initialized successfully" "NODATE"

    return 0
}

# Gracefully close the logger with a comprehensive session summary.
close_logger() {
    if [[ "$LOGGER_INITIALIZED" != "true" ]]; then
        return 0
    fi

    # Calculate session duration
    local duration_str="unknown"
    local raw_seconds=0
    if [[ -n "$LOGGER_START_TIME" ]]; then
        local end_time
        end_time="$(date '+%s')"
        raw_seconds=$(( end_time - LOGGER_START_TIME ))
        duration_str="$(_format_duration "$raw_seconds")"
    fi

    # Determine overall session status word
    local session_status="OK"
    (( LOG_WARNING_COUNT > 0 )) && session_status="WARNINGS"
    (( LOG_ERROR_COUNT   > 0 )) && session_status="ERRORS"

    # Write a pretty box-drawing session summary to both console and file
    local border_top="+--------------------------+-----------------+"
    local border_mid="+--------------------------+-----------------+"
    local border_bot="+--------------------------+-----------------+"

    local summary_lines=()
    summary_lines+=("$border_top")
    summary_lines+=("$(printf '| %-24s | %-15s |' "Session Summary"    "")")
    summary_lines+=("$border_mid")
    summary_lines+=("$(printf '| %-24s | %-15s |' "Duration"           "$duration_str")")
    summary_lines+=("$(printf '| %-24s | %-15s |' "Total Log Entries"  "$LOG_ENTRY_COUNT")")
    summary_lines+=("$(printf '| %-24s | %-15s |' "Errors"             "$LOG_ERROR_COUNT")")
    summary_lines+=("$(printf '| %-24s | %-15s |' "Warnings"           "$LOG_WARNING_COUNT")")
    summary_lines+=("$(printf '| %-24s | %-15s |' "Status"             "$session_status")")
    summary_lines+=("$border_bot")

    # Print summary to console with color
    local color_code="${COLOR_PALETTE[FOCUS]:-}"
    local reset_code="${COLOR_PALETTE[RESET]:-}"
    echo ""
    for line in "${summary_lines[@]}"; do
        echo -e "${color_code}${line}${reset_code}"
    done

    # Print summary to log file (plain text)
    {
        echo ""
        for line in "${summary_lines[@]}"; do
            echo "$line"
        done
    } >> "$LOG_FILE"

    _log_event "INFO" "Logger session ended (Duration: ${duration_str})" "NODATE"

    {
        echo ""
        echo "--- Session Ended: $(date '+%Y-%m-%d %H:%M:%S') (Duration: ${duration_str}) ---"
        echo ""
    } >> "$LOG_FILE"

    # Write session summary to JSONL
    if [[ "$JSONL_ENABLED" == "true" && -n "$JSONL_LOG_FILE" ]]; then
        _log_jsonl "SESSION" "Logger session closed" \
            "duration" "$duration_str" \
            "duration_seconds" "$raw_seconds" \
            "errors" "$LOG_ERROR_COUNT" \
            "warnings" "$LOG_WARNING_COUNT" \
            "entries" "$LOG_ENTRY_COUNT" \
            "status" "$session_status"
    fi

    export LOGGER_INITIALIZED=false
}

#===============================================================================
# STRUCTURED LOGGING (JSONL)
#===============================================================================

# Escape a string for JSON embedding (minimal, fast)
_jsonl_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Write a structured JSONL log entry alongside the plain text output
# Usage: _log_jsonl "LEVEL" "message" ["extra_key" "extra_value" ...]
_log_jsonl() {
    [[ "$JSONL_ENABLED" != "true" ]] && return 0
    [[ -z "$JSONL_LOG_FILE" ]] && return 0

    local level="$1"
    local message="$2"
    shift 2

    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local json="{\"ts\":\"${ts}\",\"level\":\"${level}\",\"msg\":\"$(_jsonl_escape "$message")\""
    json+=",\"entry\":${LOG_ENTRY_COUNT:-0}"
    json+=",\"pid\":$$"

    # Add optional extra fields (key-value pairs)
    while [[ $# -ge 2 ]]; do
        json+=",\"$1\":\"$(_jsonl_escape "$2")\""
        shift 2
    done

    json+="}"

    printf '%s\n' "$json" >> "$JSONL_LOG_FILE" 2>/dev/null
}

#===============================================================================
# CORE LOGGING ENGINE
#===============================================================================

# Core logging function -- processes every log call.
# Arguments:
#   $1 - mood    (e.g. INFO, ERROR, SUCCESS, DEBUG, ...)
#   $2 - message
#   $3 - flags   (space-separated: BOLD, NODATE, CUSTOM)
_log_event() {
    local mood="$1"
    local message="$2"
    local flags="${3:-}"

    # Validate inputs
    [[ -z "$mood" ]]    && { echo "Logger Error: No mood specified" >&2; return 1; }
    [[ -z "$message" ]] && { echo "Logger Error: No message specified" >&2; return 1; }

    # Initialize if not already done
    [[ "$LOGGER_INITIALIZED" != "true" ]] && initiate_logger

    # Parse flags
    local is_bold=false
    local is_nodate=false
    local is_custom=false

    [[ "$flags" == *"BOLD"* ]]   && is_bold=true
    [[ "$flags" == *"NODATE"* ]] && is_nodate=true
    [[ "$flags" == *"CUSTOM"* ]] && is_custom=true

    # Check if we should log this level
    if ! _should_log_level "$mood"; then
        return 0
    fi

    # Increment session counters
    (( LOG_ENTRY_COUNT++ )) || true

    case "$mood" in
        ERROR|CRITICAL|ALERT)
            (( LOG_ERROR_COUNT++ )) || true
            ;;
        WARNING|CAUTION)
            (( LOG_WARNING_COUNT++ )) || true
            ;;
    esac

    # Build console and file outputs
    local console_output
    local file_output

    console_output="$(_build_console_output "$mood" "$message" "$is_bold" "$is_nodate" "$is_custom")"
    file_output="$(_build_file_output "$mood" "$message" "$is_nodate" "$is_custom")"

    # Output to console and file
    echo -e "$console_output"
    echo "$file_output" >> "$LOG_FILE"

    # Handle special actions for certain log levels
    _handle_special_actions "$mood" "$message"

    # Write structured JSONL entry (dual-write)
    _log_jsonl "$mood" "$message"

    return 0
}

# Determine if we should log based on level hierarchy.
# Returns 0 (true) if the message should be emitted.
_should_log_level() {
    local mood="$1"

    # Log level hierarchy (lower number = higher priority)
    declare -A level_priority=(
        ["ERROR"]=1
        ["ALERT"]=1
        ["CRITICAL"]=1
        ["WARNING"]=2
        ["CAUTION"]=2
        ["IMPORTANT"]=3
        ["SUCCESS"]=3
        ["CONFIRMATION"]=3
        ["INFO"]=4
        ["STATUS"]=4
        ["FOCUS"]=4
        ["STEP"]=4
        ["TIMING"]=4
        ["HIGHLIGHT"]=5
        ["NOTE"]=5
        ["TIP"]=5
        ["DEBUG"]=6
        ["VERBOSE"]=7
        ["NEUTRAL"]=8
    )

    # Map configured LOG_LEVEL to its numeric priority
    declare -A current_priority=(
        ["ERROR"]=1
        ["WARNING"]=2
        ["INFO"]=4
        ["DEBUG"]=6
        ["VERBOSE"]=7
    )

    local mood_priority="${level_priority[$mood]:-4}"
    local current_level_priority="${current_priority[${LOG_LEVEL:-INFO}]:-4}"

    # Log if mood priority is equal or higher (lower number)
    [[ $mood_priority -le $current_level_priority ]]
}

# Build console output with colors and formatting.
_build_console_output() {
    local mood="$1"
    local message="$2"
    local is_bold="$3"
    local is_nodate="$4"
    local is_custom="$5"

    local prefix=""
    local color_code=""
    local reset_code="${COLOR_PALETTE[RESET]}"

    # Get color for mood
    color_code="${COLOR_PALETTE[$mood]:-${COLOR_PALETTE[NEUTRAL]}}"

    # Apply bold if requested
    [[ "$is_bold" == "true" ]] && color_code="$(tput bold)${color_code}"

    # Build timestamp prefix
    if [[ "$ENABLE_LOG_DATE" == "true" && "$is_nodate" == "false" ]]; then
        prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    # Build mood prefix
    if [[ "$mood" == "INFO_HEADER" && "$ENABLE_INFO_HEADER" == "true" ]]; then
        if [[ "$USE_CUSTOM_INFO_HEADER" == "true" ]]; then
            prefix="${prefix}${color_code}${CUSTOM_INFO_HEADER_TEXT}${reset_code}"
        else
            prefix="${prefix}${color_code}[INFO_HEADER]${reset_code}"
        fi
    else
        prefix="${prefix}${color_code}[${mood}]${reset_code}"
    fi

    # Add separator and message
    [[ -n "$prefix" ]] && prefix="${prefix} - "

    echo "${prefix}${color_code}${message}${reset_code}"
}

# Build file output without colors.
_build_file_output() {
    local mood="$1"
    local message="$2"
    local is_nodate="$3"
    local is_custom="$4"

    local prefix=""

    # Build timestamp prefix
    if [[ "$ENABLE_LOG_DATE" == "true" && "$is_nodate" == "false" ]]; then
        prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    # Build mood prefix
    if [[ "$mood" == "INFO_HEADER" && "$ENABLE_INFO_HEADER" == "true" ]]; then
        if [[ "$USE_CUSTOM_INFO_HEADER" == "true" ]]; then
            prefix="${prefix}${CUSTOM_INFO_HEADER_TEXT}"
        else
            prefix="${prefix}[INFO_HEADER]"
        fi
    else
        prefix="${prefix}[${mood}]"
    fi

    # Add separator and message
    [[ -n "$prefix" ]] && prefix="${prefix} - "

    echo "${prefix}${message}"
}

# Handle special actions for certain log levels.
_handle_special_actions() {
    local mood="$1"
    local message="$2"

    case "$mood" in
        "ERROR"|"CRITICAL")
            # Error-specific handling (notifications, stack traces, etc.)
            ;;
        "DEBUG")
            [[ "$VERBOSE_MODE" == "true" ]] && \
                echo "  -> Debug context: ${BASH_SOURCE[3]:-unknown}:${BASH_LINENO[2]:-unknown}" >&2
            ;;
    esac
}

#===============================================================================
# STANDARD LOGGING FUNCTIONS
#===============================================================================

# Core log levels
log_info()     { _log_event "INFO"     "$1" "${2:-}"; }
log_success()  { _log_event "SUCCESS"  "$1" "${2:-}"; }
log_warning()  { _log_event "WARNING"  "$1" "${2:-}"; }
log_error()    { _log_event "ERROR"    "$1" "${2:-}"; }
log_debug()    { _log_event "DEBUG"    "$1" "${2:-}"; }

# Extended log levels
log_info_header()   { _log_event "INFO_HEADER"   "$1" "${2:-}"; }
log_important()     { _log_event "IMPORTANT"     "$1" "${2:-}"; }
log_note()          { _log_event "NOTE"          "$1" "${2:-}"; }
log_tip()           { _log_event "TIP"           "$1" "${2:-}"; }
log_confirmation()  { _log_event "CONFIRMATION"  "$1" "${2:-}"; }
log_alert()         { _log_event "ALERT"         "$1" "${2:-}"; }
log_caution()       { _log_event "CAUTION"       "$1" "${2:-}"; }
log_focus()         { _log_event "FOCUS"         "$1" "${2:-}"; }
log_highlight()     { _log_event "HIGHLIGHT"     "$1" "${2:-}"; }
log_neutral()       { _log_event "NEUTRAL"       "$1" "${2:-}"; }
log_prompt()        { _log_event "PROMPT"        "$1" "${2:-}"; }
log_status()        { _log_event "STATUS"        "$1" "${2:-}"; }
log_verbose()       { _log_event "VERBOSE"       "$1" "${2:-}"; }
log_question()      { _log_event "QUESTION"      "$1" "${2:-}"; }
log_critical()      { _log_event "CRITICAL"      "$1" "${2:-}"; }

#===============================================================================
# CONVENIENCE FUNCTION VARIANTS
#===============================================================================

# ---- Bold variants -----------------------------------------------------------

log_bold_info()          { _log_event "INFO"         "$1" "BOLD"; }
log_bold_success()       { _log_event "SUCCESS"      "$1" "BOLD"; }
log_bold_warning()       { _log_event "WARNING"      "$1" "BOLD"; }
log_bold_error()         { _log_event "ERROR"        "$1" "BOLD"; }
log_bold_debug()         { _log_event "DEBUG"        "$1" "BOLD"; }
log_bold_important()     { _log_event "IMPORTANT"    "$1" "BOLD"; }
log_bold_note()          { _log_event "NOTE"         "$1" "BOLD"; }
log_bold_tip()           { _log_event "TIP"          "$1" "BOLD"; }
log_bold_confirmation()  { _log_event "CONFIRMATION" "$1" "BOLD"; }
log_bold_alert()         { _log_event "ALERT"        "$1" "BOLD"; }
log_bold_caution()       { _log_event "CAUTION"      "$1" "BOLD"; }
log_bold_focus()         { _log_event "FOCUS"        "$1" "BOLD"; }
log_bold_highlight()     { _log_event "HIGHLIGHT"    "$1" "BOLD"; }
log_bold_neutral()       { _log_event "NEUTRAL"      "$1" "BOLD"; }
log_bold_prompt()        { _log_event "PROMPT"       "$1" "BOLD"; }
log_bold_status()        { _log_event "STATUS"       "$1" "BOLD"; }
log_bold_verbose()       { _log_event "VERBOSE"      "$1" "BOLD"; }
log_bold_question()      { _log_event "QUESTION"     "$1" "BOLD"; }
log_bold_critical()      { _log_event "CRITICAL"     "$1" "BOLD"; }

# ---- No-date variants --------------------------------------------------------

log_nodate_info()          { _log_event "INFO"          "$1" "NODATE"; }
log_nodate_success()       { _log_event "SUCCESS"       "$1" "NODATE"; }
log_nodate_warning()       { _log_event "WARNING"       "$1" "NODATE"; }
log_nodate_error()         { _log_event "ERROR"         "$1" "NODATE"; }
log_nodate_debug()         { _log_event "DEBUG"         "$1" "NODATE"; }
log_nodate_info_header()   { _log_event "INFO_HEADER"   "$1" "NODATE"; }
log_nodate_important()     { _log_event "IMPORTANT"     "$1" "NODATE"; }
log_nodate_note()          { _log_event "NOTE"          "$1" "NODATE"; }
log_nodate_tip()           { _log_event "TIP"           "$1" "NODATE"; }
log_nodate_confirmation()  { _log_event "CONFIRMATION"  "$1" "NODATE"; }
log_nodate_alert()         { _log_event "ALERT"         "$1" "NODATE"; }
log_nodate_caution()       { _log_event "CAUTION"       "$1" "NODATE"; }
log_nodate_focus()         { _log_event "FOCUS"         "$1" "NODATE"; }
log_nodate_highlight()     { _log_event "HIGHLIGHT"     "$1" "NODATE"; }
log_nodate_neutral()       { _log_event "NEUTRAL"       "$1" "NODATE"; }
log_nodate_prompt()        { _log_event "PROMPT"        "$1" "NODATE"; }
log_nodate_status()        { _log_event "STATUS"        "$1" "NODATE"; }
log_nodate_verbose()       { _log_event "VERBOSE"       "$1" "NODATE"; }
log_nodate_question()      { _log_event "QUESTION"      "$1" "NODATE"; }
log_nodate_critical()      { _log_event "CRITICAL"      "$1" "NODATE"; }

# ---- Bold no-date variants ---------------------------------------------------

log_bold_nodate_info()          { _log_event "INFO"          "$1" "BOLD NODATE"; }
log_bold_nodate_success()       { _log_event "SUCCESS"       "$1" "BOLD NODATE"; }
log_bold_nodate_warning()       { _log_event "WARNING"       "$1" "BOLD NODATE"; }
log_bold_nodate_error()         { _log_event "ERROR"         "$1" "BOLD NODATE"; }
log_bold_nodate_debug()         { _log_event "DEBUG"         "$1" "BOLD NODATE"; }
log_bold_nodate_info_header()   { _log_event "INFO_HEADER"   "$1" "BOLD NODATE"; }
log_bold_nodate_important()     { _log_event "IMPORTANT"     "$1" "BOLD NODATE"; }
log_bold_nodate_note()          { _log_event "NOTE"          "$1" "BOLD NODATE"; }
log_bold_nodate_tip()           { _log_event "TIP"           "$1" "BOLD NODATE"; }
log_bold_nodate_confirmation()  { _log_event "CONFIRMATION"  "$1" "BOLD NODATE"; }
log_bold_nodate_alert()         { _log_event "ALERT"         "$1" "BOLD NODATE"; }
log_bold_nodate_caution()       { _log_event "CAUTION"       "$1" "BOLD NODATE"; }
log_bold_nodate_focus()         { _log_event "FOCUS"         "$1" "BOLD NODATE"; }
log_bold_nodate_highlight()     { _log_event "HIGHLIGHT"     "$1" "BOLD NODATE"; }
log_bold_nodate_neutral()       { _log_event "NEUTRAL"       "$1" "BOLD NODATE"; }
log_bold_nodate_prompt()        { _log_event "PROMPT"        "$1" "BOLD NODATE"; }
log_bold_nodate_status()        { _log_event "STATUS"        "$1" "BOLD NODATE"; }
log_bold_nodate_verbose()       { _log_event "VERBOSE"       "$1" "BOLD NODATE"; }
log_bold_nodate_question()      { _log_event "QUESTION"      "$1" "BOLD NODATE"; }
log_bold_nodate_critical()      { _log_event "CRITICAL"      "$1" "BOLD NODATE"; }

#===============================================================================
# PROGRESS BAR
#===============================================================================

# Display a progress bar for multi-step operations.
# Arguments:
#   $1 - description  (e.g. "Starting stacks")
#   $2 - current step (e.g. 3)
#   $3 - total steps  (e.g. 10)
#
# Output example:
#   [INFO] Starting stacks [███████░░░░░░░░░░░░░░░░░░░░░░░] 30%
#
# Uses $PROGRESS_BAR_WIDTH from settings.cfg (default 30).
log_progress() {
    local description="$1"
    local current="${2:-0}"
    local total="${3:-1}"

    # Prevent division by zero
    (( total <= 0 )) && total=1

    local bar_width="${PROGRESS_BAR_WIDTH:-30}"
    local percent=$(( (current * 100) / total ))
    local filled=$(( (current * bar_width) / total ))
    local empty=$(( bar_width - filled ))

    # Build the bar using unicode block characters
    local bar=""
    local i
    for (( i = 0; i < filled; i++ )); do
        bar+="\xe2\x96\x88"   # U+2588 FULL BLOCK
    done
    for (( i = 0; i < empty; i++ )); do
        bar+="\xe2\x96\x91"   # U+2591 LIGHT SHADE
    done

    local mood="INFO"

    # Check if we should log this level
    if ! _should_log_level "$mood"; then
        return 0
    fi

    # Increment entry counter
    (( LOG_ENTRY_COUNT++ )) || true

    # Console output with color
    local color_code="${COLOR_PALETTE[INFO]:-}"
    local reset_code="${COLOR_PALETTE[RESET]:-}"
    local bold_code=""
    [[ -n "${COLOR_PALETTE[BOLD]:-}" ]] && bold_code="${COLOR_PALETTE[BOLD]}"

    local timestamp_prefix=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        timestamp_prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    local console_line="${timestamp_prefix}${color_code}[INFO]${reset_code} - ${color_code}${description} [$(echo -e "${bar}")] ${percent}%${reset_code}"
    echo -e "$console_line"

    # File output (plain text -- use ASCII approximation)
    local file_bar=""
    for (( i = 0; i < filled; i++ )); do
        file_bar+="#"
    done
    for (( i = 0; i < empty; i++ )); do
        file_bar+="-"
    done

    local file_timestamp=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        file_timestamp="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    echo "${file_timestamp}[INFO] - ${description} [${file_bar}] ${percent}%" >> "$LOG_FILE"

    return 0
}

#===============================================================================
# STEP LOGGING
#===============================================================================

# Log a numbered step for sequential operations.
# Arguments:
#   $1 - current step number (e.g. 1)
#   $2 - total steps         (e.g. 5)
#   $3 - description         (e.g. "Updating Docker Compose")
#
# Output example:
#   [STEP 1/5] Updating Docker Compose
log_step() {
    local step_current="$1"
    local step_total="$2"
    local description="$3"

    local mood="FOCUS"

    if ! _should_log_level "$mood"; then
        return 0
    fi

    (( LOG_ENTRY_COUNT++ )) || true

    local color_code="${COLOR_PALETTE[FOCUS]:-}"
    local reset_code="${COLOR_PALETTE[RESET]:-}"
    local bold_code=""
    [[ -n "${COLOR_PALETTE[BOLD]:-}" ]] && bold_code="${COLOR_PALETTE[BOLD]}"

    local step_label="STEP ${step_current}/${step_total}"

    local timestamp_prefix=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        timestamp_prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    # Console output
    echo -e "${timestamp_prefix}${bold_code}${color_code}[${step_label}]${reset_code} - ${color_code}${description}${reset_code}"

    # File output
    local file_timestamp=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        file_timestamp="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    echo "${file_timestamp}[${step_label}] - ${description}" >> "$LOG_FILE"

    return 0
}

#===============================================================================
# NAMED TIMERS FOR PROFILING
#===============================================================================

# Start a named timer.
# Arguments:
#   $1 - timer name (e.g. "image_pull")
log_timer_start() {
    local timer_name="$1"

    if [[ -z "$timer_name" ]]; then
        log_warning "log_timer_start called without a timer name"
        return 1
    fi

    LOG_TIMERS["$timer_name"]="$(date '+%s')"

    log_debug "Timer '${timer_name}' started"
    return 0
}

# Stop a named timer and log the elapsed duration.
# Arguments:
#   $1 - timer name (must match a previous log_timer_start call)
#
# Output example:
#   [TIMING] image_pull completed in 2m 34s
log_timer_stop() {
    local timer_name="$1"

    if [[ -z "$timer_name" ]]; then
        log_warning "log_timer_stop called without a timer name"
        return 1
    fi

    local start_time="${LOG_TIMERS[$timer_name]:-}"
    if [[ -z "$start_time" ]]; then
        log_warning "Timer '${timer_name}' was never started"
        return 1
    fi

    local end_time
    end_time="$(date '+%s')"
    local elapsed=$(( end_time - start_time ))
    local duration_str
    duration_str="$(_format_duration "$elapsed")"

    # Remove the timer entry
    unset 'LOG_TIMERS[$timer_name]'

    # Use TIMING as the mood -- falls through to INFO priority in _should_log_level
    local mood="TIMING"

    if ! _should_log_level "$mood"; then
        return 0
    fi

    (( LOG_ENTRY_COUNT++ )) || true

    local color_code="${COLOR_PALETTE[FOCUS]:-}"
    local reset_code="${COLOR_PALETTE[RESET]:-}"

    local timestamp_prefix=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        timestamp_prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    # Console
    echo -e "${timestamp_prefix}${color_code}[TIMING]${reset_code} - ${color_code}${timer_name} completed in ${duration_str}${reset_code}"

    # File
    local file_timestamp=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        file_timestamp="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    echo "${file_timestamp}[TIMING] - ${timer_name} completed in ${duration_str}" >> "$LOG_FILE"

    return 0
}

#===============================================================================
# TABLE RENDERING
#===============================================================================

# Render tabular data with aligned columns.
# Arguments are pipe-delimited strings.  The first argument is treated as the
# header row.
#
# Usage:
#   log_table "Stack|Status|Containers" "core|Running|3" "media|Stopped|0"
#
# Output:
#   +-------+---------+------------+
#   | Stack | Status  | Containers |
#   +-------+---------+------------+
#   | core  | Running | 3          |
#   | media | Stopped | 0          |
#   +-------+---------+------------+
log_table() {
    if [[ $# -lt 1 ]]; then
        log_warning "log_table called with no arguments"
        return 1
    fi

    # Parse all rows into a 2D structure and compute column widths
    local -a all_rows=("$@")
    local -a col_widths=()

    # First pass: determine max column widths
    local row_str col_idx
    for row_str in "${all_rows[@]}"; do
        IFS='|' read -ra cells <<< "$row_str"
        for col_idx in "${!cells[@]}"; do
            local cell_len=${#cells[$col_idx]}
            if [[ -z "${col_widths[$col_idx]:-}" ]] || (( cell_len > col_widths[$col_idx] )); then
                col_widths[$col_idx]=$cell_len
            fi
        done
    done

    # Build a horizontal border line
    local border="+"
    for width in "${col_widths[@]}"; do
        border+="$(printf '%*s' $(( width + 2 )) '' | tr ' ' '-')+"
    done

    # Render the table
    local color_code="${COLOR_PALETTE[FOCUS]:-}"
    local header_color="${COLOR_PALETTE[INFO_HEADER]:-${COLOR_PALETTE[FOCUS]:-}}"
    local reset_code="${COLOR_PALETTE[RESET]:-}"

    local output_lines=()
    output_lines+=("$border")

    local row_index=0
    for row_str in "${all_rows[@]}"; do
        IFS='|' read -ra cells <<< "$row_str"
        local line="|"
        for col_idx in "${!col_widths[@]}"; do
            local cell="${cells[$col_idx]:-}"
            local width="${col_widths[$col_idx]}"
            line+="$(printf ' %-*s |' "$width" "$cell")"
        done
        output_lines+=("$line")

        # Add separator after header row
        if (( row_index == 0 )); then
            output_lines+=("$border")
        fi
        (( row_index++ )) || true
    done
    output_lines+=("$border")

    # Print to console with color
    local line_idx=0
    for line in "${output_lines[@]}"; do
        if (( line_idx <= 2 )); then
            # Header and its borders get header color
            echo -e "${header_color}${line}${reset_code}"
        else
            echo -e "${color_code}${line}${reset_code}"
        fi
        (( line_idx++ )) || true
    done

    # Print to file without color
    for line in "${output_lines[@]}"; do
        echo "$line" >> "$LOG_FILE"
    done

    return 0
}

#===============================================================================
# BANNER DISPLAY
#===============================================================================

# Display a prominent banner for major sections.
# Arguments:
#   $1 - title text   (e.g. "DOCKER SERVICES MANAGER")
#   $2 - subtitle     (optional, e.g. "v2.0.0")
#
# Output:
#   +============================================+
#   |        DOCKER SERVICES MANAGER             |
#   |                 v2.0.0                     |
#   +============================================+
log_banner() {
    local title="${1:-}"
    local subtitle="${2:-}"

    if [[ -z "$title" ]]; then
        log_warning "log_banner called without a title"
        return 1
    fi

    # Determine banner width -- at least 50, or title length + padding
    local min_width=50
    local title_len=${#title}
    local subtitle_len=${#subtitle}
    local content_width=$title_len
    (( subtitle_len > content_width )) && content_width=$subtitle_len
    local banner_width=$(( content_width + 10 ))
    (( banner_width < min_width )) && banner_width=$min_width

    # The inner width (between the two '|' characters) is banner_width - 2
    local inner_width=$(( banner_width - 2 ))

    # Build border lines
    local border_line
    border_line="+$(printf '%*s' "$inner_width" '' | tr ' ' '=')+"

    # Center the title and subtitle
    local title_pad_left=$(( (inner_width - title_len) / 2 ))
    local title_pad_right=$(( inner_width - title_len - title_pad_left ))
    local title_line
    title_line="$(printf '|%*s%s%*s|' "$title_pad_left" '' "$title" "$title_pad_right" '')"

    local subtitle_line=""
    if [[ -n "$subtitle" ]]; then
        local sub_pad_left=$(( (inner_width - subtitle_len) / 2 ))
        local sub_pad_right=$(( inner_width - subtitle_len - sub_pad_left ))
        subtitle_line="$(printf '|%*s%s%*s|' "$sub_pad_left" '' "$subtitle" "$sub_pad_right" '')"
    fi

    local color_code="${COLOR_PALETTE[FOCUS]:-}"
    local bold_code="${COLOR_PALETTE[BOLD]:-}"
    local reset_code="${COLOR_PALETTE[RESET]:-}"

    # Console output
    echo ""
    echo -e "${bold_code}${color_code}${border_line}${reset_code}"
    echo -e "${bold_code}${color_code}${title_line}${reset_code}"
    [[ -n "$subtitle_line" ]] && echo -e "${bold_code}${color_code}${subtitle_line}${reset_code}"
    echo -e "${bold_code}${color_code}${border_line}${reset_code}"
    echo ""

    # File output
    {
        echo ""
        echo "$border_line"
        echo "$title_line"
        [[ -n "$subtitle_line" ]] && echo "$subtitle_line"
        echo "$border_line"
        echo ""
    } >> "$LOG_FILE"

    return 0
}

#===============================================================================
# KEY-VALUE LOGGING
#===============================================================================

# Log key-value pairs with aligned formatting.
# Arguments:
#   $1 - key   (e.g. "User")
#   $2 - value (e.g. "$(whoami)")
#
# Output:
#   [INFO] - User .................. howson
#
# Uses dot-leaders to align values at a consistent column.
log_keyvalue() {
    local key="$1"
    local value="$2"

    if [[ -z "$key" ]]; then
        log_warning "log_keyvalue called without a key"
        return 1
    fi

    local mood="INFO"

    if ! _should_log_level "$mood"; then
        return 0
    fi

    (( LOG_ENTRY_COUNT++ )) || true

    # Fixed alignment width for the key+dots portion
    local align_width=30
    local key_len=${#key}
    local dots_count=$(( align_width - key_len ))
    (( dots_count < 3 )) && dots_count=3

    local dots
    dots="$(printf '%*s' "$dots_count" '' | tr ' ' '.')"

    local color_code="${COLOR_PALETTE[INFO]:-}"
    local dim_code="${COLOR_PALETTE[DIM]:-}"
    local reset_code="${COLOR_PALETTE[RESET]:-}"

    local timestamp_prefix=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        timestamp_prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    # Console
    echo -e "${timestamp_prefix}${color_code}[INFO]${reset_code} - ${color_code}${key}${reset_code} ${dim_code}${dots}${reset_code} ${color_code}${value}${reset_code}"

    # File
    local file_timestamp=""
    if [[ "$ENABLE_LOG_DATE" == "true" ]]; then
        file_timestamp="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi

    echo "${file_timestamp}[INFO] - ${key} ${dots} ${value}" >> "$LOG_FILE"

    return 0
}

#===============================================================================
# UTILITY AND HELPER FUNCTIONS
#===============================================================================

# Log system information as a set of key-value pairs.
log_system_info() {
    log_info_header "System Information"
    log_keyvalue "Hostname"  "$(hostname)"
    log_keyvalue "User"      "$(whoami)"
    log_keyvalue "PWD"       "$(pwd)"
    log_keyvalue "Shell"     "$SHELL"
    log_keyvalue "Date"      "$(date)"
}

# Log script start with metadata.
log_script_start() {
    local script_name="${1:-$(basename "$0")}"
    local script_args="${2:-$*}"

    log_info_header "Script Execution Started"
    log_keyvalue "Script"     "$script_name"
    [[ -n "$script_args" ]] && log_keyvalue "Arguments" "$script_args"
    log_keyvalue "PID"        "$$"
    log_keyvalue "Started at" "$(date '+%Y-%m-%d %H:%M:%S')"
}

# Log script end with execution time (uses _format_duration).
log_script_end() {
    local exit_code="${1:-0}"
    local script_name="${2:-$(basename "$0")}"

    if [[ -n "$LOGGER_START_TIME" ]]; then
        local end_time duration duration_str
        end_time="$(date '+%s')"
        duration=$(( end_time - LOGGER_START_TIME ))
        duration_str="$(_format_duration "$duration")"
        log_keyvalue "Execution time" "$duration_str"
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        log_success "Script '$script_name' completed successfully"
    else
        log_error "Script '$script_name' exited with code: $exit_code"
    fi

    log_info_header "Script Execution Completed"
}

# Log command execution with timing (uses _format_duration).
log_command() {
    local cmd="$1"
    local description="${2:-Executing command}"

    log_info "$description: $cmd"

    local start_time end_time duration duration_str exit_code
    start_time="$(date '+%s')"

    eval "$cmd"
    exit_code=$?

    end_time="$(date '+%s')"
    duration=$(( end_time - start_time ))
    duration_str="$(_format_duration "$duration")"

    if [[ $exit_code -eq 0 ]]; then
        log_success "Command completed successfully (${duration_str})"
    else
        log_error "Command failed with exit code $exit_code (${duration_str})"
    fi

    return $exit_code
}

# Create a colored log separator.
# Arguments:
#   $1 - character (default: -)
#   $2 - length    (default: 80)
#   $3 - message   (optional, centered in the line)
#   $4 - color     (default: FOCUS)
log_separator() {
    local char="${1:--}"
    local length="${2:-80}"
    local message="$3"
    local color="${4:-FOCUS}"

    local color_code="${COLOR_PALETTE[$color]:-${COLOR_PALETTE[FOCUS]}}"
    local reset_code="${COLOR_PALETTE[RESET]}"

    local separator
    separator="$(printf "%*s" "$length" "" | tr ' ' "$char")"

    if [[ -n "$message" ]]; then
        local msg_length=${#message}
        local padding=$(( (length - msg_length - 2) / 2 ))
        separator="$(printf "%*s" "$padding" "" | tr ' ' "$char") $message $(printf "%*s" "$padding" "" | tr ' ' "$char")"
    fi

    # Console output with color
    echo -e "${color_code}${separator}${reset_code}"

    # File output without color
    echo "$separator" >> "$LOG_FILE"
}

# Validate logger configuration.
validate_logger_config() {
    local errors=()

    # Check required variables
    [[ -z "${LOG_FILE:-}" ]]            && errors+=("LOG_FILE not set")
    [[ -z "${APPLICATION_TITLE:-}" ]]   && errors+=("APPLICATION_TITLE not set")
    [[ -z "${LOG_LEVEL:-}" ]]           && errors+=("LOG_LEVEL not set")

    # Check log file permissions
    if [[ -n "${LOG_FILE:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        [[ ! -w "$log_dir" ]] && errors+=("Log directory not writable: $log_dir")
    fi

    # Report errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "Logger configuration errors:" >&2
        printf "   - %s\n" "${errors[@]}" >&2
        return 1
    fi

    log_success "Logger configuration validated successfully"
    return 0
}

#===============================================================================
# TRAP HANDLERS AND CLEANUP
#===============================================================================

# Set up trap for clean logger shutdown.
_setup_logger_traps() {
    trap 'close_logger' EXIT
    trap 'log_warning "Script interrupted by user"; close_logger; exit 130' INT TERM
}

# Call trap setup when logger is sourced
_setup_logger_traps

#===============================================================================
# EXPORT FUNCTIONS FOR EXTERNAL USE
#===============================================================================

# Core lifecycle and configuration
export -f initiate_logger close_logger validate_logger_config

# Internal utilities (exported so child shells / sourced scripts can use them)
export -f _format_duration _check_dependencies _log_event _should_log_level
export -f _build_console_output _build_file_output _handle_special_actions

# Standard log levels
export -f log_info log_success log_warning log_error log_debug

# Extended log levels
export -f log_info_header log_important log_note log_tip log_confirmation
export -f log_alert log_caution log_focus log_highlight log_neutral
export -f log_prompt log_status log_verbose log_question log_critical

# Bold variants
export -f log_bold_info log_bold_success log_bold_warning log_bold_error log_bold_debug
export -f log_bold_important log_bold_note log_bold_tip log_bold_confirmation
export -f log_bold_alert log_bold_caution log_bold_focus log_bold_highlight
export -f log_bold_neutral log_bold_prompt log_bold_status log_bold_verbose
export -f log_bold_question log_bold_critical

# No-date variants
export -f log_nodate_info log_nodate_success log_nodate_warning log_nodate_error log_nodate_debug
export -f log_nodate_info_header log_nodate_important log_nodate_note log_nodate_tip
export -f log_nodate_confirmation log_nodate_alert log_nodate_caution log_nodate_focus
export -f log_nodate_highlight log_nodate_neutral log_nodate_prompt log_nodate_status
export -f log_nodate_verbose log_nodate_question log_nodate_critical

# Bold no-date variants
export -f log_bold_nodate_info log_bold_nodate_success log_bold_nodate_warning
export -f log_bold_nodate_error log_bold_nodate_debug log_bold_nodate_info_header
export -f log_bold_nodate_important log_bold_nodate_note log_bold_nodate_tip
export -f log_bold_nodate_confirmation log_bold_nodate_alert log_bold_nodate_caution
export -f log_bold_nodate_focus log_bold_nodate_highlight log_bold_nodate_neutral
export -f log_bold_nodate_prompt log_bold_nodate_status log_bold_nodate_verbose
export -f log_bold_nodate_question log_bold_nodate_critical

# Utility and helper functions
export -f log_system_info log_script_start log_script_end log_command log_separator

# New v3.0 functions
export -f log_progress log_step log_timer_start log_timer_stop
export -f log_table log_banner log_keyvalue

# Mark logger as loaded
export LOGGER_LOADED=true
