TARGET := iphone:clang:5.1:5.1
ARCHS = armv7
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 5Tube
5Tube_FILES = Tweak.m YTMux.m YTAuth.m
5Tube_FRAMEWORKS = Foundation UIKit
5Tube_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
5Tube_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
