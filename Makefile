TARGET := iphone:clang:5.1:5.1
ARCHS = armv7
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YouTubeInnerTube
YouTubeInnerTube_FILES = Tweak.m YTMux.m YTAuth.m
YouTubeInnerTube_FRAMEWORKS = Foundation UIKit
YouTubeInnerTube_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
YouTubeInnerTube_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
