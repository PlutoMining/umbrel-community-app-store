#!/usr/bin/env bash
# CHANGELOG operations for Pluto update scripts

# Fetch CHANGELOG.md from Pluto repository using GitHub API
fetch_changelog() {
  if [[ -n "$CHANGELOG_CACHE" ]]; then
    echo "$CHANGELOG_CACHE"
    return 0
  fi

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log "Warning: GITHUB_TOKEN not set, cannot fetch CHANGELOG"
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log "Warning: curl not available, cannot fetch CHANGELOG"
    return 1
  fi

  local api_url="https://api.github.com/repos/${PLUTO_REPO_OWNER}/${PLUTO_REPO_NAME}/contents/CHANGELOG.md"
  local response
  response=$(curl -s --max-time 10 \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "$api_url" 2>/dev/null)

  if [[ -z "$response" || "$response" == "null" ]]; then
    log "Warning: Failed to fetch CHANGELOG.md from GitHub"
    return 1
  fi

  # Check for API errors
  if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
    local error_msg
    error_msg=$(echo "$response" | jq -r '.message // "unknown error"')
    log "Warning: GitHub API error fetching CHANGELOG: $error_msg"
    return 1
  fi

  # Extract and decode base64 content
  local content
  content=$(echo "$response" | jq -r '.content // empty' | tr -d '\n' | base64 -d 2>/dev/null)

  if [[ -z "$content" ]]; then
    log "Warning: Failed to decode CHANGELOG.md content"
    return 1
  fi

  CHANGELOG_CACHE="$content"
  echo "$content"
  return 0
}

# Extract release notes for a specific version from CHANGELOG
extract_release_notes() {
  local version="$1"
  local changelog_content="$2"

  if [[ -z "$changelog_content" ]]; then
    return 1
  fi

  # Remove beta suffix for stable version lookup (e.g., 1.3.4-beta.0 -> 1.3.4)
  local base_version="${version%-beta.*}"
  
  # Try to match version patterns like:
  # ## [1.3.4] or ## [1.3.4-beta.0] or ## 1.3.4 or ## v1.3.4
  # Handle both with and without brackets, with and without v prefix
  local release_section=""
  
  # Try different patterns in order of likelihood
  for pattern in "## \\[${base_version}\\]" "## \\[v${base_version}\\]" "## ${base_version}" "## v${base_version}" "### \\[${base_version}\\]" "### ${base_version}"; do
    release_section=$(echo "$changelog_content" | awk -v pattern="$pattern" '
      BEGIN { in_section=0 }
      $0 ~ "^[[:space:]]*" pattern "[[:space:]]*" {
        in_section=1
        next
      }
      in_section && /^[[:space:]]*##[[:space:]]/ {
        # Next version section found (## or ###), stop
        exit
      }
      in_section {
        # Print content lines (skip version header lines)
        if ($0 !~ /^[[:space:]]*##/) {
          print
        }
      }
    ')
    
    if [[ -n "$release_section" ]]; then
      break
    fi
  done

  if [[ -z "$release_section" ]]; then
    return 1
  fi

  # Clean up the release notes:
  # - Remove leading/trailing whitespace from each line
  # - Remove completely empty lines at start/end
  # - Limit to reasonable length (first 30 lines)
  release_section=$(echo "$release_section" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk 'NF || prev {print} {prev=NF}' | head -30)

  # Remove trailing empty lines
  release_section=$(echo "$release_section" | awk '{lines[NR]=$0} END {for(i=NR;i>=1;i--) {if(length(lines[i])>0 || i==NR) {for(j=1;j<=i;j++) print lines[j]; break}}}')

  if [[ -z "$release_section" ]]; then
    return 1
  fi

  echo "$release_section"
  return 0
}
