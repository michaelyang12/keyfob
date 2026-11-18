XCODE_DEV := /Applications/Xcode.app/Contents/Developer
ifneq ($(wildcard $(XCODE_DEV)),)
export DEVELOPER_DIR := $(XCODE_DEV)
endif

APP := build/keyfob.app
BIN := .build/release/Keyfob

.PHONY: build app run install icon clean

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Keyfob
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	codesign --force --sign - $(APP)

run: app
	-pkill -x Keyfob
	open $(APP)

install: app
	-pkill -x Keyfob
	rm -rf /Applications/keyfob.app
	cp -R $(APP) /Applications/
	open /Applications/keyfob.app

icon:
	rm -rf build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
