cmake_minimum_required(VERSION 3.20)
project(yolo-board LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# ── Qt ──────────────────────────────────────────────────────────────────────
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Quick QuickWidgets Qml)

# ── logos-cpp-sdk ────────────────────────────────────────────────────────────
if(NOT LOGOS_CPP_SDK_ROOT)
    set(LOGOS_CPP_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../logos-cpp-sdk")
endif()

# ── Plugin target ────────────────────────────────────────────────────────────
set(PLUGIN_TARGET yolo_board_plugin)

qt_add_plugin(${PLUGIN_TARGET} CLASS_NAME YoloBoardPlugin)

target_sources(${PLUGIN_TARGET} PRIVATE
    src/yolo_board_plugin.cpp
    src/YoloBoardBackend.cpp
)

qt_add_resources(${PLUGIN_TARGET} "yolo_board_qml"
    PREFIX "/"
    BASE "src/qml"
    FILES
        src/qml/Main.qml
)

target_include_directories(${PLUGIN_TARGET} PRIVATE
    ${LOGOS_CPP_SDK_ROOT}/include
    ${LOGOS_CPP_SDK_ROOT}/include/cpp
    ${LOGOS_CPP_SDK_ROOT}/include/core
    ${CMAKE_CURRENT_SOURCE_DIR}/interfaces
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(${PLUGIN_TARGET} PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Quick
    Qt6::QuickWidgets
    Qt6::Qml
    ${LOGOS_CPP_SDK_ROOT}/lib/liblogos_sdk.a
)

# ── OS rpath ────────────────────────────────────────────────────────────────
if(APPLE)
    set_target_properties(${PLUGIN_TARGET} PROPERTIES
        BUILD_RPATH "@loader_path"
        INSTALL_RPATH "@loader_path"
    )
elseif(UNIX)
    set_target_properties(${PLUGIN_TARGET} PROPERTIES
        BUILD_RPATH "$ORIGIN"
        INSTALL_RPATH "$ORIGIN"
    )
endif()

# ── Install ──────────────────────────────────────────────────────────────────
install(TARGETS ${PLUGIN_TARGET}
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
)
