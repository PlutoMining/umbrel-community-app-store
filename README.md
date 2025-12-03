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


#### Using the Umbrel CLI

```bash
sudo ~/umbrel/scripts/repo add https://github.com/PlutoMining/umbrel-community-app-store.git

sudo ~/umbrel/scripts/repo update
```

If you want to remove the app store

```bash
sudo ~/umbrel/scripts/repo remove https://github.com/PlutoMining/umbrel-community-app-store.git
```

After a short refresh, the **Pluto Mining** store and its apps will be visible in the Umbrel UI.

### Installing Pluto from this store

You can install the apps either from the Umbrel UI or via the CLI:

- Install **Pluto (stable)**:

```bash
sudo ~/umbrel/scripts/app install pluto-mining-pluto
```

- Install **Pluto Next (beta)**:

```bash
sudo ~/umbrel/scripts/app install pluto-mining-pluto-next
```

Upgrades are handled by re-running the same install command or from the UI once new versions are published to this repo.

### How this repo is updated

The main Pluto repo (`PlutoMining/pluto`) owns the Umbrel manifests for both channels in `umbrel-apps/pluto` and `umbrel-apps/pluto-next`. During stable and beta releases:

- Pluto’s release scripts build and push Docker images.
- The manifests in `umbrel-apps/pluto*` are updated with new versions and image digests.
- A helper script in the Pluto repo (`scripts/sync-community-store.sh`) copies the latest manifests into:
  - `pluto-mining-pluto/` for the stable app
  - `pluto-mining-pluto-next/` for the beta app

You should commit and push changes to this repo whenever new versions of Pluto are released so Umbrel can see them.

