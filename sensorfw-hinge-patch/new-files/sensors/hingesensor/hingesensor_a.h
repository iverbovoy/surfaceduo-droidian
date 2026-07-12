/**
   @file hingesensor_a.h
   @brief D-Bus adaptor for HingeSensor

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

#ifndef HINGE_SENSOR_H
#define HINGE_SENSOR_H

#include <QtDBus/QtDBus>
#include <QObject>

#include "datatypes/unsigned.h"
#include "abstractsensor_a.h"

class HingeSensorChannelAdaptor : public AbstractSensorChannelAdaptor
{
    Q_OBJECT
    Q_DISABLE_COPY(HingeSensorChannelAdaptor)
    Q_CLASSINFO("D-Bus Interface", "local.HingeSensor")
    Q_PROPERTY(Unsigned hinge READ hinge NOTIFY hingeChanged)

public:
    HingeSensorChannelAdaptor(QObject* parent);

public Q_SLOTS:
    Unsigned hinge() const;

Q_SIGNALS:
    void hingeChanged(const Unsigned& value);
};

#endif
