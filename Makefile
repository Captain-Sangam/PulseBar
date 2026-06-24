.PHONY: build run clean install icon

build:
	swift build -c release

run:
	swift run

clean:
	swift package clean
	rm -rf .build

install: build icon
	@echo "Installing PulseBar to /Applications..."
	@mkdir -p build/PulseBar.app/Contents/MacOS
	@mkdir -p build/PulseBar.app/Contents/Resources
	@cp .build/release/PulseBar build/PulseBar.app/Contents/MacOS/
	@cp Info.plist build/PulseBar.app/Contents/
	@# The menu-bar icon is drawn from an SF Symbol at runtime — no bundled asset needed.
	@# The Dock / notification icon is a real .icns built by the `icon` target below.
	@cp build/AppIcon.icns build/PulseBar.app/Contents/Resources/AppIcon.icns
	@cp -r build/PulseBar.app /Applications/
	@echo "Installation complete!"

# Build a proper multi-resolution AppIcon.icns from the Icons/ sources.
#
# The files in Icons/ are WebP-encoded (despite their .png names), so each is first
# re-encoded to real PNG into a .iconset directory with the exact names iconutil
# expects, then compiled to a single .icns. A flat PNG is NOT a valid app icon —
# without a real .icns referenced from Info.plist, macOS falls back to the generic
# grid placeholder (the blank icon seen in the notification permission prompt).
icon:
	@echo "Building AppIcon.icns..."
	@rm -rf build/AppIcon.iconset
	@mkdir -p build/AppIcon.iconset
	@sips -s format png Icons/16-mac.png   --out build/AppIcon.iconset/icon_16x16.png      >/dev/null
	@sips -s format png Icons/32-mac.png   --out build/AppIcon.iconset/icon_16x16@2x.png   >/dev/null
	@sips -s format png Icons/32-mac.png   --out build/AppIcon.iconset/icon_32x32.png      >/dev/null
	@sips -s format png Icons/64-mac.png   --out build/AppIcon.iconset/icon_32x32@2x.png   >/dev/null
	@sips -s format png Icons/128-mac.png  --out build/AppIcon.iconset/icon_128x128.png    >/dev/null
	@sips -s format png Icons/256-mac.png  --out build/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	@sips -s format png Icons/256-mac.png  --out build/AppIcon.iconset/icon_256x256.png    >/dev/null
	@sips -s format png Icons/512-mac.png  --out build/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	@sips -s format png Icons/512-mac.png  --out build/AppIcon.iconset/icon_512x512.png    >/dev/null
	@sips -s format png Icons/1024-mac.png --out build/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	@iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
	@rm -rf build/AppIcon.iconset

help:
	@echo "Available commands:"
	@echo "  make build   - Build the release binary"
	@echo "  make run     - Run the app in debug mode"
	@echo "  make clean   - Clean build artifacts"
	@echo "  make install - Install to /Applications"
