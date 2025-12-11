#!/usr/bin/env bash
# Docker operations for Pluto update scripts

# Get image digest
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
          # Get ALL version tags, not just those with "latest" tag
          local stable_versions
          stable_versions=$(echo "$versions_json" | jq -r \
            '.[] | .metadata.container.tags[]?' 2>/dev/null | \
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
          
          # If no version found, fall back to highest stable version
          if [[ -z "$version_tag" || "$version_tag" == "null" || "$version_tag" == "" ]]; then
            echo "    ${service}: no beta versions found, using highest stable version" >&2
            version_tag=$(echo "$versions_json" | jq -r \
              '.[] | .metadata.container.tags[]?' 2>/dev/null | \
              grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
          fi
        else
          # For stable channel: get ALL version tags and select the highest
          # Don't rely on "latest" tag - get all numeric version tags and pick the highest
          version_tag=$(echo "$versions_json" | jq -r \
            '.[] | .metadata.container.tags[]?' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
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

# Update docker-compose.yml images
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
