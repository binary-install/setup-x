#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check required tools
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not found"
        return 1
    fi
}

# Download file with curl or wget
download_file() {
    local url="$1"
    local output="$2"

    if command -v curl &> /dev/null; then
        log_info "Downloading with curl: $url"
        curl -fsSL "$url" -o "$output"
    elif command -v wget &> /dev/null; then
        log_info "Downloading with wget: $url"
        wget -q "$url" -O "$output"
    else
        log_error "Neither curl nor wget found"
        return 1
    fi
}

# Calculate SHA256 hash
calculate_sha256() {
    local file="$1"

    if command -v sha256sum &> /dev/null; then
        sha256sum "$file" | cut -d' ' -f1
    elif command -v shasum &> /dev/null; then
        shasum -a 256 "$file" | cut -d' ' -f1
    else
        log_error "Neither sha256sum nor shasum found"
        return 1
    fi
}

# Main execution
main() {
    log_info "Starting binary installation with setup-x"

    # Check inputs
    if [[ -z "${INPUT_SCRIPT_URL:-}" ]]; then
        log_error "script_url input is required"
        exit 1
    fi

    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT

    SCRIPT_FILE="$TEMP_DIR/installer.sh"

    # Download the installer script
    log_info "Downloading installer script from: $INPUT_SCRIPT_URL"
    if ! download_file "$INPUT_SCRIPT_URL" "$SCRIPT_FILE"; then
        log_error "Failed to download installer script"
        exit 1
    fi

    # Verify the script
    VERIFICATION_PASSED=false

    # Try SHA256 verification first if provided
    if [[ -n "${INPUT_SCRIPT_SHA256:-}" ]]; then
        log_info "Verifying script with SHA256 hash"
        ACTUAL_SHA256=$(calculate_sha256 "$SCRIPT_FILE")

        if [[ "$ACTUAL_SHA256" == "$INPUT_SCRIPT_SHA256" ]]; then
            log_info "SHA256 verification passed"
            VERIFICATION_PASSED=true
        else
            log_error "SHA256 verification failed"
            log_error "Expected: $INPUT_SCRIPT_SHA256"
            log_error "Actual:   $ACTUAL_SHA256"
            exit 1
        fi
    fi

    # Try gh attestation verification if flags provided and SHA256 not used
    if [[ -n "${INPUT_GH_ATTESTATIONS_VERIFY_FLAGS:-}" ]] && [[ "$VERIFICATION_PASSED" == "false" ]]; then
        if check_tool "gh"; then
            log_info "Verifying script with gh attestation"
            # shellcheck disable=SC2086
            if gh attestation verify "$SCRIPT_FILE" ${INPUT_GH_ATTESTATIONS_VERIFY_FLAGS}; then
                log_info "gh attestation verification passed"
                VERIFICATION_PASSED=true
            else
                log_error "gh attestation verification failed"
                exit 1
            fi
        else
            log_warning "gh CLI not found, skipping attestation verification"
        fi
    fi

    # Warn if no verification was performed
    if [[ "$VERIFICATION_PASSED" == "false" ]]; then
        log_warning "No verification performed on the installer script"
        log_warning "Consider providing script_sha256 or gh_attestations_verify_flags for security"
    fi

    # Make script executable
    chmod +x "$SCRIPT_FILE"

    # Create a persistent directory for installation in GitHub Actions workspace
    # Use RUNNER_TEMP if available (GitHub Actions), otherwise use /tmp
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
        INSTALL_BASE="$RUNNER_TEMP"
    else
        INSTALL_BASE="/tmp"
    fi

    # Create a unique directory that persists across steps
    INSTALL_DIR="$INSTALL_BASE/binary-install-$(date +%s)-$$"
    mkdir -p "$INSTALL_DIR"
    log_info "Installing to: $INSTALL_DIR"

    # Run the installer script
    log_info "Running installer script"
    INSTALL_ARGS="-b $INSTALL_DIR"

    # Add version as positional argument if specified
    if [[ -n "${INPUT_VERSION:-}" ]]; then
        INSTALL_ARGS="$INSTALL_ARGS $INPUT_VERSION"
    fi

    # Run the installer
    if ! "$SCRIPT_FILE" $INSTALL_ARGS; then
        log_error "Installation failed"
        exit 1
    fi

    log_info "Installation completed successfully"

    # Add to PATH
    log_info "Adding $INSTALL_DIR to PATH"
    echo "$INSTALL_DIR" >> "$GITHUB_PATH"
}

# Run main function
main "$@"
