#!/bin/bash
# This script contains helper functions that provide various utilities to the application.

# Sets the terminal title to the provided argument.
# Inputs: 
#   $1 - The title string to be set for the terminal.
# Usage: 
#   set_terminal_title "My Application"
set_terminal_title() {
    local title=$1

    # Setting the terminal title
    echo -ne "\\033]0;${title}\\007"

    # Consider adding error handling if necessary
}

# Confirmation Prompt with Color and Timeout
confirm_deletion() {
    local prompt=$1
    echo -ne "\033[1;31m$prompt \033[0m[y/N]: " # Bright red color for the prompt
    read -r -n 1 -t 8 response  # Wait for a single character response for 8 seconds
    echo
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        return 0  # User confirmed
    fi
    return 1  # No response or negative response
}

# Countdown Timer
countdown_timer_ntfy() {
    local seconds="${1:-$COUNTDOWN_DURATION}"
    log_bold_nodate_status "Waiting for ${seconds} seconds..."
    while [ $seconds -gt 0 ]; do
        sleep 1
        : $((seconds--))
    done
    echo
}

# Wait for Key Press
wait_for_keypress() {
    read -r -n1 -p "Press any key to continue..."
    echo
}

# Input Prompt
input_prompt() {
    local prompt=$1
    read -r -p "$prompt: " input
    echo "$input"
}

# Countdown Timer
countdown_timer() {
    local seconds="${1:-$COUNTDOWN_DURATION}"
    echo "Waiting for ${seconds} seconds..."
    while [ $seconds -gt 0 ]; do
        echo -ne "$seconds\033[0K\r"
        sleep 1
        : $((seconds--))
    done
    echo
}
# Create a Backup of a File or Directory
# Backup Function
backup() {
    local source=$1
    local backup_path="${2:-$DEFAULT_BACKUP_PATH}"
    cp -r "$source" "$backup_path"
    echo "Backup of '$source' created at '$backup_path'"
}

# Check for Command Existence
command_exists() {
    local cmd=$1
    type "$cmd" &> /dev/null
}

# Run Command with Timeout
run_with_timeout() {
    local timeout_duration="${1:-$DEFAULT_COMMAND_TIMEOUT}"
    shift
    timeout "$timeout_duration" "$@"
}

# Generate Random String
generate_random_string() {
    local length="${1:-$RANDOM_STRING_LENGTH}"
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
    echo
}

# Get Current Network IP
get_network_ip() {
    ip -4 addr show "$DEFAULT_NETWORK_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
}

# Display Disk Usage
show_disk_usage() {
    df -h | grep -ve 'tmpfs\|udev'
}

# Create a Directory if Not Exists
ensure_directory() {
    local dir=${1:-.}
    [ -d "$dir" ] || mkdir -p "$dir"
}

# Download a File
download_file() {
    local url=$1
    local dest="${2:-./}"
    wget -P "$dest" "$url"
}

# Extract File
extract() {
    local file=$1
    case "$file" in
        *.tar.bz2) tar xjf "$file" ;;
        *.tar.gz)  tar xzf "$file" ;;
        *.bz2)     bunzip2 "$file" ;;
        *.rar)     unrar e "$file" ;;
        *.gz)      gunzip "$file" ;;
        *.tar)     tar xf "$file" ;;
        *.tbz2)    tar xjf "$file" ;;
        *.tgz)     tar xzf "$file" ;;
        *.zip)     unzip "$file" ;;
        *.Z)       uncompress "$file" ;;
        *.7z)      7z x "$file" ;;
        *)         echo "'$file' cannot be extracted via extract()" ;;
    esac
}

# Monitor a File for Changes
monitor_file() {
    local file=$1
    echo "Monitoring $file for changes..."
    tail -f "$file"
}

# Replace Text in File
replace_in_file() {
    local file=$1
    local search=$2
    local replace=$3
    sed -i "s/$search/$replace/g" "$file"
}

# List Open Ports
list_open_ports() {
    netstat -tuln
}
# Advanced Network Information
get_advanced_network_info() {
    ifconfig $DEFAULT_NETWORK_INTERFACE
}

# CPU Usage Information
show_cpu_usage() {
    mpstat
}

# Memory Usage Information
show_memory_usage() {
    free -m
}

# List Running Processes
list_running_processes() {
    ps aux
}

# Kill a Process by Name
kill_process() {
    local process_name=$1
    pkill "$process_name"
}

# Encrypt a File
encrypt_file() {
    local file=$1
    local password=${2:-$DEFAULT_ENCRYPTION_PASSWORD}
    openssl enc -aes-256-cbc -salt -in "$file" -out "${file}.enc" -k "$password"
}

# Decrypt a File
decrypt_file() {
    local file=$1
    local password=${2:-$DEFAULT_ENCRYPTION_PASSWORD}
    openssl enc -d -aes-256-cbc -in "$file" -out "${file%.enc}" -k "$password"
}
# Create a ZIP Archive
create_zip() {
    local source_dir=$1
    local zipfile="${2:-$ZIP_DIRECTORY/$(basename "$source_dir").zip}"

    mkdir -p "$ZIP_DIRECTORY"  # Ensure the ZIP directory exists
    zip -r "$zipfile" "$source_dir"   # Create the ZIP archive
    echo "Created ZIP: $zipfile"
}

# Extract a ZIP Archive
extract_zip() {
    local zipfile=$1
    local target_dir="$EXTRACTION_DIRECTORY"

    mkdir -p "$target_dir"  # Ensure the extraction directory exists
    unzip "$zipfile" -d "$target_dir"   # Extract the ZIP archive
    echo "Extracted to: $target_dir"
}
# Check Internet Connectivity
check_internet() {
    ping -c 4 "$INTERNET_CHECK_HOST"
}
# Get Current User
get_current_user() {
    whoami
}

# Change File Permissions
change_file_permissions() {
    local file=$1
    local permissions=${2:-$DEFAULT_FILE_PERMISSIONS}
    chmod "$permissions" "$file"
}

# Create a Symbolic Link
create_symlink() {
    local target=$1
    local link_name=$2
    ln -s "$target" "$link_name"
}

# Display System Information
show_system_info() {
    uname -a
}

# List Files in a Directory
list_files() {
    local dir=${1:-.}
    ls -l "$dir"
}

# Calculate Directory Size
calculate_directory_size() {
    local dir=${1:-.}
    du -sh "$dir"
}

# Search for a File
search_file() {
    local filename=$1
    find / -name "$filename" 2>/dev/null
}

# Display Current Path
show_current_path() {
    pwd
}

# Restart Network Service
restart_network() {
    systemctl restart networking
}
# Placeholder for additional utility functions
# ...
