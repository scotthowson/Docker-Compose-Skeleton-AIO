#!/bin/bash
# =============================================================================
# Secrets Library v2.0
# One encrypted key-value store shared by the REST API, start.sh and the CLI
# utilities, so a secret behaves the same however a stack is started.
#
# Storage:   .secrets/<NAME>.enc   openssl enc -aes-256-cbc -salt -pbkdf2 (binary)
#            .secrets/.master-key  256-bit random key, mode 600
# Names:     ^[A-Za-z_][A-Za-z0-9_]*$ (UPPER_SNAKE recommended), 64 chars max
# Reference: ${SECRETS_<NAME>} in docker-compose.yml, the stack .env or the
#            root .env. ${SECRETS.<NAME>} is accepted and normalized on write.
# Injection: compose_with_secrets exports SECRETS_<NAME> only to the compose
#            child process; values never reach disk in clear text.
#
# Dependencies: openssl. Requires Bash 4+.
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SECRETS_DIR="${BASE_DIR}/.secrets"
SECRETS_MASTER_KEY_FILE="${SECRETS_DIR}/.master-key"
SECRETS_NAME_RE='^[A-Za-z_][A-Za-z0-9_]{0,63}$'

# =============================================================================
# INITIALIZATION
# =============================================================================

secrets_init() {
    if [[ ! -d "$SECRETS_DIR" ]]; then
        (umask 077; mkdir -p "$SECRETS_DIR") 2>/dev/null || mkdir -p "$SECRETS_DIR" || return 1
    fi
    chmod 700 "$SECRETS_DIR" 2>/dev/null
    [[ -f "$SECRETS_DIR/.gitignore" ]] || echo '*' > "$SECRETS_DIR/.gitignore"
    secrets_generate_master_key
}

# Generate the master key if it is missing. Written to a private temp file
# first: a failing openssl must never leave an empty key behind.
secrets_generate_master_key() {
    [[ -s "$SECRETS_MASTER_KEY_FILE" ]] && return 0
    local tmp="${SECRETS_MASTER_KEY_FILE}.tmp"
    if ! (umask 077; openssl rand -hex 32 > "$tmp") 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "Failed to generate the secrets master key (is openssl installed?)" >&2
        return 1
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$SECRETS_MASTER_KEY_FILE"
}

# =============================================================================
# NAMES AND REFERENCES
# =============================================================================

secrets_validate_name() {
    local name="$1"
    [[ "$name" =~ $SECRETS_NAME_RE ]] && return 0
    echo "Invalid secret name '$name': use letters, digits and underscores, starting with a letter (e.g. HOMARR_PASSWORD)" >&2
    return 1
}

# Rewrite ${SECRETS.NAME} / $SECRETS.NAME to the compose-compatible form.
_normalize_secrets_syntax() {
    sed 's/\${SECRETS\.\([A-Za-z0-9_]*\)}/${SECRETS_\1}/g; s/\$SECRETS\.\([A-Za-z0-9_]*\)/$SECRETS_\1/g'
}

# Names referenced as SECRETS_<NAME> in the given files (sorted, unique).
# Usage: secrets_references FILE...
secrets_references() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] && grep -oE 'SECRETS_[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null
    done | sed 's/^SECRETS_//' | sort -u
}

# Referenced names that have no stored value. Usage: secrets_missing FILE...
secrets_missing() {
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        secrets_exists "$name" || echo "$name"
    done < <(secrets_references "$@")
}

# =============================================================================
# CRUD
# =============================================================================

secrets_exists() {
    [[ "$1" =~ $SECRETS_NAME_RE && -f "$SECRETS_DIR/$1.enc" ]]
}

# Usage: secrets_set NAME VALUE
secrets_set() {
    local name="$1" value="$2"
    secrets_validate_name "$name" || return 1
    [[ -n "$value" ]] || { echo "Refusing to store an empty value for $name" >&2; return 1; }
    secrets_init || return 1
    local target="$SECRETS_DIR/${name}.enc"
    # -pass file: keeps the key out of /proc/*/cmdline
    if (umask 077; printf '%s' "$value" | openssl enc -aes-256-cbc -salt -pbkdf2 \
            -pass "file:${SECRETS_MASTER_KEY_FILE}" -out "${target}.tmp" 2>/dev/null) && [[ -s "${target}.tmp" ]]; then
        chmod 600 "${target}.tmp" && mv -f "${target}.tmp" "$target"
    else
        rm -f "${target}.tmp"
        echo "Failed to encrypt secret: $name" >&2
        return 1
    fi
}

# Usage: secrets_get NAME  (plaintext on stdout; 1 if missing or undecryptable)
secrets_get() {
    local name="$1"
    [[ "$name" =~ $SECRETS_NAME_RE ]] || return 1
    [[ -f "$SECRETS_DIR/$name.enc" && -f "$SECRETS_MASTER_KEY_FILE" ]] || return 1
    openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:${SECRETS_MASTER_KEY_FILE}" -in "$SECRETS_DIR/$name.enc" 2>/dev/null
}

# Names only, one per line, never values.
secrets_list() {
    local f
    for f in "$SECRETS_DIR"/*.enc; do
        [[ -f "$f" ]] || continue
        f=$(basename "$f" .enc)
        [[ "$f" =~ $SECRETS_NAME_RE ]] && echo "$f"
    done | sort
}

# JSON array of {key, modified, size} — the API's list shape.
secrets_list_json() {
    local f name mod size first=true out="["
    for f in "$SECRETS_DIR"/*.enc; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .enc)
        mod=$(date -u -d "@$(stat -c '%Y' "$f" 2>/dev/null || echo 0)" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
        size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        [[ "$first" == "true" ]] && first=false || out+=","
        out+="{\"key\":\"$name\",\"modified\":\"$mod\",\"size\":$size}"
    done
    printf '%s]' "$out"
}

# Overwrite, then remove.
secrets_delete() {
    local name="$1"
    [[ "$name" =~ $SECRETS_NAME_RE ]] || return 1
    local file="$SECRETS_DIR/$name.enc"
    [[ -f "$file" ]] || { echo "Secret not found: $name" >&2; return 1; }
    if command -v shred >/dev/null 2>&1; then
        shred -u "$file" 2>/dev/null || rm -f "$file"
    else
        dd if=/dev/urandom of="$file" bs="$(stat -c '%s' "$file" 2>/dev/null || echo 64)" count=1 conv=notrunc 2>/dev/null
        rm -f "$file"
    fi
}

# =============================================================================
# COMPOSE INTEGRATION
# =============================================================================

# Print `export SECRETS_<NAME>=<value>` for every reference in FILE... that has
# a stored value. Usage: eval "$(secrets_env_exports FILE...)"
secrets_env_exports() {
    local name val
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if val=$(secrets_get "$name"); then
            printf 'export SECRETS_%s=%q\n' "$name" "$val"
        else
            echo "[DCS] WARN: secret '$name' is referenced but not stored (\${SECRETS_$name})" >&2
        fi
    done < <(secrets_references "$@")
}

# Run docker compose with the referenced secrets in its environment only.
# Usage: compose_with_secrets COMPOSE_FILE ENV_FILE SUBCOMMAND [ARGS...]
# ENV_FILE may be empty. References are collected from the compose file, the
# stack .env and the root .env.
compose_with_secrets() {
    local compose_file="$1"; shift
    local env_file="$1"; shift
    local -a args=(-f "$compose_file")
    [[ -n "$env_file" && -f "$env_file" ]] && args+=(--env-file "$env_file")
    (
        eval "$(secrets_env_exports "$compose_file" "${env_file:-/dev/null}" "$BASE_DIR/.env")"
        ${DOCKER_COMPOSE_CMD:-docker compose} "${args[@]}" "$@"
    )
}

# Backwards-compatible names used across the code base
_decrypt_secret() { secrets_get "$@"; }
_secrets_env_exports() { secrets_env_exports "$@"; }
_compose_with_secrets() { compose_with_secrets "$@"; }

# =============================================================================
# BUNDLES (encrypted export / import of the whole store, without the key)
# =============================================================================

# Usage: secrets_export_bundle OUTPUT.tar
secrets_export_bundle() {
    local out="$1"
    [[ -n "$out" ]] || return 1
    [[ -d "$SECRETS_DIR" ]] || { echo "No secrets to export" >&2; return 1; }
    (cd "$SECRETS_DIR" && umask 077 && tar -cf "$out" --exclude='.master-key' --exclude='.gitignore' -- *.enc 2>/dev/null)
}

# Usage: secrets_import_bundle INPUT.tar  (only *.enc entries, no paths)
secrets_import_bundle() {
    local in="$1"
    [[ -f "$in" ]] || { echo "Bundle not found: $in" >&2; return 1; }
    if tar -tf "$in" 2>/dev/null | grep -vqE '^[A-Za-z_][A-Za-z0-9_]{0,63}\.enc$'; then
        echo "Bundle contains entries that are not secrets; refusing" >&2
        return 1
    fi
    secrets_init || return 1
    (cd "$SECRETS_DIR" && umask 077 && tar -xf "$in" 2>/dev/null) && chmod 600 "$SECRETS_DIR"/*.enc 2>/dev/null
}
