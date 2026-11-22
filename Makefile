.PHONY: architecture build core-build lint monitor project run test test-ui test-editor snapshots

UI_SOURCES := $(shell rg --files App -g '*.swift' | rg -v 'App/RedraftApp.swift')
SWIFT_FLAGS ?=
CORE_BUILD_DIR = $(shell swift build --package-path Packages/RedraftCore $(SWIFT_FLAGS) --show-bin-path 2>/dev/null)
CORE_MODULE_DIR = $(if $(wildcard $(CORE_BUILD_DIR)/Modules),$(CORE_BUILD_DIR)/Modules,$(CORE_BUILD_DIR))
CORE_OBJECTS = $(if $(wildcard $(CORE_BUILD_DIR)/libRedraftCore.a),$(CORE_BUILD_DIR)/libRedraftCore.a,$(shell rg --files --no-ignore $(CORE_BUILD_DIR)/RedraftCore.build -g '*.o'))
UI_TEST_FLAGS = -target $(shell uname -m)-apple-macosx13.0 -module-cache-path .build/ui-tests/ModuleCache \
	-swift-version 6 -parse-as-library -I $(CORE_MODULE_DIR)

core-build:
	swift build --package-path Packages/RedraftCore $(SWIFT_FLAGS)

build: project
	xcodebuild -project Redraft.xcodeproj -scheme Redraft -configuration Debug \
		-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath .build build

project:
	xcodegen generate

run: build
	open .build/Build/Products/Debug/Redraft.app

test:
	swift test --package-path Packages/RedraftCore $(SWIFT_FLAGS)

test-ui: core-build
	mkdir -p .build/ui-tests
	swiftc $(UI_TEST_FLAGS) $(UI_SOURCES) $(CORE_OBJECTS) \
		Tests/TestSupport.swift Tests/WorkspaceStateTests.swift \
		-o .build/ui-tests/WorkspaceStateTests
	.build/ui-tests/WorkspaceStateTests

snapshots: core-build
	mkdir -p .build/ui-tests
	swiftc $(UI_TEST_FLAGS) $(UI_SOURCES) $(CORE_OBJECTS) \
		Tests/TestSupport.swift Tests/NativeUISnapshots.swift \
		-o .build/ui-tests/NativeUISnapshots
	.build/ui-tests/NativeUISnapshots

test-editor: core-build
	mkdir -p .build/ui-tests
	swiftc $(UI_TEST_FLAGS) $(UI_SOURCES) $(CORE_OBJECTS) \
		Tests/TestSupport.swift Tests/EditorInteractionTests.swift \
		-o .build/ui-tests/EditorInteractionTests
	.build/ui-tests/EditorInteractionTests

lint:
	xcrun swift-format lint --strict --recursive App Packages/RedraftCore/Package.swift \
		Packages/RedraftCore/Sources Packages/RedraftCore/Tests Tests

architecture:
	python3 scripts/update_architecture.py

monitor:
	python3 scripts/agent_monitor.py serve
