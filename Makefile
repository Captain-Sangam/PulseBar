.PHONY: build run clean install

build:
	swift build -c release

run:
	swift run

clean:
	swift package clean
	rm -rf .build

install: build
	@echo "Installing PulseBar to /Applications..."
	@mkdir -p build/PulseBar.app/Contents/MacOS
	@mkdir -p build/PulseBar.app/Contents/Resources
	@cp .build/release/PulseBar build/PulseBar.app/Contents/MacOS/
	@cp Info.plist build/PulseBar.app/Contents/
	@# The menu-bar icon is drawn from an SF Symbol at runtime — no bundled asset needed.
	@# The files in Icons/ are WebP-encoded, so re-encode to real PNG for the Dock/app icon.
	@sips -s format png Icons/128-mac.png --out build/PulseBar.app/Contents/Resources/AppIcon.png >/dev/null
	@cp -r build/PulseBar.app /Applications/
	@echo "Installation complete!"

help:
	@echo "Available commands:"
	@echo "  make build   - Build the release binary"
	@echo "  make run     - Run the app in debug mode"
	@echo "  make clean   - Clean build artifacts"
	@echo "  make install - Install to /Applications"
