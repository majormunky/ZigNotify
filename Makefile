.PHONY: build run check-listeners status test-notify install

TARGET := x86_64-linux-gnu
BINARY := zig-out/bin/zignotify
INSTALL_PATH := $(HOME)/.local/bin/zignotify
CONFIG_DIR :=- $(HOME)/.config/zignotify

build:
	zig build -Dtarget=$(TARGET)

run:
	pkill zignotify 2>/dev/null || true
	zig build run -Dtarget=$(TARGET)

check-listeners:
	@echo "=== Notification Daemon Check ==="
	@busctl --user list | grep -i notif || echo "Nothing found"

status:
	@pgrep -a zignotify && echo "" && busctl --user list | grep -i notif || echo "zignotify is not running"

test-notify:
	notify-send "Test" "This is a normal notification"

# Install binary to ~/.local/bin
install: build
	@mkdir -p $(dir $(INSTALL_PATH))
	cp $(BINARY) $(INSTALL_PATH)
	@echo "Installed to $(INSTALL_PATH)"
