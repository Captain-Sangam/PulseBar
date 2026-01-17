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
	@cp icons/16-mac.png build/PulseBar.app/Contents/Resources/MenuBarIcon.png
	@cp icons/32-mac.png build/PulseBar.app/Contents/Resources/MenuBarIcon@2x.png
	@cp icons/128-mac.png build/PulseBar.app/Contents/Resources/AppIcon.png
	@cp -r build/PulseBar.app /Applications/
	@echo "Installation complete!"

help:
	@echo "Available commands:"
	@echo "  make build   - Build the release binary"
	@echo "  make run     - Run the app in debug mode"
	@echo "  make clean   - Clean build artifacts"
	@echo "  make install - Install to /Applications"
