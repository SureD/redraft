.PHONY: architecture build lint project run test

build: project
	xcodebuild -project Redraft.xcodeproj -scheme Redraft -configuration Debug \
		-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath .build build

project:
	xcodegen generate

run: build
	open .build/Build/Products/Debug/Redraft.app

test:
	swift test --package-path Packages/RedraftCore

lint:
	xcrun swift-format lint --strict --recursive App Packages/RedraftCore/Package.swift \
		Packages/RedraftCore/Sources Packages/RedraftCore/Tests

architecture:
	python3 scripts/update_architecture.py
