#!/bin/bash
# This script contains functions for handling errors in a standardized and graceful manner.

# Exits the script gracefully while logging an error message with the exit code.
# It captures the last command's exit status and logs it before exiting.
# Usage: Should be called in a context where an error has occurred, and the script needs to exit.
graceful_exit() {
    local exit_code="${1:-$?}"  # Use provided exit code or capture the last command's exit code

    # Log the error with the exit code
    log_error "Encountered an error. Exiting with code ${exit_code}"

    exit "${exit_code}"  # Exit with the captured exit code
}