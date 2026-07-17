SCOUT_RELEASE_VERSION ?= 0.1.0

.PHONY: bootstrap configure-secrets rotate-approval-key secret-tool generate core-test persistence-test bridge-test launch-test app-test gateway-build build run check package provision-package smoke-existing live-smoke-existing package-smoke live-smoke notarize clean

bootstrap:
	cd Gateway && npm install
	node Scripts/configure-gateway-token.mjs
	xcodegen generate

configure-secrets:
	node Scripts/configure-gateway-token.mjs

rotate-approval-key: secret-tool
	.build/tools/scout-launcher secrets rotate-approval

secret-tool:
	mkdir -p .build/tools
	xcrun swiftc -parse-as-library -O -framework Security Tools/ScoutLauncher/main.swift -o .build/tools/scout-launcher

generate:
	xcodegen generate

core-test:
	swift test --package-path Packages/ScoutCore

persistence-test:
	swift test --package-path Packages/ScoutPersistence

bridge-test:
	cd Gateway && npm test

launch-test:
	node --test Scripts/run-scout.test.mjs

gateway-build:
	cd Gateway && npm run build

app-test: generate
	xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test

build: generate
	xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build

run: configure-secrets gateway-build build
	./Scripts/run-scout.sh

check: secret-tool core-test persistence-test bridge-test launch-test app-test

package: configure-secrets
	node Scripts/package-release.mjs --adhoc

provision-package:
	node Scripts/provision-packaged-secrets.mjs

smoke-existing:
	dist/Scout-$(SCOUT_RELEASE_VERSION)/Scout.app/Contents/MacOS/Scout --smoke-test

live-smoke-existing:
	dist/Scout-$(SCOUT_RELEASE_VERSION)/Scout.app/Contents/MacOS/Scout --live-smoke

package-smoke: package
	node Scripts/provision-packaged-secrets.mjs
	dist/Scout-$(SCOUT_RELEASE_VERSION)/Scout.app/Contents/MacOS/Scout --smoke-test

live-smoke: package
	node Scripts/provision-packaged-secrets.mjs
	dist/Scout-$(SCOUT_RELEASE_VERSION)/Scout.app/Contents/MacOS/Scout --live-smoke

notarize: configure-secrets
	node Scripts/package-release.mjs --notarize

clean:
	swift package --package-path Packages/ScoutCore clean
	swift package --package-path Packages/ScoutPersistence clean
	cd Gateway && npm run clean
	rm -rf dist
