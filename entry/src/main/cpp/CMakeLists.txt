cmake_minimum_required(VERSION 3.4.1)
project(mnnchat)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

add_definitions("-DOHOS_PLATFORM -DLOG_TAG=\"MnnChatNative\"")

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

# MNN include paths (configured when MNN SDK is placed in libs or third_party)
if(EXISTS ${NATIVERENDER_ROOT_PATH}/third_party/mnn/include)
    include_directories(${NATIVERENDER_ROOT_PATH}/third_party/mnn/include)
    include_directories(${NATIVERENDER_ROOT_PATH}/third_party/mnn/include/transformers)
    add_definitions("-DHAVE_MNN_SDK=1")
    link_directories(${NATIVERENDER_ROOT_PATH}/third_party/mnn/lib/${OHOS_ARCH})
endif()

set(SOURCE_FILES
    mnn_engine_wrapper.cpp
    mnn_chat_napi.cpp
)

add_library(mnnchat SHARED ${SOURCE_FILES})

# Link OpenHarmony NAPI & HiLog libraries
target_link_libraries(mnnchat PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
)

# Link MNN libraries if present
if(EXISTS ${NATIVERENDER_ROOT_PATH}/third_party/mnn/lib/${OHOS_ARCH}/libMNN.so)
    target_link_libraries(mnnchat PUBLIC
        MNN
        MNN_Express
        llm
    )
endif()
