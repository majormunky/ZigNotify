# MunkNotify

A lightweight Linux notification daemon written in Zig, implementing the [freedesktop.org Desktop Notifications Specification](https://specifications.freedesktop.org/notification-spec/notification-spec-latest.html) (v1.2).

![Zig](https://img.shields.io/badge/Zig-0.14+-orange)
![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/platform-Linux%20%2F%20Wayland-green)

## Features

- **D-Bus service** — implements `org.freedesktop.Notifications`
- **Wayland native** — uses `wlr-layer-shell` for compositor-managed surfaces
- **Multiple notifications** — independent surfaces stacked vertically, each dismissed independently
- **Auto-dismiss** — respects per-notification timeouts, configurable default
- **Urgency styling** — distinct accent colors for low, normal, and critical urgency
- **App icon rendering** — renders icons from file paths (PNG, JPEG, etc.)
- **App name display** — shows sending application above the summary
- **Config file** — `~/.config/zignotify/config` with hot reload via inotify
- **`NotificationClosed` signal** — emitted on expiry, programmatic close, or on user dismiss

## Dependencies

| Library | Purpose |
|---|---|
| `libsystemd` | sd-bus D-Bus implementation |
| `wayland-client` | Wayland compositor communication |
| `wayland-protocols` | XDG shell protocol |
| `wlr-protocols` | `wlr-layer-shell` protocol |
| `cairo` | 2D rendering |
| `gdk-pixbuf-2.0` | Image loading for icons |

### Install dependencies (Arch / CachyOS)

```bash
sudo pacman -S systemd-libs wayland wayland-protocols wlr-protocols cairo gdk-pixbuf2
```

### Install dependencies (Debian / Ubuntu)

```bash
sudo apt install libsystemd-dev libwayland-dev wayland-protocols libcairo2-dev libgdk-pixbuf-2.0-dev
```

> **Note:** `wlr-protocols` may not be in the Debian repos. Clone it from [gitlab.freedesktop.org/wlroots/wlr-protocols](https://gitlab.freedesktop.org/wlroots/wlr-protocols) and generate the headers manually.

## Build

Requires **Zig 0.14+**.

```bash
# Clone the repo
git clone https://github.com/majormunky/munknotify
cd zignotify

# Generate Wayland protocol bindings
wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml src/xdg-shell.h
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml src/xdg-shell.c
wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml src/wlr-layer-shell-unstable-v1.h
wayland-scanner private-code /usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml src/wlr-layer-shell-unstable-v1.c

# Build
zig build -Dtarget=x86_64-linux-gnu

# Or build and run directly
zig build run -Dtarget=x86_64-linux-gnu
```

## Installation

```bash
# Install binary to ~/.local/bin
make install

# Create default config
make init-config

# Install and enable systemd user service
cp zignotify.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zignotify
```

## Configuration

Config file location: `~/.config/zignotify/config`

Changes are picked up automatically via inotify — no restart needed.

```ini
# Notification size
width = 300
height = 100
margin = 10

# Timeout in milliseconds (-1 uses default_timeout, 0 = never expire)
default_timeout = 5000

# Font sizes
font_size_summary = 14.0
font_size_body = 12.0

# Corner radius
corner_radius = 8.0

# Position: top_right, top_left, bottom_right, bottom_left
position = top_right

# Colors in r,g,b,a format (0.0 - 1.0)
background_color = 0.18, 0.18, 0.18, 1.0
low_color        = 0.5,  0.5,  0.5,  1.0
normal_color     = 0.27, 0.52, 0.95, 1.0
critical_color   = 0.9,  0.2,  0.2,  1.0
```

## Usage

### Disable your existing notification daemon

If you're running swaync or dunst, stop it before starting zignotify:

```bash
# swaync
systemctl --user disable --now swaync
sudo mv /usr/share/dbus-1/services/org.erikreider.swaync.service \
        /usr/share/dbus-1/services/org.erikreider.swaync.service.bak

# dunst
systemctl --user disable --now dunst
```

### Send test notifications

```bash
notify-send "Hello" "This is a normal notification"
notify-send -u low "FYI" "Low priority"
notify-send -u critical "Warning" "Something is wrong"
notify-send --icon=/usr/share/icons/hicolor/48x48/apps/firefox.png "Firefox" "Icon test"
```

### Makefile targets

```bash
make build          # Build the project
make run            # Kill existing instance and run fresh build
make kill           # Stop the running daemon
make status         # Check if zignotify owns org.freedesktop.Notifications
make check-listeners # See what's currently on the notification bus
make test-notify    # Send a normal notification
make test-low       # Send a low urgency notification
make test-critical  # Send a critical notification
make test-all       # Send all three urgency levels
make test-icon      # Send a notification with an icon
make test-close     # Send and programmatically close a notification
make monitor        # Watch raw D-Bus notification traffic
make watch-config   # Print a message when the config file changes
make install        # Copy binary to ~/.local/bin
make clean          # Remove build artifacts
```

## Project Structure

```
src/
  main.zig          — Entry point, D-Bus vtable, event loop
  wayland.zig       — Wayland connection, layer shell surfaces, Cairo rendering
  state.zig         — Shared daemon state, notification store
  config.zig        — Config file parsing
  inotify.zig       — File watch for config hot reload
  notification.zig  — Notification data types
  vtable.c          — sd-bus vtable (C file, required due to opaque struct)
  vtable.h          — vtable header
  xdg-shell.c/h                        — Generated Wayland protocol bindings
  wlr-layer-shell-unstable-v1.c/h      — Generated layer shell bindings
build.zig           — Zig build script
munknotify.service   — systemd user service file
Makefile            — Useful development commands
```

## How It Works

1. **D-Bus** — munknotify claims `org.freedesktop.Notifications` on the session bus via sd-bus, registering a vtable with the four required methods (`GetCapabilities`, `GetServerInformation`, `Notify`, `CloseNotification`).

2. **Notification queue** — incoming `Notify` calls are parsed and placed into a pending queue rather than processed immediately, avoiding conflicts between the D-Bus and Wayland event loops.

3. **Wayland rendering** — the main event loop drains the pending queue, creating a `zwlr_layer_surface_v1` for each notification. Surfaces are anchored to a screen corner and stacked vertically with configurable margin.

4. **Cairo drawing** — each surface gets a shared memory buffer (`wl_shm`) drawn with Cairo: rounded rectangle background, urgency accent bar, app icon, app name, summary, and body text.

5. **Dismissal** — notifications are removed on timeout expiry, pointer click, or `CloseNotification` call. The `NotificationClosed` signal is emitted in all cases with the appropriate reason code.

## Compatibility

Tested on:
- **CachyOS** (Arch-based) with **Hyprland**
- Requires a Wayland compositor with `wlr-layer-shell` support (Hyprland, Sway, river, etc.)
- Does **not** support X11

## License

MIT
