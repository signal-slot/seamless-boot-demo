cmake_minimum_required(VERSION 3.21)
project(astra-demo VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Quick Gui Qml)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(astra-demo
    main.cpp
)

file(GLOB IMAGE_FILES CONFIGURE_DEPENDS "qml/images/*.png")

# Flatten resource paths: every file sits directly under /qt/qml/AstraDemo/
# (the qml/ prefix is stripped), so QML sees images/sat.png etc.
set_source_files_properties(qml/Main.qml          PROPERTIES QT_RESOURCE_ALIAS Main.qml)
set_source_files_properties(qml/GroundControl.qml PROPERTIES QT_RESOURCE_ALIAS GroundControl.qml)
set_source_files_properties(qml/OrbitTrace.js     PROPERTIES QT_RESOURCE_ALIAS OrbitTrace.js)
foreach(img ${IMAGE_FILES})
    file(RELATIVE_PATH alias "${CMAKE_CURRENT_SOURCE_DIR}/qml" "${img}")
    set_source_files_properties("${img}" PROPERTIES QT_RESOURCE_ALIAS "${alias}")
endforeach()

qt_add_qml_module(astra-demo
    URI AstraDemo
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/GroundControl.qml
        qml/OrbitTrace.js
    RESOURCES
        ${IMAGE_FILES}
)

target_link_libraries(astra-demo PRIVATE Qt6::Quick Qt6::Gui Qt6::Qml)

# libdrm: read back Plymouth's frozen frame from the CRTC at startup so the
# QML splash continues the sweep where Plymouth froze (see main.cpp).
# Optional — without it (or on desktop) the readback compiles out / no-ops.
find_package(PkgConfig QUIET)
if(PKG_CONFIG_FOUND)
    pkg_check_modules(LIBDRM IMPORTED_TARGET libdrm)
    if(LIBDRM_FOUND)
        target_link_libraries(astra-demo PRIVATE PkgConfig::LIBDRM)
    endif()
endif()
