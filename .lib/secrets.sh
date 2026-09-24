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
        secrets_generate_master_key || return 1
    fi
}

# Generate a random master key if it doesn't exist. The key is written to a
# private temp file first: a failing openssl must never leave an empty key
# behind that would then silently "encrypt" every secret.
secrets_generate_master_key() {
    if [[ -s "$SECRETS_MASTER_KEY_FILE" ]]; then
        return 0
    fi

    local tmp="${SECRETS_MASTER_KEY_FILE}.tmp"
    if ! (umask 077; openssl rand -hex 32 > "$tmp") 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "Failed to generate the secrets master key (is openssl installed?)" >&2
        return 1
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$SECRETS_MASTER_KEY_FILE"
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
    secrets_init || return 1

    local target
    local payload
    if [[ "$SECRETS_ENCRYPTION" == "true" ]]; then
        target="$SECRETS_DIR/${key}.enc"
        payload=$(_secrets_encrypt "$value")
        if [[ -z "$payload" ]]; then
            echo "Failed to encrypt secret: $key" >&2
            return 1
        fi
    else
        target="$SECRETS_DIR/${key}"
        payload="$value"
    fi

    if ! (umask 077; printf '%s' "$payload" > "${target}.tmp") 2>/dev/null; then
        rm -f "${target}.tmp"
        echo "Failed to write secret: $key" >&2
        return 1
    fi
    chmod 600 "${target}.tmp" && mv -f "${target}.tmp" "$target"
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

# Export all secrets as an encrypted tar bundle.
# The bundle is encrypted with the master key and does NOT contain it — move
# .secrets/.master-key to the destination separately (and securely).
secrets_export_bundle() {
    local output_path="${1:-${BASE_DIR}/secrets-export-$(date '+%Y%m%d').tar.enc}"
    secrets_init || return 1

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1
    chmod 700 "$tmp_dir"
    local tmp_tar="$tmp_dir/bundle.tar"
    if ! tar -cf "$tmp_tar" -C "$SECRETS_DIR" --exclude='.master-key' --exclude='.gitignore' . 2>/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi

    local rc=0
    if [[ -s "$SECRETS_MASTER_KEY_FILE" ]]; then
        (umask 077; openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
            -pass "file:$SECRETS_MASTER_KEY_FILE" \
            -in "$tmp_tar" -out "$output_path") 2>/dev/null || rc=1
    else
        (umask 077; cp "$tmp_tar" "$output_path") || rc=1
    fi

    rm -rf "$tmp_dir"
    [[ $rc -eq 0 ]] && echo "$output_path"
    return $rc
}

# Import secrets from an encrypted tar bundle (created by secrets_export_bundle)
secrets_import_bundle() {
    local input_path="$1"
    [[ ! -f "$input_path" ]] && { echo "File not found: $input_path" >&2; return 1; }

    secrets_init || return 1
    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1
    chmod 700 "$tmp_dir"
    local tmp_tar="$tmp_dir/bundle.tar"

    local rc=0
    if [[ -s "$SECRETS_MASTER_KEY_FILE" ]]; then
        openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt \
            -pass "file:$SECRETS_MASTER_KEY_FILE" \
            -in "$input_path" -out "$tmp_tar" 2>/dev/null || rc=1
    else
        cp "$input_path" "$tmp_tar" || rc=1
    fi

    # Only plain files at the top level of the archive are restored
    if [[ $rc -eq 0 ]]; then
        if tar -tf "$tmp_tar" 2>/dev/null | grep -qE '^\.\./|/\.\./|^/'; then
            echo "Refusing bundle with path traversal entries" >&2
            rc=1
        else
            tar -xf "$tmp_tar" -C "$SECRETS_DIR" --no-absolute-names --exclude='.master-key' 2>/dev/null || rc=1
        fi
    fi
    rm -rf "$tmp_dir"
    return $rc
}
