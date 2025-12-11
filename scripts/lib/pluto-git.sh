#!/usr/bin/env bash
# Git operations for Pluto update scripts

# Check git state
check_git_state() {
  command -v git >/dev/null 2>&1 || err "git is required"
  
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    err "Not a git repository"
  fi
}

# Commit and push changes
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
