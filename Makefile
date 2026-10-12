# Scope — headless build (xcodegen + xcodebuild + SwiftPM)
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
DERIVED := $(CURDIR)/DerivedData
SCHEME := Scope
CONFIG ?= Debug
# Debug builds "Scope Debug.app" so it never collides with the installed copy (project.yml).
APP_NAME := $(if $(filter Debug,$(CONFIG)),Scope Debug,Scope)
APP := $(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME).app
XCB := xcodebuild -project Scope.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation CODE_SIGN_IDENTITY="-"

.PHONY: generate resolve build run test test-one clean app-path

generate:            ## Regenerate Scope.xcodeproj from project.yml
	xcodegen generate --spec project.yml

resolve: generate    ## Resolve remote SwiftPM deps (SwiftTerm) into DerivedData
	xcodebuild -project Scope.xcodeproj -scheme $(SCHEME) -derivedDataPath $(DERIVED) -skipPackagePluginValidation -resolvePackageDependencies

build: generate      ## Build the app (Debug by default; CONFIG=Release for release)
	$(XCB) build | tail -n 20

run: build           ## Launch the built .app
	# Without this, a build launched from inside a Scope thread inherits SCOPE_HOME and points at the
	# production ~/.scope -- same config, same thread records, same hook socket as the installed copy.
	env -u SCOPE_HOME -u SCOPE_SOCK -u SCOPE_THREAD -u SCOPE_TASK -u SCOPE_TASK_ROOT \
	    -u SCOPE_SCOPE -u SCOPE_SCOPE_ROOT -u SCOPE_PORT open "$(APP)"

app-path:            ## Print the path of the built .app
	@echo "$(APP)"

test:                ## SwiftPM unit tests (Swift Testing) — full package
	swift test

test-one:            ## One test file/suite: make test-one FILE=SlugTests
	@test -n "$(FILE)" || (echo "usage: make test-one FILE=<SuiteName or Suite/testName>"; exit 2)
	swift test --filter "$(FILE)"

clean:               ## Remove generated artifacts
	rm -rf Scope.xcodeproj DerivedData .build .swiftpm/xcode
