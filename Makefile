# theos Makefile (tuỳ chọn — dùng nếu bạn có theos)
# make clean && make
TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LocketPlus
LocketPlus_FILES = $(wildcard Tweak/*.m)
LocketPlus_FRAMEWORKS = Foundation UIKit AVFoundation PhotosUI CoreMedia QuartzCore
LocketPlus_CFLAGS = -fobjc-arc
LocketPlus_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
