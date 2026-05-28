cmake_minimum_required(VERSION 3.16)
project(sidraw-dump CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Build mode:
#   SIDRAW_MONOLITHIC=ON  (default) build libresidfp + libsidplayfp statically
#                          from the vendored sources under external/. Produces
#                          a single self-contained binary with no system
#                          libsidplayfp dependency at runtime.
#   SIDRAW_MONOLITHIC=OFF link against the system libsidplayfp via pkg-config.
#                          Faster iteration build; binary needs libsidplayfp
#                          installed at runtime.
option(SIDRAW_MONOLITHIC "Statically link libresidfp/libsidplayfp from external/" ON)

if(SIDRAW_MONOLITHIC)
  include(ExternalProject)

  # vendored source trees, kept under external/ next to this CMakeLists
  # (read-only — we copy them into the build tree before autoreconf so the
  # user's checkout stays clean)
  set(LIBRESIDFP_SRC   "${CMAKE_CURRENT_SOURCE_DIR}/external/libresidfp-main")
  set(LIBSIDPLAYFP_SRC "${CMAKE_CURRENT_SOURCE_DIR}/external/libsidplayfp-master")

  if(NOT EXISTS "${LIBRESIDFP_SRC}/configure.ac")
    message(FATAL_ERROR "Vendored libresidfp not found at ${LIBRESIDFP_SRC}")
  endif()
  if(NOT EXISTS "${LIBSIDPLAYFP_SRC}/configure.ac")
    message(FATAL_ERROR "Vendored libsidplayfp not found at ${LIBSIDPLAYFP_SRC}")
  endif()

  set(EXT_PREFIX        "${CMAKE_BINARY_DIR}/ext")
  set(RESIDFP_INSTALL   "${EXT_PREFIX}/libresidfp/install")
  set(SIDPLAYFP_INSTALL "${EXT_PREFIX}/libsidplayfp/install")
  # force lib/ instead of the distro-default lib64 so the paths below are
  # predictable regardless of host (rhel/fedora pick lib64, debian picks lib).
  set(RESIDFP_AR        "${RESIDFP_INSTALL}/lib/libresidfp.a")
  set(SIDPLAYFP_AR      "${SIDPLAYFP_INSTALL}/lib/libsidplayfp.a")

  # autotools jobs honour parallelism via $(nproc); CMake's $(MAKE) sub-makes
  # would otherwise serialise.
  include(ProcessorCount)
  ProcessorCount(NPROC)
  if(NPROC EQUAL 0)
    set(NPROC 1)
  endif()

  ExternalProject_Add(libresidfp_ext
    SOURCE_DIR        "${EXT_PREFIX}/libresidfp/src"
    DOWNLOAD_COMMAND  ${CMAKE_COMMAND} -E copy_directory "${LIBRESIDFP_SRC}" "${EXT_PREFIX}/libresidfp/src"
    BUILD_IN_SOURCE   1
    CONFIGURE_COMMAND bash -c "autoreconf -fi && ./configure --prefix=${RESIDFP_INSTALL} --libdir=${RESIDFP_INSTALL}/lib --enable-static --disable-shared --with-pic --disable-tests"
    BUILD_COMMAND     make -j${NPROC}
    INSTALL_COMMAND   make install
    BUILD_BYPRODUCTS  "${RESIDFP_AR}"
  )

  ExternalProject_Add(libsidplayfp_ext
    SOURCE_DIR        "${EXT_PREFIX}/libsidplayfp/src"
    DOWNLOAD_COMMAND  ${CMAKE_COMMAND} -E copy_directory "${LIBSIDPLAYFP_SRC}" "${EXT_PREFIX}/libsidplayfp/src"
    BUILD_IN_SOURCE   1
    # Apply our `currentCycle()` patch (exposes EventScheduler PHI1 time
    # so sidraw-dump can timestamp captures with exact-cycle precision).
    # `patch -N` is no-op on a re-run, so this is idempotent across rebuilds.
    PATCH_COMMAND     bash -c "patch -p1 -N --silent < ${CMAKE_CURRENT_SOURCE_DIR}/libsidplayfp-current-cycle.patch || true"
    # the vendored libsidplayfp tree's configure.ac references
    # src/builders/exsid-builder/driver/m4 (a git submodule that's empty in
    # the vendored snapshot). aclocal scans the dir even with --without-exsid,
    # so create the stub before autoreconf.
    CONFIGURE_COMMAND bash -c "mkdir -p src/builders/exsid-builder/driver/m4 src/builders/usbsid-builder/driver/m4 && autoreconf -fi && PKG_CONFIG_PATH=${RESIDFP_INSTALL}/lib/pkgconfig ./configure --prefix=${SIDPLAYFP_INSTALL} --libdir=${SIDPLAYFP_INSTALL}/lib --enable-static --disable-shared --with-pic --without-usbsid --without-exsid --disable-testsuite --disable-tests"
    BUILD_COMMAND     make -j${NPROC}
    INSTALL_COMMAND   make install
    DEPENDS           libresidfp_ext
    BUILD_BYPRODUCTS  "${SIDPLAYFP_AR}"
  )

  # Imported targets — let CMake honour the DEPENDS chain even though
  # the .a files only exist after the ExternalProjects run.
  add_library(libresidfp_static STATIC IMPORTED GLOBAL)
  set_target_properties(libresidfp_static PROPERTIES IMPORTED_LOCATION "${RESIDFP_AR}")
  add_dependencies(libresidfp_static libresidfp_ext)

  add_library(libsidplayfp_static STATIC IMPORTED GLOBAL)
  set_target_properties(libsidplayfp_static PROPERTIES IMPORTED_LOCATION "${SIDPLAYFP_AR}")
  add_dependencies(libsidplayfp_static libsidplayfp_ext)

  # Three executables share the same statically-linked libsidplayfp +
  # libresidfp:
  #   sidraw-dump  --  .sid -> .sidraw (register-write capture)
  #   sidraw-play  --  .sidraw -> .wav (drives libresidfp directly; no 6510)
  #   sid-play     --  .sid -> .wav (full libsidplayfp render, A/B reference)
  foreach(tgt sidraw-dump sidraw-play sid-play)
    if (tgt STREQUAL "sidraw-dump")
      add_executable(${tgt} src/sidraw_dump.cpp)
    elseif (tgt STREQUAL "sidraw-play")
      add_executable(${tgt} src/sidraw_play.cpp)
    elseif (tgt STREQUAL "sid-play")
      add_executable(${tgt} src/sid_play.cpp)
    endif()
    target_include_directories(${tgt} PRIVATE
      "${SIDPLAYFP_INSTALL}/include"
      "${RESIDFP_INSTALL}/include")
    target_link_libraries(${tgt} PRIVATE libsidplayfp_static libresidfp_static m)
    target_link_options(${tgt} PRIVATE -static-libstdc++ -static-libgcc)
    add_dependencies(${tgt} libsidplayfp_ext libresidfp_ext)
  endforeach()

else()
  # dynamic-link build (system libsidplayfp + libresidfp via pkg-config)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(SIDPLAYFP REQUIRED IMPORTED_TARGET libsidplayfp)
  pkg_check_modules(RESIDFP   REQUIRED IMPORTED_TARGET libresidfp)

  add_executable(sidraw-dump src/sidraw_dump.cpp)
  target_link_libraries(sidraw-dump PRIVATE PkgConfig::SIDPLAYFP)

  add_executable(sidraw-play src/sidraw_play.cpp)
  target_link_libraries(sidraw-play PRIVATE PkgConfig::RESIDFP)

  add_executable(sid-play src/sid_play.cpp)
  target_link_libraries(sid-play PRIVATE PkgConfig::SIDPLAYFP)
endif()

foreach(tgt sidraw-dump sidraw-play sid-play)
  target_compile_options(${tgt} PRIVATE -Wall -Wextra -Wpedantic)
endforeach()

install(TARGETS sidraw-dump sidraw-play sid-play RUNTIME DESTINATION bin)
