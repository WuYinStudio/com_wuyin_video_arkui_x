cmake_minimum_required(VERSION 3.5.0)
project(glassrender)

set(NATIVE_LIB_NAME libglass)

add_library(${NATIVE_LIB_NAME} SHARED
    napi_init.cpp
    napi_init.h
    glass_render.cpp
    glass_render.h
    glass_shader.h
    egl_manager.cpp
    egl_manager.h
)

target_include_directories(${NATIVE_LIB_NAME} PRIVATE
    ${NATIVERENDER_ROOT_PATH}/include
)

target_link_libraries(${NATIVE_LIB_NAME}
    libace_napi.z.so
  libace_ndk.z.so
    libnative_window.so
    libnative_image.so
    libhilog_ndk.z.so
    EGL
    GLESv3
)

set_target_properties(${NATIVE_LIB_NAME} PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
)
