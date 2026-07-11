# Common development tasks.
#
# `make run` launches via `swift run` (quick dev loop); TCC grants are then
# attributed to the launching terminal. To exercise the end-user permission
# flow, build the bundle (`make app`) and open it (`./scripts/make-app.sh --run`).

.PHONY: all build test app run check fix clean

SWIFT_SOURCES := Package.swift Sources Tests

all: build

# Debug build (compile check)
build:
	swift build

# Unit tests
test:
	swift test

# Release build wrapped into build/LiveTranscriber.app
# (pass SIGN_ID=<cert name> to sign with a stable identity instead of ad-hoc)
app:
	./scripts/make-app.sh

# Quick dev loop: build and launch directly with SwiftPM
run:
	swift run LiveTranscriber

# Formatting check (fails when violations are found)
check:
	xcrun swift-format lint --strict --recursive $(SWIFT_SOURCES)

# Apply fixable formatting issues in place
fix:
	xcrun swift-format format --in-place --recursive $(SWIFT_SOURCES)

clean:
	swift package clean
	rm -rf build
