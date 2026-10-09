#include "jobmodel.h"

#include <QFileInfo>

JobModel::JobModel(QObject *parent) : QAbstractListModel(parent) {}

int JobModel::rowCount(const QModelIndex &parent) const {
    return parent.isValid() ? 0 : int(m_jobs.size());
}

QVariant JobModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= m_jobs.size())
        return {};
    const Job &job = m_jobs.at(index.row());
    switch (role) {
    case IdRole: return job.id;
    case ImageUrlRole: return job.imagePath.isEmpty() ? QUrl() : QUrl::fromLocalFile(job.imagePath);
    case NameRole: return displayName(job);
    case StateRole: return stateName(job.state);
    case StageRole: return job.stage;
    case ProgressRole: return progressOf(job);
    case GlbUrlRole: return job.glbPath.isEmpty() ? QUrl() : QUrl::fromLocalFile(job.glbPath);
    case DetailRole: return job.detail;
    case CreatedRole: return job.created;
    case RotationRole: return job.rotation;
    case HeightMmRole: return job.heightMm;
    case HasImageRole: return !job.imagePath.isEmpty();
    }
    return {};
}

QHash<int, QByteArray> JobModel::roleNames() const {
    return {
        {IdRole, "jobId"},
        {ImageUrlRole, "imageUrl"},
        {NameRole, "name"},
        {StateRole, "jobState"},
        {StageRole, "stage"},
        {ProgressRole, "progress"},
        {GlbUrlRole, "glbUrl"},
        {DetailRole, "detail"},
        {CreatedRole, "created"},
        {RotationRole, "orientation"},
        {HeightMmRole, "heightMm"},
        {HasImageRole, "hasImage"},
    };
}

void JobModel::append(const Job &job) {
    const int row = int(m_jobs.size());
    beginInsertRows(QModelIndex(), row, row);
    m_jobs.append(job);
    endInsertRows();
    emit countChanged();
}

void JobModel::reset(const QList<Job> &jobs) {
    beginResetModel();
    m_jobs = jobs;
    endResetModel();
    emit countChanged();
}

void JobModel::removeAt(int row) {
    if (row < 0 || row >= m_jobs.size())
        return;
    beginRemoveRows(QModelIndex(), row, row);
    m_jobs.removeAt(row);
    endRemoveRows();
    emit countChanged();
}

int JobModel::rowOf(const QString &id) const {
    for (int row = 0; row < m_jobs.size(); ++row) {
        if (m_jobs.at(row).id == id)
            return row;
    }
    return -1;
}

bool JobModel::hasPendingWork() const {
    for (const Job &job : m_jobs) {
        if (job.state == Job::State::Queued || job.state == Job::State::Running)
            return true;
    }
    return false;
}

QString JobModel::stateName(Job::State state) {
    switch (state) {
    case Job::State::Queued: return QStringLiteral("queued");
    case Job::State::Running: return QStringLiteral("running");
    case Job::State::Done: return QStringLiteral("done");
    case Job::State::Failed: return QStringLiteral("failed");
    case Job::State::Cancelled: return QStringLiteral("cancelled");
    }
    return {};
}

Job::State JobModel::stateFromName(const QString &name) {
    for (Job::State state : {Job::State::Queued, Job::State::Running, Job::State::Done,
                             Job::State::Failed, Job::State::Cancelled}) {
        if (stateName(state) == name)
            return state;
    }
    return Job::State::Cancelled;
}

QString JobModel::displayName(const Job &job) {
    if (!job.glbPath.isEmpty())
        return QFileInfo(job.glbPath).completeBaseName();
    const QString name = QFileInfo(job.imagePath).fileName();
    return job.seed == 42 ? name : QStringLiteral("%1 · take %2").arg(name).arg(job.seed);
}

double JobModel::progressOf(const Job &job) {
    if (job.state == Job::State::Done)
        return 1.0;
    if (job.state != Job::State::Running || job.total <= 0)
        return -1.0;
    return qBound(0.0, double(job.step) / job.total, 1.0);
}
