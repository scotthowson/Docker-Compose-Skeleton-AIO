#!/bin/bash
# =============================================================================
# Secrets Management Library v1.0
# Lightweight encrypted secrets storage using AES-256-CBC via OpenSSL
# Secrets are stored per-key in .secrets/ with optional encryption at rest
#
# Dependencies: openssl
# Requires: Bash 4+
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SECRETS_DIR="${BASE_DIR}/.secrets"
SECRETS_MASTER_KEY_FILE="${SECRETS_DIR}/.master-key"
SECRETS_ENCRYPTION="${SECRETS_ENCRYPTION:-true}"

# =============================================================================
# INITIALIZATION
# =============================================================================

secrets_init() {
    if [[ ! -d "$SECRETS_DIR" ]]; then
        mkdir -p "$SECRETS_DIR"
        chmod 700 "$SECRETS_DIR"
    fi

    # Ensure gitignore
    if [[ ! -f "$SECRETS_DIR/.gitignore" ]]; then
        echo '*' > "$SECRETS_DIR/.gitignore"
    fi

    # Generate master key if needed and encryption is enabled
    if [[ "$SECRETS_ENCRYPTION" == "true" ]]; then
        secrets_generate_master_key
    fi
}

# Generate a random master key if it doesn't exist
secrets_generate_master_key() {
    if [[ -f "$SECRETS_MASTER_KEY_FILE" ]]; then
        return 0
    fi

    openssl rand -hex 32 > "$SECRETS_MASTER_KEY_FILE" 2>/dev/null
    chmod 600 "$SECRETS_MASTER_KEY_FILE"
}

# =============================================================================
# ENCRYPTION / DECRYPTION
# =============================================================================

_secrets_encrypt() {
    local plaintext="$1"
    if [[ "$SECRETS_ENCRYPTION" != "true" || ! -f "$SECRETS_MASTER_KEY_FILE" ]]; then
        printf '%s' "$plaintext"
        return 0
    fi

    printf '%s' "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -salt -pass "file:$SECRETS_MASTER_KEY_FILE" -base64 -A 2>/dev/null
}

_secrets_decrypt() {
    local ciphertext="$1"
    if [[ "$SECRETS_ENCRYPTION" != "true" || ! -f "$SECRETS_MASTER_KEY_FILE" ]]; then
        printf '%s' "$ciphertext"
        return 0
    fi

    printf '%s' "$ciphertext" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -d -salt -pass "file:$SECRETS_MASTER_KEY_FILE" -base64 -A 2>/dev/null
}

# =============================================================================
# CRUD OPERATIONS
# =============================================================================

# Validate a secret key name
_secrets_validate_key() {
    local key="$1"
    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid key name: only alphanumeric, dashes, and underscores allowed" >&2
        return 1
    fi
    # Prevent path traversal
    if [[ "$key" == *".."* || "$key" == *"/"* ]]; then
        echo "Invalid key name: path traversal not allowed" >&2
        return 1
    fi
    return 0
}

# Set a secret value
# Usage: secrets_set key value
secrets_set() {
    local key="$1"
    local value="$2"

    _secrets_validate_key "$key" || return 1
    secrets_init

    local encrypted
    encrypted=$(_secrets_encrypt "$value")

    if [[ "$SECRETS_ENCRYPTION" == "true" ]]; then
        printf '%s' "$encrypted" > "$SECRETS_DIR/${key}.enc"
        chmod 600 "$SECRETS_DIR/${key}.enc"
    else
        printf '%s' "$value" > "$SECRETS_DIR/${key}"
        chmod 600 "$SECRETS_DIR/${key}"
    fi

    return 0
}

# Get a secret value
# Usage: secrets_get key
secrets_get() {
    local key="$1"
    _secrets_validate_key "$key" || return 1

    # Try encrypted first, then plaintext
    if [[ -f "$SECRETS_DIR/${key}.enc" ]]; then
        local ciphertext
        ciphertext=$(cat "$SECRETS_DIR/${key}.enc")
        _secrets_decrypt "$ciphertext"
    elif [[ -f "$SECRETS_DIR/${key}" ]]; then
        cat "$SECRETS_DIR/${key}"
    else
        echo "Secret not found: $key" >&2
        return 1
    fi
}

# List all secret keys as JSON array (never returns values)
secrets_list() {
    secrets_init
    local result="["
    local first=true

    for f in "$SECRETS_DIR"/*; do
        [[ ! -f "$f" ]] && continue
        local name
        name=$(basename "$f")
        # Skip hidden files and gitignore
        [[ "$name" == .* ]] && continue
        # Strip .enc extension
        name="${name%.enc}"

        [[ "$first" == "true" ]] && first=false || result+=","
        result+="\"$name\""
    done

    result+="]"
    echo "$result"
}

# Delete a secret securely
secrets_delete() {
    local key="$1"
    _secrets_validate_key "$key" || return 1

    local deleted=false
    for ext in "" ".enc"; do
        local file="$SECRETS_DIR/${key}${ext}"
        if [[ -f "$file" ]]; then
            # Overwrite with random data before deletion
            local size
            size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 64)
            dd if=/dev/urandom bs=1 count="$size" of="$file" 2>/dev/null
            rm -f "$file"
            deleted=true
        fi
    done

    [[ "$deleted" == "true" ]] && return 0
    echo "Secret not found: $key" >&2
    return 1
}

# Check if a secret exists
secrets_exists() {
    local key="$1"
    _secrets_validate_key "$key" || return 1
    [[ -f "$SECRETS_DIR/${key}" || -f "$SECRETS_DIR/${key}.enc" ]]
}

# =============================================================================
# IMPORT / EXPORT
# =============================================================================

# Export all secrets as an encrypted tar bundle
secrets_export_bundle() {
    local output_path="${1:-${BASE_DIR}/secrets-export-$(date '+%Y%m%d').tar.enc}"
    secrets_init

    local tmp_tar="/tmp/dcs-secrets-export-$$.tar"
    tar -cf "$tmp_tar" -C "$SECRETS_DIR" . 2>/dev/null

    if [[ -f "$SECRETS_MASTER_KEY_FILE" ]]; then
        openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
            -pass "file:$SECRETS_MASTER_KEY_FILE" \
            -in "$tmp_tar" -out "$output_path" 2>/dev/null
    else
        cp "$tmp_tar" "$output_path"
    fi

    rm -f "$tmp_tar"
    echo "$output_path"
}

# Import secrets from an encrypted tar bundle
secrets_import_bundle() {
    local input_path="$1"
    [[ ! -f "$input_path" ]] && { echo "File not found: $input_path" >&2; return 1; }

    secrets_init
    local tmp_tar="/tmp/dcs-secrets-import-$$.tar"

    if [[ -f "$SECRETS_MASTER_KEY_FILE" ]]; then
        openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt \
            -pass "file:$SECRETS_MASTER_KEY_FILE" \
            -in "$input_path" -out "$tmp_tar" 2>/dev/null
    else
        cp "$input_path" "$tmp_tar"
    fi

    tar -xf "$tmp_tar" -C "$SECRETS_DIR" 2>/dev/null
    rm -f "$tmp_tar"
    return 0
}
