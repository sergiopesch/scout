SCOUT_RELEASE_VERSION ?= 0.1.0

.PHONY: bootstrap configure-secrets rotate-approval-key secret-tool generate core-test persistence-test bridge-test launch-test app-test gateway-build release-lint build run check package provision-package smoke-existing live-smoke-existing package-smoke live-smoke notarize clean deep-clean

bootstrap:
	cd Gateway && npm ci
	node Scripts/configure-gateway-token.mjs
	xcodegen generate

configure-secrets:
	node Scripts/configure-gateway-token.mjs

rotate-approval-key: secret-tool
	.build/tools/scout-launcher secrets rotate-approval

secret-tool:
	mkdir -p .build/tools
	xcrun swiftc -parse-as-library -O -D SCOUT_SECRET_TOOL -framework Security -framework LocalAuthentication Tools/ScoutLauncher/LauncherSecurityPolicy.swift Tools/ScoutLauncher/main.swift -o .build/tools/scout-launcher

generate:
	xcodegen generate

core-test:
	swift test --package-path Packages/ScoutCore

persistence-test:
	swift test --package-path Packages/ScoutPersistence

bridge-test:
	cd Gateway && npm run check

launch-test:
	node --test Scripts/run-scout.test.mjs Scripts/package-release.test.mjs
	mkdir -p .build/tools
	xcrun swiftc -parse-as-library Tools/ScoutLauncher/LauncherSecurityPolicy.swift Tools/ScoutLauncherTests/LauncherSecurityPolicyTests.swift -o .build/tools/scout-launcher-policy-tests
	.build/tools/scout-launcher-policy-tests

gateway-build:
	cd Gateway && npm run build

release-lint:
	node --check Scripts/package-release.mjs
	node Scripts/verify-action-pins.mjs
	node Scripts/generate-gateway-third-party-licenses.mjs --check
	ruby -e 'require "yaml"; ARGV.each { |file| YAML.load_file(file, aliases: true) }' .github/workflows/ci.yml .github/workflows/secrets.yml .github/ISSUE_TEMPLATE/config.yml

app-test: generate
	mkdir -p .build
	lockf -k .build/app-test.lock xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO test

build: generate
	xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build

run: configure-secrets gateway-build build
	./Scripts/run-scout.sh

check: release-lint secret-tool core-test persistence-test bridge-test gateway-build launch-test app-test

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
	rm -rf .build Scout.xcodeproj dist Packages/ScoutCore/.build Packages/ScoutPersistence/.build

deep-clean: clean
	rm -rf Gateway/node_modules
