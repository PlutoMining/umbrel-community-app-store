#!/usr/bin/env bash
# List/display operations for Pluto update scripts

# List available versions
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
