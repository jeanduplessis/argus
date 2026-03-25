#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="Argus"

# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  build       Build the app (default if no command given)
  run         Build, then launch the app
  install     Build, install to /Applications, and launch
  clean       Remove build artifacts
  generate    Regenerate Argus.xcodeproj from project.yml

Options:
  --debug     Use Debug configuration (default)
  --release   Use Release configuration
  --no-open   Don't launch the app after run/install

Examples:
  ./scripts/build.sh build
  ./scripts/build.sh run
  ./scripts/build.sh run --release
  ./scripts/build.sh install
  ./scripts/build.sh clean
EOF
    exit 0
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
COMMAND=""
CONFIGURATION="Debug"
OPEN_APP=1

while [[ $# -gt 0 ]]; do
    case $1 in
        build|run|install|clean|generate) COMMAND="$1"; shift ;;
        --debug)    CONFIGURATION="Debug";   shift ;;
        --release)  CONFIGURATION="Release"; shift ;;
        --no-open)  OPEN_APP=0;              shift ;;
        -h|--help)  usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Default command
COMMAND="${COMMAND:-build}"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m==>\033[0m %s\n" "$*" >&2; }
time_start() { _t_start=$(date +%s); }
time_end()   { local elapsed=$(( $(date +%s) - _t_start )); log "Completed in ${elapsed}s"; }

ensure_xcode_project() {
    if [[ ! -d "${PROJECT_DIR}/Argus.xcodeproj" ]]; then
        log "Argus.xcodeproj not found — generating..."
        do_generate
    fi
}

find_app() {
    find "${BUILD_DIR}" -name "${APP_NAME}.app" -type d 2>/dev/null | head -1
}

quit_running() {
    if pgrep -x "${APP_NAME}" > /dev/null 2>&1; then
        log "Quitting running ${APP_NAME}..."
        osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
        for _ in $(seq 1 5); do
            pgrep -x "${APP_NAME}" > /dev/null 2>&1 || return 0
            sleep 1
        done
        pkill -9 "${APP_NAME}" 2>/dev/null || true
        sleep 0.5
    fi
}

launch_app() {
    local app_path="$1"
    if [[ $OPEN_APP -eq 1 ]]; then
        log "Launching ${APP_NAME}..."
        (
            unset ARGUS_SOCKET_PATH ARGUS_WORKSPACE_ID ARGUS_SURFACE_ID
            open "$app_path"
        )
    fi
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
do_generate() {
    log "Regenerating Xcode project from project.yml..."
    if ! command -v xcodegen &> /dev/null; then
        err "xcodegen not found. Install with: brew install xcodegen"
        exit 1
    fi
    (cd "$PROJECT_DIR" && xcodegen generate)
    ok "Xcode project generated"
}

do_build() {
    ensure_xcode_project
    log "Building ${APP_NAME} (${CONFIGURATION})..."
    time_start

    xcodebuild \
        -project "${PROJECT_DIR}/Argus.xcodeproj" \
        -scheme Argus \
        -configuration "${CONFIGURATION}" \
        -derivedDataPath "${BUILD_DIR}" \
        build 2>&1 | tail -5

    local app_path
    app_path="$(find_app)"
    if [[ -z "$app_path" ]]; then
        err "Build product not found"
        exit 1
    fi

    # Ad-hoc codesign
    codesign --force --deep --sign - "${app_path}" 2>/dev/null || true

    time_end
    ok "Build succeeded: ${app_path}"
}

do_run() {
    do_build
    quit_running
    launch_app "$(find_app)"
}

do_install() {
    do_build
    quit_running

    local app_path
    app_path="$(find_app)"
    local dest="/Applications/${APP_NAME}.app"

    log "Installing to ${dest}..."
    rm -rf "$dest"
    cp -R "$app_path" "$dest"
    ok "Installed to ${dest}"

    launch_app "$dest"
}

do_clean() {
    log "Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    ok "Clean complete"
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
case "$COMMAND" in
    build)    do_build    ;;
    run)      do_run      ;;
    install)  do_install  ;;
    clean)    do_clean    ;;
    generate) do_generate ;;
    *)        usage       ;;
esac
