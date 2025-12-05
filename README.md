## Pluto Mining Umbrel Community App Store

This repository hosts the **Pluto Mining** Umbrel Community App Store. It lets you install and test Pluto directly from a custom store, without waiting for the official Umbrel app store.

The structure follows the official template from [`getumbrel/umbrel-community-app-store`](https://github.com/getumbrel/umbrel-community-app-store).

### Store metadata

- Store ID: `pluto-mining` (see `umbrel-app-store.yml`)
- Apps:
  - `pluto-mining-pluto` – Pluto stable channel
  - `pluto-mining-pluto-next` – Pluto beta channel (pluto-next)


## Installation

To install this on your umbrel, you can add this repository through the Umbrel user interface as shown in the following demo:


### Adding this store to Umbrel OS

On your Umbrel OS box, add the Pluto Mining store 

#### Via UI

https://user-images.githubusercontent.com/10330103/197889452-e5cd7e96-3233-4a09-b475-94b754adc7a3.mp4

After a short refresh, the **Pluto Mining** store and its apps will be visible in the Umbrel UI.

### Installing Pluto from this store

You can install the apps either from the Umbrel UI or via the CLI:

- connect via SSH to your device
- Install **Pluto (stable)**:

```bash
umbreld client apps.install.mutate --appId pluto-mining-pluto
```

- Install **Pluto Next (beta)**:

```bash
umbreld client apps.install.mutate --appId pluto-mining-pluto-next
```

Upgrades are handled by re-running the same install command or from the UI once new versions are published to this repo.

## Updating Apps

This repository includes an automated update script that keeps the Pluto apps up-to-date with the latest images from GitHub Container Registry (GHCR).

### Update Script

The `scripts/update-pluto-from-registry.sh` script:

- **Resolves image digests** for all Pluto services (backend, discovery, frontend, grafana, prometheus) from GHCR
- **Updates docker-compose.yml** with pinned image digests for reproducibility
- **Detects version changes** including transitions between stable and beta channels
- **Bumps umbrel-app.yml version** automatically based on semver changes:
  - Major version change → bumps major version
  - Minor version change → bumps minor version
  - Patch version change → bumps patch version
  - Bundle change (digest update) → bumps patch version
- **Works with any YAML indentation style** (spaces or tabs, any indentation level)
- **Optionally commits and pushes** changes to the repository

### Usage

Update the **stable channel** (pluto-mining-pluto):
```bash
./scripts/update-pluto-from-registry.sh --channel stable
```

Update the **beta channel** (pluto-mining-pluto-next):
```bash
./scripts/update-pluto-from-registry.sh --channel beta
```

Preview changes without modifying files (dry-run):
```bash
./scripts/update-pluto-from-registry.sh --channel stable --dry-run
```

Update without committing changes:
```bash
./scripts/update-pluto-from-registry.sh --channel stable --no-commit
```

List current versions:
```bash
./scripts/update-pluto-from-registry.sh --list-versions
```

Show help:
```bash
./scripts/update-pluto-from-registry.sh --help
```

### Exit Codes

- `0` - Success (changes made and committed if `--no-commit` not set)
- `1` - Error occurred
- `2` - No changes needed (bundle unchanged)

### Requirements

- `docker` and `docker buildx` (for resolving image digests)
- `jq` (for JSON parsing)
- `GITHUB_TOKEN` environment variable (required - for querying GitHub API to find latest versions)
- `git` (if committing changes)
- Compatible with both Linux and macOS (uses cross-platform sed implementation)

### Beta Channel Behavior

The beta channel uses the latest stable release UNLESS there is a HIGHER beta release available:
- If `1.1.3-beta.0` (beta) and `1.1.3` (stable) both exist → selects `1.1.3` (stable preferred when base version matches)
- If only `1.1.4-beta.0` exists (no `1.1.4` stable yet) → selects `1.1.4-beta.0`
- If `1.1.3` (stable) and `1.1.4-beta.0` (beta) exist → selects `1.1.4-beta.0` (higher version: 1.1.4 > 1.1.3)

This ensures beta channel users get the latest stable releases when available, but can also access newer beta releases that haven't been released as stable yet.

**Note:** The script uses the GitHub API to find the latest image versions. **GITHUB_TOKEN is required** - the script will error if it's not set, as it cannot reliably determine version numbers from floating tags like `:beta` or `:latest` without the API.

### How It Works

1. **Extracts current versions** from `docker-compose.yml` for each service (supports any indentation style)
2. **Queries GHCR** for the latest available versions based on the channel
   - For beta channel: uses the latest stable release unless there's a higher beta release available (see Beta Channel Behavior section above)
   - For stable channel: uses `latest` tag
3. **Resolves image digests** for the latest versions to ensure reproducibility
4. **Computes bundle fingerprint** to detect if any changes occurred (compares image tags and digests)
5. **Bumps app version** in `umbrel-app.yml` based on the highest semver change detected across all services
6. **Updates docker-compose.yml** preserving the original indentation style
7. **Commits and pushes** changes (unless `--no-commit` is used)

The script mirrors the version-bump behavior implemented in the main Pluto repository, ensuring consistent versioning across channels. It correctly detects version changes even when switching between stable and beta channels (e.g., when a service moves from a stable version to a beta version).
