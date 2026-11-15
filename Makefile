TARGET := iphone:clang:5.1:5.1
ARCHS = armv7
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 5Tube
5Tube_FILES = Tweak.m YTMux.m YTAuth.m Core/YTCommon.m Core/YTAPI.m Core/YTFeed.m Core/YTPlayer.m Core/YTCaptions.m Core/YTActions.m Core/YTTrending.m Core/YTHooks.m
5Tube_FRAMEWORKS = Foundation UIKit
5Tube_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I$(THEOS_PROJECT_DIR)
5Tube_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
