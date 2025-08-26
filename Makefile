TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IMRead

IMRead_FILES = Tweak.x
IMRead_CFLAGS = -fobjc-arc
IMRead_FRAMEWORKS = Foundation CoreFoundation
IMRead_PRIVATE_FRAMEWORKS = IMCore

include $(THEOS_MAKE_PATH)/tweak.mk
