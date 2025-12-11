#!/usr/bin/env bash

set -euo pipefail

# Update Pluto apps in this community store based on images in GHCR.
# This script:
#   - Resolves image digests for a given app version and channel (stable/beta)
#   - Updates docker-compose.yml with pinned image digests (preserves indentation style)
#   - Detects version changes including transitions between stable and beta channels
#   - Bumps umbrel-app.yml version when the bundle changes
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

STORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CHANNEL=""
NO_COMMIT=false
DRY_RUN=false
LIST_VERSIONS=false
CHANGES_MADE=false
NEW_APP_VERSION=""

DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/plutomining}"

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

# Load environment variables from .env file if present
load_env_file "$STORE_ROOT"

log() {
  echo "[update-pluto-from-registry] $*"
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

usage() {
  cat <<EOF
Usage: $(basename "$0") --channel stable|beta [--no-commit] [--dry-run] [--list-versions]

Options:
  --channel         stable | beta
  --no-commit       Skip git commit and push (default: false)
  --dry-run         Preview changes without modifying files (default: false)
  --list-versions   List current versions in the repository
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

get_digest() {
  local image="$1"
  local manifest_json sha

  if ! manifest_json=$(docker buildx imagetools inspect "$image" --format "{{json .Manifest}}" 2>&1); then
    err "Failed to inspect image $image: $manifest_json"
  fi

  sha=$(echo "$manifest_json" | jq -r '.digest // empty')
  [[ -n "$sha" && "$sha" != "null" ]] || err "Could not extract SHA256 digest from $image"
  echo "${sha#sha256:}"
}

extract_image_version() {
  local compose_file="$1"
  local service="$2"
  
  # Extract version from image line like: image: ghcr.io/plutomining/pluto-backend:1.1.2@sha256:...
  # Uses POSIX-compliant [[:space:]] character class for portability
  # Match only top-level service definitions (not references in depends_on sections)
  # by finding the service block and extracting the image version from within that block only
  # We stop at the next top-level service definition to avoid matching nested references
  local in_service=0
  while IFS= read -r line; do
    # Check if this is a top-level service definition (service name followed by colon at start of line)
    if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
      # Check if it's our target service
      if [[ "$line" =~ ^[[:space:]]*${service}:[[:space:]]*$ ]]; then
        in_service=1
      else
        # Different service started, stop processing
        in_service=0
      fi
    elif [[ $in_service -eq 1 ]] && [[ "$line" =~ ^[[:space:]]+image: ]]; then
      # Found image line within our target service block
      # Extract version using sed
      echo "$line" | sed -E 's|.*:([0-9]+\.[0-9]+\.[0-9]+(-[^@]+)?)@.*|\1|'
      return 0
    fi
  done < "$compose_file"

  return 1
}

# Get the latest version tag from GHCR
# For beta channel: tries :beta tag first, falls back to :latest if :beta doesn't exist
# For stable channel: always uses :latest tag
# Outputs ONLY the version number to stdout, all logs go to stderr
get_latest_version() {
  local service="$1"
  local channel="${2:-stable}"  # Default to stable if not provided
  local image_base="${DOCKER_REGISTRY}/pluto-${service}"
  
  # Use GitHub API first (fastest and most reliable, doesn't require docker)
  if command -v curl >/dev/null 2>&1 && [[ -n "${GITHUB_TOKEN:-}" ]]; then
    local package_name="pluto-${service}"
    local api_url="https://api.github.com/orgs/plutomining/packages/container/${package_name}/versions"
    
    local versions_json
    versions_json=$(curl -s --max-time 10 -H "Authorization: token ${GITHUB_TOKEN}" \
                       -H "Accept: application/vnd.github.v3+json" \
                       "$api_url" 2>/dev/null)
    
    # Check if response is valid (not an error message)
    if [[ -n "$versions_json" && "$versions_json" != "null" && "$versions_json" != "" ]]; then
      # Check if it's an error response
      if echo "$versions_json" | jq -e '.message' >/dev/null 2>&1; then
        echo "    ${service}: GitHub API error: $(echo "$versions_json" | jq -r '.message // "unknown error"')" >&2
      else
        # Response is valid, try to extract version
        local version_tag=""
        
        if [[ "$channel" == "beta" ]]; then
          # For beta channel: use the latest stable release UNLESS there is a HIGHER beta release
          # - If 1.1.3-beta.0 (beta) and 1.1.3 (stable) both exist → select 1.1.3 (stable)
          # - If only 1.1.4-beta.0 exists (no 1.1.4 stable) → select 1.1.4-beta.0
          # - If 1.1.3 (stable) and 1.1.4-beta.0 (beta) exist → select 1.1.4-beta.0 (higher: 1.1.4 > 1.1.3)
          
          # Get all beta versions (e.g., 1.1.3-beta.0, 1.1.4-beta.0)
          local beta_versions
          beta_versions=$(echo "$versions_json" | jq -r \
            '.[] | select(.metadata.container.tags[]? == "beta") | .metadata.container.tags[]' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' | sort -V)
          
          # Get all stable versions (e.g., 1.1.3, 1.1.2)
          local stable_versions
          stable_versions=$(echo "$versions_json" | jq -r \
            '.[] | select(.metadata.container.tags[]? == "latest") | .metadata.container.tags[]' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)
          
          # Build candidate list: all stable versions + beta versions without stable counterparts
          local candidate_versions=""
          
          # Add all stable versions
          if [[ -n "$stable_versions" ]]; then
            candidate_versions="$stable_versions"
          fi
          
          # For each beta version, check if there's a corresponding stable version
          while IFS= read -r beta_version; do
            [[ -z "$beta_version" ]] && continue
            # Extract base version (remove -beta.X suffix if present)
            local base_version="${beta_version%-beta.*}"
            # Check if this base version exists in stable versions
            if ! echo "$stable_versions" | grep -qFx "$base_version"; then
              # No stable version for this base, include the beta version
              if [[ -z "$candidate_versions" ]]; then
                candidate_versions="$beta_version"
              else
                candidate_versions="${candidate_versions}"$'\n'"${beta_version}"
              fi
            fi
          done <<< "$beta_versions"
          
          # Pick the highest version from candidates
          if [[ -n "$candidate_versions" ]]; then
            version_tag=$(echo "$candidate_versions" | sort -V | tail -1)
          fi
          
          # If no version found, fall back to latest
          if [[ -z "$version_tag" || "$version_tag" == "null" || "$version_tag" == "" ]]; then
            echo "    ${service}: no beta versions found, using 'latest'" >&2
            version_tag=$(echo "$versions_json" | jq -r \
              '.[] | select(.metadata.container.tags[]? == "latest") | .metadata.container.tags[]' 2>/dev/null | \
              grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
          fi
        else
          # For stable channel: use latest
          version_tag=$(echo "$versions_json" | jq -r \
            '.[] | select(.metadata.container.tags[]? == "latest") | .metadata.container.tags[]' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
        fi
        
        if [[ -n "$version_tag" && "$version_tag" != "null" && "$version_tag" != "" ]]; then
          echo "$version_tag"
          return 0
        fi
      fi
    fi
  elif [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "    ${service}: GITHUB_TOKEN not set, falling back to docker inspection" >&2
  fi
  
  # Without GitHub API, we cannot reliably determine version numbers from :beta or :latest tags
  # The docker-compose.yml requires specific version tags (e.g., :1.1.2), not floating tags
  echo "[update-pluto-from-registry][error] GITHUB_TOKEN is required to determine image versions." >&2
  echo "[update-pluto-from-registry][error] Set GITHUB_TOKEN environment variable or configure it in GitHub Actions." >&2
  return 1
}

# Compare two semver versions and return the change type: "major", "minor", "patch", or "none"
compare_semver_change() {
  local old_version="$1"
  local new_version="$2"
  
  # Remove any pre-release suffixes for comparison
  local old_base="${old_version%%-*}"
  local new_base="${new_version%%-*}"
  
  if [[ "$old_base" == "$new_base" ]]; then
    echo "none"
    return 0
  fi
  
  # Parse versions
  local old_major old_minor old_patch
  local new_major new_minor new_patch
  
  IFS='.' read -r old_major old_minor old_patch <<<"$old_base"
  IFS='.' read -r new_major new_minor new_patch <<<"$new_base"
  
  if [[ "$old_major" != "$new_major" ]]; then
    echo "major"
  elif [[ "$old_minor" != "$new_minor" ]]; then
    echo "minor"
  elif [[ "$old_patch" != "$new_patch" ]]; then
    echo "patch"
  else
    echo "none"
  fi
}

list_available_versions() {
  log "Current configuration in this repository:"
  log ""
  
  # Check stable channel
  local stable_manifest="${STORE_ROOT}/pluto-mining-pluto/umbrel-app.yml"
  local stable_compose="${STORE_ROOT}/pluto-mining-pluto/docker-compose.yml"
  
  if [[ -f "$stable_manifest" && -f "$stable_compose" ]]; then
    local stable_app_version
    stable_app_version=$(get_current_app_version "$stable_manifest" 2>/dev/null || echo "unknown")
    local stable_image_version
    stable_image_version=$(extract_image_version "$stable_compose" "backend" 2>/dev/null || echo "unknown")
    
    log "  Stable channel (pluto-mining-pluto):"
    log "    Umbrel app version: ${stable_app_version}"
    log "    Docker image tag:   ${stable_image_version}"
    log ""
  fi
  
  # Check beta channel
  local beta_manifest="${STORE_ROOT}/pluto-mining-pluto-next/umbrel-app.yml"
  local beta_compose="${STORE_ROOT}/pluto-mining-pluto-next/docker-compose.yml"
  
  if [[ -f "$beta_manifest" && -f "$beta_compose" ]]; then
    local beta_app_version
    beta_app_version=$(get_current_app_version "$beta_manifest" 2>/dev/null || echo "unknown")
    local beta_image_version
    beta_image_version=$(extract_image_version "$beta_compose" "backend" 2>/dev/null || echo "unknown")
    
    log "  Beta channel (pluto-mining-pluto-next):"
    log "    Umbrel app version: ${beta_app_version}"
    log "    Docker image tag:   ${beta_image_version}"
    log ""
  fi
  
  log "To find available Docker image versions to update to:"
  log ""
  log "1. Check GitHub Packages (shows all published image tags):"
  log "   https://github.com/orgs/plutomining/packages?repo_name=pluto"
  log ""
  log "2. Check Pluto releases (shows what versions were released):"
  log "   https://github.com/PlutoMining/pluto/releases"
  log ""
  log "3. Test a specific version exists:"
  log "   docker buildx imagetools inspect ghcr.io/plutomining/pluto-backend:1.4.0"
  log ""
  log "Usage:"
  log "  Run the script with --channel to re-resolve image digests:"
  log "  ./scripts/update-pluto-from-registry.sh --channel stable"
  log ""
  log "  The script extracts each service's version from docker-compose.yml and"
  log "  re-resolves their digests. The Umbrel app version will be bumped if"
  log "  the image bundle changes."
}

compute_bundle_fingerprint() {
  local file=$1
  awk '
    $1 ~ /^[a-zA-Z0-9_-]+:$/ { svc=substr($1, 1, length($1)-1) }
    $1 == "image:" && svc != "" {
      img=$2
      gsub("\"", "", img)
      printf "%s=%s\n", svc, img
    }
  ' "$file" | sort | sha256sum | awk '{print $1}'
}

get_current_app_version() {
  local manifest="$1"
  grep -E '^version:' "$manifest" | sed -E 's/version: "(.*)"/\1/'
}

bump_stable_version() {
  local current="$1"
  local base="$2"

  if [[ -z "$current" ]]; then
    echo "$base"
    return
  fi

  local higher
  higher=$(printf "%s\n%s\n" "$current" "$base" | sort -V | tail -n1)
  if [[ "$higher" == "$base" && "$base" != "$current" ]]; then
    echo "$base"
  else
    local major minor patch
    IFS='.' read -r major minor patch <<<"$current"
    patch=$((patch + 1))
    echo "${major}.${minor}.${patch}"
  fi
}

bump_beta_version() {
  local current="$1"
  local base="$2"

  local cur_base cur_suffix
  cur_base="${current%%-*}"
  cur_suffix="${current#*-}"

  if [[ "$cur_base" != "$base" || -z "$cur_suffix" ]]; then
    echo "${base}-beta.0"
    return
  fi

  if [[ "$cur_suffix" =~ ^beta\.([0-9]+)$ ]]; then
    local n="${BASH_REMATCH[1]}"
    n=$((n + 1))
    echo "${base}-beta.${n}"
  else
    echo "${base}-beta.0"
  fi
}

update_compose_images() {
  local compose="$1"
  shift
  local pairs=("$@")

  local pair svc img
  for pair in "${pairs[@]}"; do
    svc="${pair%%=*}"
    img="${pair#*=}"
    # Match service name with any indentation, then update image line within that service block
    # Uses POSIX-compliant [[:space:]] character class for portability
    # The pattern: find service line, then within that block (until next service or empty line), update image line
    # This works regardless of indentation level (spaces or tabs) and preserves the original indentation
    sed_in_place -E "/^[[:space:]]*${svc}:/,/^[[:space:]]*[a-zA-Z0-9_-]+:|^$/{
      /^[[:space:]]+image:/s|^([[:space:]]+)image:.*|\1image: ${img}|
    }" "$compose"
  done
}

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
  IFS='.' read -r major minor patch <<<"${current_version%%-*}"
  
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
  
  if [[ "$CHANNEL" == "stable" ]]; then
    next_version="${major}.${minor}.${patch}"
  else
    # For beta, append -beta.0 or increment beta number
    local beta_suffix="${current_version#*-}"
    if [[ "$beta_suffix" =~ ^beta\.([0-9]+)$ ]]; then
      local beta_num="${BASH_REMATCH[1]}"
      beta_num=$((beta_num + 1))
      next_version="${major}.${minor}.${patch}-beta.${beta_num}"
    else
      next_version="${major}.${minor}.${patch}-beta.0"
    fi
  fi

  log ""
  log "Current app version for ${app_dir}: $current_version"
  log "New app version for ${app_dir}:     $next_version"

  if $DRY_RUN; then
    log "[dry-run] Would update ${manifest}:"
    log "[dry-run]   version: \"${current_version}\" -> \"${next_version}\""
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

  sed_in_place -E "s/version: \".*\"/version: \"${next_version}\"/" "$manifest"
  sed_in_place -E "s/Version .*/Version ${next_version}/" "$manifest" || true

  update_compose_images "$compose" "${new_pairs[@]}"

  NEW_APP_VERSION="$next_version"
  CHANGES_MADE=true
  log "Updated ${manifest} and ${compose}"
  return 0  # Return 0 to indicate changes were made
}

check_git_state() {
  command -v git >/dev/null 2>&1 || err "git is required"
  
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    err "Not a git repository"
  fi
}

commit_and_push() {
  local app_name
  if [[ "$CHANNEL" == "stable" ]]; then
    app_name="pluto-mining-pluto"
  else
    app_name="pluto-mining-pluto-next"
  fi

  check_git_state

  local manifest="${STORE_ROOT}/${app_name}/umbrel-app.yml"
  local compose="${STORE_ROOT}/${app_name}/docker-compose.yml"

  # Check if there are any changes to commit for the specific files
  if git diff --quiet "$manifest" "$compose"; then
    log "No changes to commit."
    return 0
  fi

  # Stage the specific files
  git add "$manifest" "$compose"

  # Generate commit message
  local commit_msg="Update Pluto (${CHANNEL}) to app version ${NEW_APP_VERSION}

Re-resolved image digests from registry"

  # Commit
  if git commit -m "$commit_msg"; then
    log "Committed changes"
  else
    err "Failed to commit changes"
  fi

  # Push
  log "Pushing changes..."
  if git push; then
    log "Pushed changes successfully"
  else
    err "Failed to push changes. Make sure you have push access to the repository."
  fi
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
