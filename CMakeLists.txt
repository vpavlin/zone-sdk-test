cmake_minimum_required(VERSION 3.20)
project(yolo-board LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Framework build (Basecamp plugin) ─────────────────────────────────────────
if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)

    logos_module(
        NAME yolo_board
        SOURCES
            src/YoloBoardInterface.h
            src/YoloBoardPlugin.h
            src/YoloBoardPlugin.cpp
            src/YoloBoardBackend.h
            src/YoloBoardBackend.cpp
        EXTERNAL_LIBS zone_sequencer_rs
        FIND_PACKAGES OpenSSL
        LINK_LIBRARIES OpenSSL::Crypto
    )

# ── Manual build (standalone app + plugin fallback) ──────────────────────────
else()
    set(CMAKE_AUTOMOC ON)

    find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Quick QuickWidgets Qml Concurrent Network)
    find_package(OpenSSL REQUIRED)

    if(NOT LOGOS_CPP_SDK_ROOT)
        set(LOGOS_CPP_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../logos-cpp-sdk")
    endif()

    if(NOT ZONE_SEQUENCER_RS_LIB_DIR)
        set(ZONE_SEQUENCER_RS_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../zone-sequencer-rs/target/release")
    endif()

    if(APPLE)
        set(DYLIB_EXT ".dylib")
    else()
        set(DYLIB_EXT ".so")
    endif()

    set(QML_SOURCES src/qml/Main.qml)

    # ── Basecamp plugin target ────────────────────────────────────────────────
    set(PLUGIN_TARGET yolo_board_plugin)

    qt_add_plugin(${PLUGIN_TARGET} CLASS_NAME YoloBoardPlugin)

    target_sources(${PLUGIN_TARGET} PRIVATE
        src/YoloBoardPlugin.cpp
        src/YoloBoardBackend.cpp
    )

    qt_add_resources(${PLUGIN_TARGET} "yolo_board_qml"
        PREFIX "/qml"
        BASE "src/qml"
        FILES ${QML_SOURCES}
    )

    target_include_directories(${PLUGIN_TARGET} PRIVATE
        ${LOGOS_CPP_SDK_ROOT}/include
        ${LOGOS_CPP_SDK_ROOT}/include/cpp
        ${LOGOS_CPP_SDK_ROOT}/include/core
        ${CMAKE_CURRENT_SOURCE_DIR}/src
    )

    target_compile_definitions(${PLUGIN_TARGET} PRIVATE LOGOS_CORE_AVAILABLE)

    target_link_directories(${PLUGIN_TARGET} PRIVATE "${ZONE_SEQUENCER_RS_LIB_DIR}")

    target_link_libraries(${PLUGIN_TARGET} PRIVATE
        Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Quick Qt6::QuickWidgets
        Qt6::Qml Qt6::Concurrent Qt6::Network
        ${LOGOS_CPP_SDK_ROOT}/lib/liblogos_sdk.a
        zone_sequencer_rs
    )

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

    # ── Standalone app target ─────────────────────────────────────────────────
    set(APP_TARGET yolo_board_app)

    qt_add_executable(${APP_TARGET}
        src/main.cpp
        src/YoloBoardBackend.cpp
    )

    qt_add_resources(${APP_TARGET} "yolo_board_app_qml"
        PREFIX "/qml"
        BASE "src/qml"
        FILES ${QML_SOURCES}
    )

    target_include_directories(${APP_TARGET} PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
    )

    target_link_directories(${APP_TARGET} PRIVATE "${ZONE_SEQUENCER_RS_LIB_DIR}")

    target_link_libraries(${APP_TARGET} PRIVATE
        Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Quick Qt6::Qml
        Qt6::Concurrent Qt6::Network
        zone_sequencer_rs
        OpenSSL::Crypto
    )

    if(APPLE)
        set_target_properties(${APP_TARGET} PROPERTIES
            BUILD_RPATH "@loader_path"
            INSTALL_RPATH "@loader_path"
        )
    elseif(UNIX)
        set_target_properties(${APP_TARGET} PROPERTIES
            BUILD_RPATH "$ORIGIN"
            INSTALL_RPATH "$ORIGIN"
        )
    endif()

    # ── Install ───────────────────────────────────────────────────────────────
    install(TARGETS ${PLUGIN_TARGET}
        LIBRARY DESTINATION lib
        RUNTIME DESTINATION bin
    )
    install(TARGETS ${APP_TARGET}
        RUNTIME DESTINATION bin
    )
    install(FILES "${ZONE_SEQUENCER_RS_LIB_DIR}/libzone_sequencer_rs${DYLIB_EXT}"
        DESTINATION lib
    )
endif()
