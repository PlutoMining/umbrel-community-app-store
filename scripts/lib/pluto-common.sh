#!/usr/bin/env bash
# Common utilities and constants for Pluto update scripts

# Determine script root and store root
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE_ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"

# Constants
PLUTO_REPO_OWNER="${PLUTO_REPO_OWNER:-PlutoMining}"
PLUTO_REPO_NAME="${PLUTO_REPO_NAME:-pluto}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/plutomining}"

# Shared state variables (will be set by main script)
CHANGELOG_CACHE=""

# Logging functions
log() {
  echo "[update-pluto-from-registry] $*" >&2
}

err() {
  echo "[update-pluto-from-registry][error] $*" >&2
  exit 1
}

# Cross-platform sed in-place editing
# macOS (BSD sed) requires an extension argument for -i, Linux (GNU sed) doesn't
sed_in_place() {
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS/BSD sed
    sed -i '' "$@"
  else
    # Linux/GNU sed
    sed -i "$@"
  fi
}

# Load .env file if present, preserving command-line environment variables
# Usage: load_env_file SCRIPT_ROOT [VAR1 VAR2 ...]
# If additional variable names are provided, they will also be preserved from command-line
load_env_file() {
  local script_root="$1"
  shift
  local preserve_vars=("$@")
  local env_file="${script_root}/.env"
  
  # Save existing values if set (always preserve GITHUB_USERNAME and GITHUB_TOKEN)
  local saved_github_username="${GITHUB_USERNAME:-}"
  local saved_github_token="${GITHUB_TOKEN:-}"
  
  # Save any additional variables that were requested
  declare -A saved_vars
  for var in "${preserve_vars[@]}"; do
    # Use indirect variable reference to check if variable is set
    if [[ -n "${!var:-}" ]]; then
      saved_vars["$var"]="${!var}"
    fi
  done
  
  # Load .env file if it exists
  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${env_file}"
    set +a
  fi
  
  # Restore command-line values if they were set (takes precedence over .env)
  if [[ -n "$saved_github_username" ]]; then
    GITHUB_USERNAME="$saved_github_username"
  fi
  if [[ -n "$saved_github_token" ]]; then
    GITHUB_TOKEN="$saved_github_token"
  fi
  
  # Restore additional preserved variables
  for var in "${!saved_vars[@]}"; do
    eval "${var}=\"${saved_vars[$var]}\""
  done
}
