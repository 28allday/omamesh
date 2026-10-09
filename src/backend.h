#pragma once

#include <QHash>
#include <QObject>
#include <QSortFilterProxyModel>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <QVector3D>

#include "exporter.h"
#include "glbinfo.h"
#include "jobmodel.h"

class Engine;
class PortalFileChooser;

// The one object QML talks to. Everything that touches the filesystem, a
// subprocess or D-Bus lives behind here; QML only reads properties, calls
// invokables and reacts to signals. Jobs are addressed by their id, so the
// sorted, filtered list in the sidebar can never act on the wrong one.
class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(JobModel *jobs READ jobs CONSTANT)
    Q_PROPERTY(QSortFilterProxyModel *visibleJobs READ visibleJobs CONSTANT)
    Q_PROPERTY(QString filter READ filter WRITE setFilter NOTIFY filterChanged)
    Q_PROPERTY(QString engineState READ engineState NOTIFY engineChanged)
    Q_PROPERTY(QString engineMessage READ engineMessage NOTIFY engineChanged)
    Q_PROPERTY(QString quality READ quality WRITE setQuality NOTIFY qualityChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool exporting READ exporting NOTIFY exportingChanged)
    Q_PROPERTY(bool canExport READ canExport CONSTANT)

public:
    // `libraryPath` is where the list is kept between runs; empty means the
    // standard place (~/.local/share/omamesh/library.json).
    explicit Backend(QObject *parent = nullptr, const QString &libraryPath = QString());
    ~Backend() override;

    JobModel *jobs() { return &m_jobs; }
    QSortFilterProxyModel *visibleJobs() { return &m_visible; }
    QString filter() const { return m_filter; }
    void setFilter(const QString &filter);
    QString engineState() const;
    QString engineMessage() const;
    QString quality() const { return m_quality; }
    void setQuality(const QString &quality);
    QString status() const { return m_status; }
    bool busy() const { return m_busy; }
    bool exporting() const { return m_exporter.busy(); }
    bool canExport() const;

    // Pure helpers live here as statics so the tests can reach them without a
    // window, an engine or a desktop.
    static bool isImageFile(const QString &path);
    static bool isModelFile(const QString &path);
    static bool isQuality(const QString &quality);
    static QStringList blenderArguments(const QString &glbPath);
    // The photo a model was made from: same folder, same name minus "-seedN".
    static QString imageFor(const QString &glbPath);
    // The size of the model's box once turned by `rotation`.
    static QVector3D rotatedExtent(const QVector3D &min, const QVector3D &max,
                                   const QQuaternion &rotation);
    // A usable file name from what the user typed, or empty if there's none.
    static QString cleanName(const QString &name);
    static QString formatBytes(qint64 bytes);
    // `stem.suffix` in `dir`, or `stem-2.suffix` and so on if that's taken.
    static QString freePath(const QString &dir, const QString &stem, const QString &suffix);
    // An unused non-default seed, checking both jobs and files beside the photo.
    // Starts at `firstSeed` and scans forward; -1 if every seed is taken.
    static int freeSeed(const QString &imagePath, const QList<Job> &jobs, int firstSeed);
    // How much to scale glTF units by for an export at `heightMm`.
    static double exportScale(const QString &format, double heightMm, double modelHeight);

    // Where a job sits in the sorted, filtered list, or -1 if filtered out.
    Q_INVOKABLE int visibleRow(const QString &id) const;
    Q_INVOKABLE void openDialog();
    Q_INVOKABLE void open(const QUrl &url);
    // Images get queued, .glb models join the list as they are. Returns how
    // many of the urls were used.
    Q_INVOKABLE int addUrls(const QVariantList &urls);
    Q_INVOKABLE void remove(const QString &id);
    Q_INVOKABLE bool moveToBin(const QString &id);
    Q_INVOKABLE bool rename(const QString &id, const QString &name);
    Q_INVOKABLE void cancel(const QString &id);
    Q_INVOKABLE void retry(const QString &id);
    Q_INVOKABLE void newTake(const QString &id);
    Q_INVOKABLE void openInBlender(const QString &id);
    Q_INVOKABLE void showInFolder(const QString &id);
    Q_INVOKABLE void restartEngine();

    // Turns the model a quarter (or any) turn about "x", "y" or "z".
    Q_INVOKABLE void rotate(const QString &id, const QString &axis, double degrees);
    Q_INVOKABLE void resetOrientation(const QString &id);
    Q_INVOKABLE void setHeightMm(const QString &id, double heightMm);
    // Faces, vertices, textures, file size and dimensions, ready to show.
    Q_INVOKABLE QVariantMap info(const QString &id);
    // Asks where to save, then exports in the background.
    Q_INVOKABLE void exportModel(const QString &id, const QString &format, double ratio, int texture);
    // Where a snapshot of the view should go, next to the model.
    Q_INVOKABLE QString snapshotPath(const QString &id) const;
    Q_INVOKABLE void snapshotSaved(const QString &path, bool ok);

signals:
    void filterChanged();
    void engineChanged();
    void qualityChanged();
    void statusChanged();
    void busyChanged();
    void exportingChanged();
    void jobAdded(const QString &id);
    void jobFinished(const QString &id);
    void exportFinished(bool ok, const QString &message);
    void failed(const QString &message);

private:
    QString queue(const QString &imagePath, int seed);
    QString addModel(const QString &glbPath);
    void submit(int row);
    void handleEvent(const QJsonObject &event);
    void failPending(const QString &message);
    void refreshBusy();
    void setStatus(const QString &status);
    void scheduleSave();
    void saveNow();
    QString nextId() { return QString::number(m_nextId++); }
    const GlbInfo &glbInfo(const QString &path);

    PortalFileChooser *m_chooser;
    PortalFileChooser *m_saver;
    Engine *m_engine;
    Exporter m_exporter;
    JobModel m_jobs;
    QSortFilterProxyModel m_visible;
    QString m_libraryPath;
    QTimer m_saveTimer;
    QString m_filter;
    QString m_quality;
    QString m_status;
    bool m_busy = false;
    int m_nextId = 1;

    struct PendingExport {
        QString id;
        ExportOptions options;
    };
    PendingExport m_pendingExport;

    struct CachedInfo {
        QDateTime modified;
        GlbInfo info;
    };
    QHash<QString, CachedInfo> m_info;
};
