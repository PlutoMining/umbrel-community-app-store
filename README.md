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
