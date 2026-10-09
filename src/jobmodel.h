#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QList>
#include <QQuaternion>
#include <QUrl>

// One dropped image and what has happened to it.
struct Job {
    enum class State { Queued, Running, Done, Failed, Cancelled };

    QString id;
    QString imagePath;
    int seed = 42;
    QString quality;
    State state = State::Queued;
    QString stage;
    int step = 0;
    int total = 0;
    QString glbPath;
    QString detail;
    QDateTime created;
    // How the user turned the model upright, applied in the viewer and on export.
    QQuaternion rotation;
    // Real height in millimetres for printing; 0 means not set.
    double heightMm = 0;
};

class JobModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
    enum Role {
        IdRole = Qt::UserRole + 1,
        ImageUrlRole,
        NameRole,
        StateRole,
        StageRole,
        ProgressRole,
        GlbUrlRole,
        DetailRole,
        CreatedRole,
        RotationRole,
        HeightMmRole,
        HasImageRole,
    };

    explicit JobModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void append(const Job &job);
    void reset(const QList<Job> &jobs);
    const QList<Job> &all() const { return m_jobs; }
    void removeAt(int row);
    int rowOf(const QString &id) const;
    const Job &at(int row) const { return m_jobs.at(row); }
    // Applies `change` to the job and tells the views which row moved.
    template <typename F> void update(int row, F change) {
        if (row < 0 || row >= m_jobs.size())
            return;
        change(m_jobs[row]);
        emit dataChanged(index(row), index(row));
    }
    bool hasPendingWork() const;

    static QString stateName(Job::State state);
    static Job::State stateFromName(const QString &name);
    // What the list shows: the model file's name once there is one.
    static QString displayName(const Job &job);
    // 0..1 for a stage with steps, -1 while a stage has no step count.
    static double progressOf(const Job &job);

signals:
    void countChanged();

private:
    QList<Job> m_jobs;
};
