/**
   @file hingesensor.cpp
   @brief HingeSensor

   <p>
   Copyright (C) 2016 Canonical LTD.

   @author Lorn Potter <lorn.potter@canonical.com>

   This file is part of Sensorfw.

   Sensord is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License
   version 2.1 as published by the Free Software Foundation.

   Sensord is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with Sensord.  If not, see <http://www.gnu.org/licenses/>.
   </p>
 */

#include "hingesensor.h"

#include "sensormanager.h"
#include "bin.h"
#include "bufferreader.h"

HingeSensorChannel::HingeSensorChannel(const QString& id) :
        AbstractSensorChannel(id),
        DataEmitter<TimedUnsigned>(1),
        previousValue_(0,0)
{
    SensorManager& sm = SensorManager::instance();

    hingeAdaptor_ = sm.requestDeviceAdaptor("hingeadaptor");
    if (!hingeAdaptor_) {
        setValid(false);
        return;
    }

    hingeReader_ = new BufferReader<TimedUnsigned>(1);

    outputBuffer_ = new RingBuffer<TimedUnsigned>(1);

    // Create buffers for filter chain
    filterBin_ = new Bin;

    filterBin_->add(hingeReader_, "hinge");
    filterBin_->add(outputBuffer_, "buffer");

    filterBin_->join("hinge", "source", "buffer", "sink");

    // Join datasources to the chain
    connectToSource(hingeAdaptor_, "hinge", hingeReader_);

    marshallingBin_ = new Bin;
    marshallingBin_->add(this, "sensorchannel");

    outputBuffer_->join(this);

    setDescription("ambient hinge in pascals");
    setRangeSource(hingeAdaptor_);
    addStandbyOverrideSource(hingeAdaptor_);
    setIntervalSource(hingeAdaptor_);

    setValid(true);
}

HingeSensorChannel::~HingeSensorChannel()
{
    if (isValid()) {
        SensorManager& sm = SensorManager::instance();

        disconnectFromSource(hingeAdaptor_, "hinge", hingeReader_);

        sm.releaseDeviceAdaptor("hingeadaptor");

        delete hingeReader_;
        delete outputBuffer_;
        delete marshallingBin_;
        delete filterBin_;
    }
}

bool HingeSensorChannel::start()
{
    sensordLogD() << id() << "Starting HingeSensorChannel";

    if (AbstractSensorChannel::start()) {
        marshallingBin_->start();
        filterBin_->start();
        hingeAdaptor_->startSensor();
    }
    return true;
}

bool HingeSensorChannel::stop()
{
    sensordLogD() << id() << "Stopping HingeSensorChannel";

    if (AbstractSensorChannel::stop()) {
        hingeAdaptor_->stopSensor();
        filterBin_->stop();
        marshallingBin_->stop();
    }
    return true;
}

void HingeSensorChannel::emitData(const TimedUnsigned& value)
{
    if (value.value_ != previousValue_.value_) {
        previousValue_.value_ = value.value_;

        writeToClients((const void*)(&value), sizeof(value));
    }
}
