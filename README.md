> [!NOTE]
> This tool was created with the assistance of AI (GitHub Copilot).

# bildschirmUniversum

A utility to easily manage display arrangements in BüroUniversum.

## bildschirmuniversum — manage external monitor arrangement

Instantly swap the left/right position of your two external monitors, vertically
align them, enforce 60 Hz, and optionally position the built-in laptop display
relative to the external group — all in one atomic operation. Designed for shared
desk environments where the physical monitor layout varies between desks.

**Requirements:** macOS  
**No administrator privileges required.**

### Install from GitHub release (recommended)

```bash
bash install.sh
# then (once) add ~/.local/bin to PATH if prompted
bildschirmuniversum
```

`install.sh` downloads the pre-compiled binary from the latest GitHub release —
no Xcode Command Line Tools required.

### Build from source

```bash
swiftc -O -o bildschirmuniversum bildschirmuniversum.swift
```

### Run directly without installing

```bash
swift bildschirmuniversum.swift
```

### Options

| Flag | Description |
|------|-------------|
| `--align top\|center\|bottom` | Vertical alignment when swapping (default: `bottom`) |
| `--no-align` | Skip vertical alignment when swapping |
| `--builtin bottom\|left\|right` | Reposition the built-in display relative to the external group. **External displays are left unchanged** when this flag is used |
| `--rotate-left normal\|left\|upsideDown\|right` | Set rotation for the display that ends up in the **left** slot |
| `--rotate-right normal\|left\|upsideDown\|right` | Set rotation for the display that ends up in the **right** slot |
| `--main left\|right\|builtin` | Move the menu bar to the specified display (slot names refer to the final arrangement) |
| `--no-refresh` | Skip the automatic 60 Hz refresh-rate change |
| `-h`, `--help` | Show usage information |
| `-V`, `--version` | Show version information |

The `--builtin` positions:

- `bottom` — centered horizontally below both external displays
- `left` — to the left of the external group, bottom-aligned
- `right` — to the right of the external group, bottom-aligned

The `--rotate-left` / `--rotate-right` rotation values:

- `normal` — 0° (landscape, upright)
- `left` — 90° counter-clockwise (portrait, top of panel faces left)
- `upsideDown` — 180° (landscape, inverted)
- `right` — 270° clockwise (portrait, top of panel faces right)

If the laptop lid is closed (clamshell mode) and `--builtin` or `--main builtin`
is specified, a warning is printed and the flag is silently ignored.

The `--main` flag moves the macOS menu bar to the specified display by shifting
all display origins so the target ends up at coordinate `(0, 0)`. It is applied
after all other positioning operations and can be combined with any other flag.

### How it works

Uses macOS's `CoreGraphics` to apply all changes in **one atomic transaction**:

- **Position swap** via `CGConfigureDisplayOrigin` — swaps screen-space origins
- **Refresh rate** via `CGConfigureDisplayWithDisplayMode` — finds the best 60 Hz mode
  at the current resolution, preserving HiDPI (pixel dimensions are matched)
- **Rotation** via the private `CGSSetDisplayRotation` API — applied immediately after
  the main transaction; same mechanism used by macOS display management utilities

Changes apply immediately and persist for the current login session.
Running the command again restores the original order.

---

## Development

### Creating a release

Releases are built automatically by GitHub Actions when a version tag is pushed.

1. Make sure all changes are committed and pushed to `main`.
2. Tag the commit with a version number following [Semantic Versioning](https://semver.org/):

   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```

3. The [Release workflow](.github/workflows/release.yml) will then:
   - Compile `bildschirmuniversum.swift` on `macos-latest`
   - Package the binary as `bildschirmuniversum-macos.zip`
   - Publish a GitHub release with the zip attached and auto-generated release notes

The new release will be picked up automatically by `install.sh` the next time a user runs it.
