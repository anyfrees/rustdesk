set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
# Match the Rust and Xcode targets instead of the runner's current SDK version.
set(VCPKG_OSX_DEPLOYMENT_TARGET 15.0)
set(VCPKG_C_FLAGS "-miphoneos-version-min=15.0")
set(VCPKG_CXX_FLAGS "-miphoneos-version-min=15.0")
