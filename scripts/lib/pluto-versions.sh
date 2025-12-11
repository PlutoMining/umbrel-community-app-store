#!/usr/bin/env bash
# Version management functions for Pluto update scripts

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

# Get current app version from manifest
get_current_app_version() {
  local manifest="$1"
  grep -E '^version:' "$manifest" | sed -E 's/version: "(.*)"/\1/'
}

# Extract image version from docker-compose.yml
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

# Compute bundle fingerprint from docker-compose.yml
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

# Bump stable version
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

# Bump beta version
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
