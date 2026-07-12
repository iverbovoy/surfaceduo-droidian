/****************************************************************************
**
** Copyright (C) 2013 Jolla Ltd
**
** Copyright (C) 2017 Matti Lehtimäki
**
** $QT_BEGIN_LICENSE:LGPL$
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 2.1 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL included in the
** packaging of this file.  Please review the following information to
** ensure the GNU Lesser General Public License version 2.1 requirements
** will be met: http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include <QFile>
#include <QTextStream>

#include "hybrishingeadaptor.h"
#include "logging.h"
#include "datatypes/utils.h"
#include "config.h"

HybrisHingeAdaptor::HybrisHingeAdaptor(const QString& id) :
    HybrisAdaptor(id,SENSOR_TYPE_HINGE_ANGLE)
{
    buffer = new DeviceAdaptorRingBuffer<TimedUnsigned>(1);
    setAdaptedSensor("hinge", "Hinge angle in degrees (Surface Duo)", buffer);
    setDescription("Hybris hinge angle");
    powerStatePath = SensorFrameworkConfig::configuration()->value("hinge/powerstate_path").toByteArray();
    if (!powerStatePath.isEmpty() && !QFile::exists(powerStatePath))
    {
        sensordLogW() << NodeBase::id() << "Path does not exists: " << powerStatePath;
        powerStatePath.clear();
    }
}

HybrisHingeAdaptor::~HybrisHingeAdaptor()
{
    delete buffer;
}

bool HybrisHingeAdaptor::startSensor()
{
    if (!(HybrisAdaptor::startSensor()))
        return false;
    if (isRunning() && !powerStatePath.isEmpty())
        writeToFile(powerStatePath, "1");
    sensordLogD() << id() << "Hybris HybrisHingeAdaptor start";
    return true;
}

void HybrisHingeAdaptor::stopSensor()
{
    HybrisAdaptor::stopSensor();
    if (!isRunning() && !powerStatePath.isEmpty())
        writeToFile(powerStatePath, "0");
    sensordLogD() << id() << "Hybris HybrisHingeAdaptor stop";
}

void HybrisHingeAdaptor::processSample(const sensors_event_t& data)
{
    TimedUnsigned *d = buffer->nextSlot();
    d->timestamp_ = quint64(data.timestamp * .001);
#ifdef USE_BINDER
    d->value_ = data.u.scalar; // hinge angle in degrees (0..360)
#else
    d->value_ = data.data[0];  // hinge angle in degrees (0..360)
#endif
    buffer->commit();
    buffer->wakeUpReaders();
}
