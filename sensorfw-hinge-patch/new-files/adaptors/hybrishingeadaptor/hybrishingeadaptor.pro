TARGET       = hybrishingeadaptor

HEADERS += hybrishingeadaptor.h \
           hybrishingeadaptorplugin.h

SOURCES += hybrishingeadaptor.cpp \
           hybrishingeadaptorplugin.cpp
LIBS+= -L../../core -lhybrissensorfw-qt$${QT_MAJOR_VERSION}

include( ../adaptor-config.pri )
config_hybris {
    PKGCONFIG += android-headers
}
