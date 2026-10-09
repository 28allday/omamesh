#pragma once

#include <QJsonArray>
#include <QList>
#include <QString>

#include "jobmodel.h"

// The list of models, kept between runs as JSON. Jobs that were still being
// made when the app closed come back as stopped, so they can be tried again.
namespace Library {

QString defaultPath();

QJsonArray toJson(const QList<Job> &jobs);
// Drops entries whose files have all gone; a model whose .glb went missing but
// whose photo is still there comes back as stopped, ready to make again.
QList<Job> fromJson(const QJsonArray &array);

QList<Job> load(const QString &path);
bool save(const QString &path, const QList<Job> &jobs);

}
