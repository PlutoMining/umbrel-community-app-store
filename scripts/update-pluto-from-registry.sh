#!/usr/bin/env bash

set -euo pipefail

# Update Pluto apps in this community store based on images in GHCR.
# This script:
#   - Resolves image digests for a given app version and channel (stable/beta)
#   - Updates docker-compose.yml with pinned image digests (preserves indentation style)
#   - Detects version changes including transitions between stable and beta channels
#   - Bumps umbrel-app.yml version when the bundle changes
#   - Fetches release notes from CHANGELOG.md for stable releases
#   - Provides interactive prompt to edit release notes (unless --no-prompt is used)
#   - Optionally commits and pushes changes
#
# Beta channel behavior:
#   Uses the latest stable release UNLESS there is a HIGHER beta release available.
#   - If 1.1.3-beta.0 (beta) and 1.1.3 (stable) both exist → selects 1.1.3 (stable)
#   - If only 1.1.4-beta.0 exists (no 1.1.4 stable) → selects 1.1.4-beta.0
#   - If 1.1.3 (stable) and 1.1.4-beta.0 (beta) exist → selects 1.1.4-beta.0 (higher: 1.1.4 > 1.1.3)
#
# It mirrors the version-bump behavior implemented in the main Pluto repo.
# The script is indentation-agnostic and works with any YAML indentation style.

# Determine script directory and source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/pluto-common.sh"

# Load environment variables from .env file if present
load_env_file "$STORE_ROOT"

# Source all library modules
source "${SCRIPT_DIR}/lib/pluto-versions.sh"
source "${SCRIPT_DIR}/lib/pluto-docker.sh"
source "${SCRIPT_DIR}/lib/pluto-changelog.sh"
source "${SCRIPT_DIR}/lib/pluto-release-notes.sh"
source "${SCRIPT_DIR}/lib/pluto-git.sh"
source "${SCRIPT_DIR}/lib/pluto-list.sh"

# Main script state variables
CHANNEL=""
NO_COMMIT=false
DRY_RUN=false
LIST_VERSIONS=false
CHANGES_MADE=false
NEW_APP_VERSION=""
NO_PROMPT=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --channel stable|beta [--no-commit] [--dry-run] [--list-versions] [--no-prompt]

Options:
  --channel         stable | beta
  --no-commit       Skip git commit and push (default: false)
  --dry-run         Preview changes without modifying files (default: false)
  --list-versions   List current versions in the repository
  --no-prompt       Skip interactive release notes prompt (default: false)
  -h, --help        Show this help

Environment:
  DOCKER_REGISTRY   Registry base (default: ${DOCKER_REGISTRY})

Exit codes:
  0  Success (changes made and committed if --no-commit not set)
  1  Error occurred
  2  No changes needed (bundle unchanged)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel)
        CHANNEL="${2:-}"
        shift 2
        ;;
      --no-commit)
        NO_COMMIT=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --list-versions)
        LIST_VERSIONS=true
        shift
        ;;
      --no-prompt)
        NO_PROMPT=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        ;;
    esac
  done
}

ensure_args() {
  # Skip validation if listing versions
  if $LIST_VERSIONS; then
    # Channel is optional for list-versions, but if provided, validate it
    if [[ -n "$CHANNEL" ]]; then
      [[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || err "--channel must be stable or beta"
    fi
    return 0
  fi
  
  [[ -n "$CHANNEL" ]] || err "--channel is required"
  [[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || err "--channel must be stable or beta"
}

# Main update function - orchestrates the update process
update_app() {
  local app_dir="$1"
  local manifest="${app_dir}/umbrel-app.yml"
  local compose="${app_dir}/docker-compose.yml"

  [[ -f "$manifest" && -f "$compose" ]] || err "Missing Umbrel app files in $app_dir"

  local -a services=(backend discovery frontend grafana prometheus)
  local -A current_versions
  local -A latest_versions
  local -A version_changes
  local -a new_pairs=()
  local svc current_version latest_version change_type

  # Step 1: Extract current versions from docker-compose.yml
  log "Extracting current versions from docker-compose.yml..."
  for svc in "${services[@]}"; do
    current_version=$(extract_image_version "$compose" "$svc")
    if [[ -z "$current_version" || "$current_version" == "unknown" ]]; then
      err "Could not extract version for service ${svc} from ${compose}"
    fi
    current_versions["$svc"]="$current_version"
    if $DRY_RUN; then
      log "[dry-run]   ${svc}: current version ${current_version}"
    else
      log "  ${svc}: current version ${current_version}"
    fi
  done

  # Step 2: Check GHCR for latest versions
  log ""
  log "Checking GHCR for latest versions (channel: ${CHANNEL})..."
  for svc in "${services[@]}"; do
    current_version="${current_versions[$svc]}"
    if $DRY_RUN; then
      log "[dry-run]   ${svc}: checking latest version..."
    else
      log "  ${svc}: checking latest version..."
    fi
    # Capture stdout (version only) while letting stderr (logs/errors) pass through
    # Use process substitution to separate stdout and stderr
    latest_version=$({ get_latest_version "$svc" "$CHANNEL" 2>&3; } 3>&2)
    
    # Extract just the version number (should be the only line on stdout)
    latest_version=$(echo "$latest_version" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
    
    # Validate that we got a version
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
      err "Failed to get latest version for ${svc} (channel: ${CHANNEL})"
    fi
    
    latest_versions["$svc"]="$latest_version"
    
    # Determine change type
    change_type=$(compare_semver_change "$current_version" "$latest_version")
    version_changes["$svc"]="$change_type"
    
    if [[ "$change_type" != "none" ]]; then
      log "    ${current_version} -> ${latest_version} (${change_type} change)"
    else
      log "    ${current_version} (no change)"
    fi
  done

  # Step 3: Build new image pairs with latest versions
  log ""
  log "Resolving image digests for latest versions..."
  for svc in "${services[@]}"; do
    latest_version="${latest_versions[$svc]}"
    local image="${DOCKER_REGISTRY}/pluto-${svc}:${latest_version}"
    local digest
    digest=$(get_digest "$image")
    new_pairs+=("${svc}=${image}@sha256:${digest}")
    if $DRY_RUN; then
      log "[dry-run]   ${svc}: resolved ${image}@sha256:${digest}"
    fi
  done

  local current_fp new_fp
  current_fp=$(compute_bundle_fingerprint "$compose")

  local tmp
  tmp="$(mktemp)"
  cp "$compose" "$tmp"
  update_compose_images "$tmp" "${new_pairs[@]}"
  new_fp=$(compute_bundle_fingerprint "$tmp")
  
  if $DRY_RUN; then
    log "[dry-run] Current fingerprint: ${current_fp}"
    log "[dry-run] New fingerprint:     ${new_fp}"
  fi
  
  rm -f "$tmp"

  # Check if any version actually changed (not just digests)
  local has_version_change=false
  for svc in "${services[@]}"; do
    if [[ "${version_changes[$svc]}" != "none" ]]; then
      has_version_change=true
      break
    fi
  done

  if [[ "$current_fp" == "$new_fp" ]]; then
    if [[ "$has_version_change" == "true" ]]; then
      # Version tags changed but fingerprint is the same - this shouldn't happen normally
      # but could occur if digests are identical (same image content, different tags)
      # In this case, we should still update to reflect the version tag change
      if $DRY_RUN; then
        log "[dry-run] Version tags changed but digests are identical. Will update version tags."
      fi
      # Continue to update the images and version
    else
      if $DRY_RUN; then
        log "[dry-run] Bundle unchanged for ${app_dir}; no updates needed."
      else
        log "Bundle unchanged for ${app_dir}; nothing to update."
      fi
      return 1  # Return 1 to indicate no changes
    fi
  fi

  # Step 4: Determine highest semver change type across all services
  local highest_change="none"
  for svc in "${services[@]}"; do
    change_type="${version_changes[$svc]}"
    case "$change_type" in
      major)
        highest_change="major"
        ;;
      minor)
        if [[ "$highest_change" != "major" ]]; then
          highest_change="minor"
        fi
        ;;
      patch)
        if [[ "$highest_change" != "major" && "$highest_change" != "minor" ]]; then
          highest_change="patch"
        fi
        ;;
    esac
  done

  # Step 5: Calculate new app version based on highest change
  local current_version next_version
  current_version=$(get_current_app_version "$manifest")
  if [[ -z "$current_version" ]]; then
    err "Could not determine current app version from $manifest"
  fi

  # If bundle changed but no version changes, still bump patch
  if [[ "$highest_change" == "none" ]]; then
    log ""
    log "Bundle changed (digests updated) but versions unchanged. Bumping patch version."
    highest_change="patch"
  else
    log ""
    log "Highest change type: ${highest_change}"
  fi
  
  # Parse current app version and bump accordingly
  local major minor patch
  local current_base="${current_version%%-*}"
  IFS='.' read -r major minor patch <<<"$current_base"
  
  case "$highest_change" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
  esac
  
  local new_base="${major}.${minor}.${patch}"

  if [[ "$CHANNEL" == "stable" ]]; then
    next_version="$new_base"
  else
    # For beta: if base version changed, reset to beta.0; otherwise increment beta number
    if [[ "$new_base" != "$current_base" ]]; then
      # Base version changed, reset beta to 0
      next_version="${new_base}-beta.0"
    else
      # Base version unchanged, increment beta number
      local beta_suffix="${current_version#*-}"
      if [[ "$beta_suffix" =~ ^beta\.([0-9]+)$ ]]; then
        local beta_num="${BASH_REMATCH[1]}"
        beta_num=$((beta_num + 1))
        next_version="${new_base}-beta.${beta_num}"
      else
        next_version="${new_base}-beta.0"
      fi
    fi
  fi

  log ""
  log "Current app version for ${app_dir}: $current_version"
  log "New app version for ${app_dir}:     $next_version"

  # Step 6: Fetch and prepare release notes
  local release_notes=""
  if [[ "$CHANNEL" == "stable" ]]; then
    log ""
    log "Fetching release notes from CHANGELOG.md..."
    local changelog_content
    changelog_content=$(fetch_changelog 2>&1)

    if [[ -n "$changelog_content" && "$changelog_content" != *"Warning:"* ]]; then
      local extracted_notes
      extracted_notes=$(extract_release_notes "$next_version" "$changelog_content")

      if [[ -n "$extracted_notes" ]]; then
        release_notes="$extracted_notes"
        log "Found release notes for version ${next_version}"
      else
        log "Warning: No release notes found in CHANGELOG for version ${next_version}, using default"
        release_notes="Version ${next_version}"
      fi
    else
      log "Warning: Could not fetch CHANGELOG, using default release notes"
      release_notes="Version ${next_version}"
    fi
  else
    # Beta channel: use simplified format
    release_notes="Version ${next_version}"
  fi

  # Prompt user to edit release notes if not in dry-run or no-prompt mode
  release_notes=$(prompt_release_notes "$release_notes")

  if $DRY_RUN; then
    log "[dry-run] Would update ${manifest}:"
    log "[dry-run]   version: \"${current_version}\" -> \"${next_version}\""
    log "[dry-run]   releaseNotes:"
    echo "$release_notes" | while IFS= read -r line; do
      log "[dry-run]     $line"
    done
    log "[dry-run] Would update ${compose} with new image digests:"
    for pair in "${new_pairs[@]}"; do
      svc="${pair%%=*}"
      img="${pair#*=}"
      log "[dry-run]   ${svc}: ${img}"
    done
    NEW_APP_VERSION="$next_version"
    CHANGES_MADE=true
    return 0
  fi

  # Update version
  sed_in_place -E "s/version: \".*\"/version: \"${next_version}\"/" "$manifest"

  # Update release notes in YAML
  update_release_notes "$manifest" "$release_notes"

  update_compose_images "$compose" "${new_pairs[@]}"

  NEW_APP_VERSION="$next_version"
  CHANGES_MADE=true
  log "Updated ${manifest} and ${compose}"
  return 0  # Return 0 to indicate changes were made
}

main() {
  parse_args "$@"
  ensure_args

  # Pre-flight checks
  command -v docker >/dev/null 2>&1 || err "docker is required"
  command -v jq >/dev/null 2>&1 || err "jq is required"
  if ! docker buildx version >/dev/null 2>&1; then
    err "docker buildx is required"
  fi

  # Handle list-versions mode
  if $LIST_VERSIONS; then
    list_available_versions "backend"
    exit 0
  fi

  if $DRY_RUN; then
    log "Running in dry-run mode (no changes will be made)"
  fi

  # Update the app
  local update_result
  if [[ "$CHANNEL" == "stable" ]]; then
    if update_app "${STORE_ROOT}/pluto-mining-pluto"; then
      update_result=0
    else
      update_result=1
    fi
  else
    if update_app "${STORE_ROOT}/pluto-mining-pluto-next"; then
      update_result=0
    else
      update_result=1
    fi
  fi

  # If no changes were made, exit with code 2
  if [[ $update_result -ne 0 ]]; then
    log "No changes needed."
    exit 2
  fi

  # Commit and push if requested
  if $DRY_RUN; then
    if ! $NO_COMMIT; then
      log "[dry-run] Would commit and push changes"
      log "[dry-run] Commit message would be:"
      log "[dry-run]   Update Pluto (${CHANNEL}) to app version ${NEW_APP_VERSION}"
      log "[dry-run]   Re-resolved image digests from registry"
    else
      log "[dry-run] Would skip commit (--no-commit flag set)"
    fi
    log "Dry-run completed. Review the output above."
  elif ! $NO_COMMIT; then
    commit_and_push
    log "Done. Changes committed and pushed."
  else
    log "Done. Changes made but not committed (--no-commit flag set)."
    log "New app version: ${NEW_APP_VERSION}"
  fi

  exit 0
}

main "$@"
