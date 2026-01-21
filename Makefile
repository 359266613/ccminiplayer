TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = CCMiniPlayer
CCMiniPlayer_FILES = Tweak.xm
CCMiniPlayer_CFLAGS = -fobjc-arc
CCMiniPlayer_FRAMEWORKS = UIKit Foundation QuartzCore
CCMiniPlayer_PRIVATE_FRAMEWORKS = MediaRemote

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
