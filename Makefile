.DEFAULT_GOAL := status
.PHONY: build run check-listeners status test-notify install init-config run-tests

TARGET := x86_64-linux-gnu
BINARY := zig-out/bin/munknotify
INSTALL_PATH := $(HOME)/.local/bin/munknotify
CONFIG_DIR := $(HOME)/.config/munknotify

build:
	zig build -Dtarget=$(TARGET)

run:
	pkill munknotify 2>/dev/null || true
	zig build run -Dtarget=$(TARGET)

check-listeners:
	@echo "=== Notification Daemon Check ==="
	@busctl --user list | grep -i notif || echo "Nothing found"

status:
	@pgrep -a munknotify && echo "" && busctl --user list | grep -i notif || echo "munknotify is not running"

test-notify:
	notify-send "Test" "This is a normal notification"

# Create default config if it doesn't exist
init-config:
	@mkdir -p $(CONFIG_DIR)
	@if [ ! -f $(CONFIG_DIR)/config ]; then \
		cp config.example $(CONFIG_DIR)/config; \
		echo "Config created at $(CONFIG_DIR)/config"; \
	else \
		echo "Config already exists at $(CONFIG_DIR)/config"; \
	fi

# Install binary to ~/.local/bin
install: build
	@mkdir -p $(dir $(INSTALL_PATH))
	cp $(BINARY) $(INSTALL_PATH)
	@echo "Installed to $(INSTALL_PATH)"

run-tests:
	@zig build test --summary all
