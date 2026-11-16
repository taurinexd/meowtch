# Vedetta build entry points.
#
# The TESTFLAGS below work around a Command Line Tools quirk on macOS 26:
# `swift test` does not add the Developer Frameworks / lib paths where
# Testing.framework and lib_TestingInterop.dylib live. Only when the CLT
# is the toolchain in use: with Xcode in use a plain `swift test` works,
# and these flags would link the CLT's Testing.framework against Xcode's
# (undefined Testing symbols) — the CLT folder is often still installed
# next to Xcode, so its mere presence isn't the signal.

# Prefer full Xcode when present: recent Command Line Tools ship without the
# SwiftUI macro plugins (@State fails with "SwiftUIMacros not found").
XCODE_DEV := /Applications/Xcode.app/Contents/Developer
ifeq (,$(DEVELOPER_DIR))
ifneq (,$(wildcard $(XCODE_DEV)))
export DEVELOPER_DIR := $(XCODE_DEV)
endif
endif

CLT := /Library/Developer/CommandLineTools
DEVFW := $(CLT)/Library/Developer/Frameworks
DEVLIB := $(CLT)/Library/Developer/usr/lib
ACTIVE_DEV := $(or $(DEVELOPER_DIR),$(shell xcode-select -p 2>/dev/null))

ifeq ($(CLT),$(ACTIVE_DEV))
TESTFLAGS := -Xswiftc -F$(DEVFW) -Xlinker -F$(DEVFW) \
	-Xlinker -rpath -Xlinker $(DEVFW) \
	-Xlinker -rpath -Xlinker $(DEVLIB)
endif

.PHONY: build test app run clean

build:
	cd App && swift build

test:
	cd App && swift test $(TESTFLAGS)

app:
	Scripts/make-app.sh

run: app
	open dist/Meowtch.app

clean:
	rm -rf App/.build dist
