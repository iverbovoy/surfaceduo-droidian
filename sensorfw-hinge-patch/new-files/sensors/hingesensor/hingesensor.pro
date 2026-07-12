CONFIG      += link_pkgconfig

TARGET       = hingesensor

HEADERS += hingesensor.h   \
           hingesensor_a.h \
           hingeplugin.h

SOURCES += hingesensor.cpp   \
           hingesensor_a.cpp \
           hingeplugin.cpp

include( ../sensor-config.pri )

contextprovider {
    DEFINES += PROVIDE_CONTEXT_INFO
    PKGCONFIG += contextprovider-1.0
}

