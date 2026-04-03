.PHONY: build bundle install

bundle: build
	cp build/Release/EnumWindows AlfredWorkflow/
	cd AlfredWorkflow && zip -r ../SwiftWindowSwitcher.alfredworkflow info.plist icon.png switch.png EnumWindows

build:
	xcodebuild -project EnumWindows.xcodeproj \
		-target EnumWindows \
		-configuration Release \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

install: bundle
	open SwiftWindowSwitcher.alfredworkflow
