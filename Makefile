# Vedetta build entry points.
#
# The TESTFLAGS below work around a Command Line Tools quirk on macOS 26:
# `swift test` does not add the Developer Frameworks / lib paths where
# Testing.framework and lib_TestingInterop.dylib live. With full Xcode
# installed a plain `swift test` works and the flags are harmless no-ops.

DEVFW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEVLIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

ifneq (,$(wildcard $(DEVFW)))
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
	open dist/Vedetta.app

clean:
	rm -rf App/.build dist
