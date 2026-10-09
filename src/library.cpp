#include "library.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>

namespace Library {

QString defaultPath() {
    // GenericDataLocation: AppDataLocation would nest organisation and app
    // name (~/.local/share/omamesh/omamesh).
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
        + QStringLiteral("/omamesh/library.json");
}

QJsonArray toJson(const QList<Job> &jobs) {
    QJsonArray array;
    for (const Job &job : jobs) {
        Job::State state = job.state;
        QString detail = job.detail;
        if (state == Job::State::Queued || state == Job::State::Running) {
            state = Job::State::Cancelled;
            detail = QStringLiteral("Stopped when omamesh closed");
        }
        const QQuaternion &r = job.rotation;
        QJsonObject object{
            {QStringLiteral("image"), job.imagePath},
            {QStringLiteral("glb"), job.glbPath},
            {QStringLiteral("seed"), job.seed},
            {QStringLiteral("quality"), job.quality},
            {QStringLiteral("state"), JobModel::stateName(state)},
            {QStringLiteral("detail"), detail},
            {QStringLiteral("created"), job.created.toString(Qt::ISODate)},
            {QStringLiteral("rotation"), QJsonArray{r.scalar(), r.x(), r.y(), r.z()}},
        };
        if (job.heightMm > 0)
            object.insert(QStringLiteral("heightMm"), job.heightMm);
        array.append(object);
    }
    return array;
}

QList<Job> fromJson(const QJsonArray &array) {
    QList<Job> jobs;
    for (const QJsonValue &value : array) {
        const QJsonObject object = value.toObject();
        Job job;
        job.imagePath = object.value(QStringLiteral("image")).toString();
        job.glbPath = object.value(QStringLiteral("glb")).toString();
        job.seed = object.value(QStringLiteral("seed")).toInt(42);
        job.quality = object.value(QStringLiteral("quality")).toString();
        job.state = JobModel::stateFromName(object.value(QStringLiteral("state")).toString());
        job.detail = object.value(QStringLiteral("detail")).toString();
        job.created = QDateTime::fromString(object.value(QStringLiteral("created")).toString(),
                                            Qt::ISODate);
        const QJsonArray r = object.value(QStringLiteral("rotation")).toArray();
        if (r.size() == 4)
            job.rotation = QQuaternion(float(r[0].toDouble()), float(r[1].toDouble()),
                                       float(r[2].toDouble()), float(r[3].toDouble()));
        job.heightMm = object.value(QStringLiteral("heightMm")).toDouble();

        const bool hasImage = !job.imagePath.isEmpty() && QFileInfo::exists(job.imagePath);
        const bool hasModel = !job.glbPath.isEmpty() && QFileInfo::exists(job.glbPath);
        if (!hasImage)
            job.imagePath.clear();
        if (job.state == Job::State::Done && !hasModel) {
            if (!hasImage)
                continue;
            job.state = Job::State::Cancelled;
            job.glbPath.clear();
            job.detail = QStringLiteral("The model file is missing; Try again makes it anew");
        }
        if (job.state != Job::State::Done && !hasImage)
            continue;
        jobs.append(job);
    }
    return jobs;
}

QList<Job> load(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return fromJson(QJsonDocument::fromJson(file.readAll()).array());
}

bool save(const QString &path, const QList<Job> &jobs) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(QJsonDocument(toJson(jobs)).toJson());
    return file.commit();
}

}
