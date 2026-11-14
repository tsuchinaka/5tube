TARGET := iphone:clang:5.1:5.1
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = 5TubePrefs
5TubePrefs_FILES = YTPrefsController.m
5TubePrefs_INSTALL_PATH = /Library/PreferenceBundles
5TubePrefs_FRAMEWORKS = UIKit
5TubePrefs_PRIVATE_FRAMEWORKS = Preferences
5TubePrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I$(THEOS)/vendor/include
5TubePrefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS5.1.sdk/System/Library/PrivateFrameworks

include $(THEOS_MAKE_PATH)/bundle.mk
