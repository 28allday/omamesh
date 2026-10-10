QT += core gui qml quick quickcontrols2 dbus

CONFIG += c++17 release
TARGET = omamesh
VERSION = 0.2.4
DEFINES += OMAMESH_VERSION=\\\"$$VERSION\\\"
TEMPLATE = app

HEADERS += \
    src/backend.h \
    src/engine.h \
    src/exporter.h \
    src/glbinfo.h \
    src/library.h \
    src/scenetools.h \
    src/filepicker.h \
    src/jobmodel.h \
    src/theme.h

SOURCES += \
    src/main.cpp \
    src/backend.cpp \
    src/engine.cpp \
    src/exporter.cpp \
    src/glbinfo.cpp \
    src/library.cpp \
    src/scenetools.cpp \
    src/filepicker.cpp \
    src/jobmodel.cpp \
    src/theme.cpp

RESOURCES += src/resources.qrc
