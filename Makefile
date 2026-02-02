TARGET = iphone:clang:15.0
INSTALL_TARGET_PROCESSES = SpringBoard appstored installd TrollDecrypt
THEOS_PACKAGE_SCHEME = rootless

PACKAGE_VERSION = 1.3.1-4

include $(THEOS)/makefiles/common.mk
SUBPROJECTS += deps/SSZipArchive
include $(THEOS_MAKE_PATH)/aggregate.mk

APPLICATION_NAME = TrollDecrypt
TWEAK_NAME = TrollDecryptHook
TOOL_NAME = TDDaemonKiller

TrollDecrypt_FILES = $(shell find . \
    -path "*/.theos/*" -prune -o \
    -path "./deps/SSZipArchive/*" -prune -o \
    -path "./appstoretrollerKiller/main.m" -prune -o \
    \( -name "*.m" -o -name "*.mm" -o -name "*.xm" -o -name "*.c" \) -print)

TrollDecrypt_FRAMEWORKS = UIKit CoreGraphics MobileCoreServices Security
TrollDecrypt_PRIVATE_FRAMEWORKS = AppServerSupport RunningBoardServices
TrollDecrypt_CFLAGS = -fobjc-arc -I./include -I./deps

TrollDecrypt_LDFLAGS += -F$(THEOS_OBJ_DIR)
TrollDecrypt_LDFLAGS += -Wl,-rpath,@executable_path/Frameworks
TrollDecrypt_EXTRA_FRAMEWORKS += SSZipArchive

TrollDecrypt_OBJCFLAGS = -include shared.h
TrollDecrypt_CODESIGN_FLAGS = -STrollDecrypt.entitlements
TrollDecrypt_INSTALL_PATH = /Applications

# Tweak files (hooks into appstored)
TrollDecryptHook_FILES = TweakHook.xm
TrollDecryptHook_CFLAGS = -fobjc-arc

# Tool to kill daemons with root privileges (renamed to avoid directory conflict)
TDDaemonKiller_FILES = appstoretrollerKiller/main.m appstoretrollerKiller/TSUtil.m
TDDaemonKiller_INSTALL_NAME = appstoretrollerKiller
TDDaemonKiller_CFLAGS = -fobjc-arc
TDDaemonKiller_CODESIGN_FLAGS = -SappstoretrollerKiller/entitlements.plist
TDDaemonKiller_INSTALL_PATH = /usr/local/bin

internal-stage::
	echo "Moving SSZipArchive.framework into app bundle"
	mkdir -p $(THEOS_STAGING_DIR)/Applications/TrollDecrypt.app/Frameworks
	cp -R $(THEOS_STAGING_DIR)/Library/Frameworks/SSZipArchive.framework \
	      $(THEOS_STAGING_DIR)/Applications/TrollDecrypt.app/Frameworks
	rm -rf $(THEOS_STAGING_DIR)/Library

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	echo "compiling Assets.car..."
	$(ECHO_NOTHING)mkdir -p $(THEOS_PROJECT_DIR)/_assetbuild$(ECHO_END)
	$(ECHO_NOTHING)xcrun actool Resources/Assets.xcassets \
		--output-format human-readable-text \
		--notices --warnings \
		--platform iphoneos \
		--minimum-deployment-target 14.0 \
		--app-icon AppIcon \
		--include-all-app-icons \
		--output-partial-info-plist "$(THEOS_PROJECT_DIR)/_assetbuild/assetcatalog.plist" \
		--compile "$(THEOS_STAGING_DIR)/Applications/TrollDecrypt.app"$(ECHO_END)
	$(ECHO_NOTHING)rm -rf "$(THEOS_STAGING_DIR)/Applications/TrollDecrypt.app/Assets.xcassets"$(ECHO_END)

	echo "Building .tipa"
	$(ECHO_NOTHING)rm -rf Payload$(ECHO_END)
	$(ECHO_NOTHING)rm -f TrollDecrypt.tipa$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)ldid -STrollDecrypt.entitlements $(THEOS_STAGING_DIR)/Applications/TrollDecrypt.app/TrollDecrypt$(ECHO_END)
	$(ECHO_NOTHING)cp -a $(THEOS_STAGING_DIR)/Applications/* $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)mv $(THEOS_STAGING_DIR)/Payload .$(ECHO_END)
	$(ECHO_NOTHING)zip -q -r TrollDecrypt.tipa Payload$(ECHO_END)
	$(ECHO_NOTHING)rm -rf Payload$(ECHO_END)
