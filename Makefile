# Common development tasks.
#
# `make run` launches via `swift run` (quick dev loop); TCC grants are then
# attributed to the launching terminal. To exercise the end-user permission
# flow, build the bundle (`make app`) and open it (`./scripts/make-app.sh --run`).

.PHONY: all build test app run check fix clean

SWIFT_SOURCES := Package.swift Sources Tests

# The Swift Build system compiles asset catalogs (Assets.xcassets -> Assets.car)
# and lays out a proper resource bundle; the native build system does not, which
# leaves the tray icon unusable. Keep every SwiftPM invocation on it.
SWIFT_BUILD_SYSTEM := --build-system swiftbuild

all: build

# Debug build (compile check)
build:
	swift build $(SWIFT_BUILD_SYSTEM)

# Unit tests
test:
	swift test $(SWIFT_BUILD_SYSTEM)

# Release build wrapped into build/LiveTranscriber.app
# (pass SIGN_ID=<cert name> to sign with a stable identity instead of ad-hoc)
app:
	./scripts/make-app.sh

# Quick dev loop: build and launch directly with SwiftPM
run:
	swift run $(SWIFT_BUILD_SYSTEM) LiveTranscriber

# Formatting check (fails when violations are found)
check:
	xcrun swift-format lint --strict --recursive $(SWIFT_SOURCES)

# Apply fixable formatting issues in place
fix:
	xcrun swift-format format --in-place --recursive $(SWIFT_SOURCES)

clean:
	swift package clean
	rm -rf build
