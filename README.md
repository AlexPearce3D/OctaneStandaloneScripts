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

### `scripts/light_control_panel.lua`

Creates a floating light-control panel for Octane Standalone scenes.

Current version: `v0.1.13`

Highlights:

- Scans the current scene and falls back to a file-backed `.ocs` scan when Octane's live Lua graph only exposes anonymous internals.
- Shows exposed Float controls created by `expose_nested_emissions.lua`.
- Traces exposed power controls back to their original Texture emission nodes for the `Go` action when possible.
- Includes daylight environment power controls.
- Supports per-row power sliders, off/reset/delete buttons, `Go` selection, and global all-off/reset.
- Adds row borders and marks the last interacted row with a `>` prefix.
- Supports marking a target node for deletion, then writing/reloading with `Apply+Render`.
- Writes a `.lightpanel.bak` backup before modifying a scene.

## Usage

Open a script in Octane Standalone's Lua script editor while a project is open and run it.

`expose_nested_emissions.lua` writes changes in place after creating a backup. To dry-run from command-line/script execution, pass:

```sh
--dry-run
```

`light_control_panel.lua` edits file-backed scene values in memory first. Use `Apply+Render` in the panel to write the scene, reload it, and restart rendering.

The first log line prints each script version so you can confirm which copy Octane ran.
