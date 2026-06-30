# Octane Standalone Scripts

Lua utilities for Octane Standalone workflows.

## Scripts

### `scripts/expose_nested_emissions.lua`

Exposes nested Texture emission controls up to parent node graphs by adding Float value controls and Float input linkers.

Current version: `v0.4.07`

Highlights:

- Scans nested node graphs for material and light `emission` pins.
- Exposes emission `power` as parent-graph Float controls.
- Falls back to multiplying `efficiency or texture` when an emission node has no `power` pin.
- Resolves emission nodes connected before or after their material pin in the `.ocs` XML.
- Groups `wP...` parallax-plane emissions into a shared `wP Parallax Planes Power` control.
- Writes a `.exposed-emissions.bak` backup before modifying a scene.

## Usage

Open the script in Octane Standalone's Lua script editor while a project is open and run it.

By default the script writes changes in place after creating a backup. To dry-run from command-line/script execution, pass:

```sh
--dry-run
```

The first log line prints the script version so you can confirm which copy Octane ran.
