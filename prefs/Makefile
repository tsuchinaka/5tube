TARGET := iphone:clang:5.1:5.1
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = YouTubeInnerTubePrefs
YouTubeInnerTubePrefs_FILES = YTPrefsController.m
YouTubeInnerTubePrefs_INSTALL_PATH = /Library/PreferenceBundles
YouTubeInnerTubePrefs_FRAMEWORKS = UIKit
YouTubeInnerTubePrefs_PRIVATE_FRAMEWORKS = Preferences
YouTubeInnerTubePrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I$(THEOS)/vendor/include
YouTubeInnerTubePrefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS5.1.sdk/System/Library/PrivateFrameworks

include $(THEOS_MAKE_PATH)/bundle.mk
