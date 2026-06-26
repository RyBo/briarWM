.PHONY: build release test run check sign clean

# Build the debug binary.
build:
	swift build

# Optimized build.
release:
	swift build -c release

# Run the unit tests (uses swift-testing; no Xcode required).
test:
	swift test

# Build and run in the foreground (Ctrl-C to stop).
run: build
	.build/debug/briarWM

# Validate a config file without launching the WM.
#   make check                       # checks ~/.config/briarWM/config.yaml
#   make check CONFIG=config.example.yaml
check: build
	.build/debug/briarWM --check-config $(CONFIG)

# Self-sign the debug binary so the Accessibility (TCC) grant survives rebuilds.
# One-time setup: create a self-signed code-signing cert named "briarWM-dev" in
# Keychain Access (Certificate Assistant → Create a Certificate → Code Signing).
sign: build
	codesign --force --sign briarWM-dev .build/debug/briarWM
	@echo "signed; the Accessibility grant should now persist across rebuilds"

clean:
	swift package clean
	rm -rf .build
