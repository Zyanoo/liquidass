#!/bin/zsh
make clean
make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean
make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1
make clean
# this only works if you got the roothide theos fork: https://github.com/roothide/Developer
make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
