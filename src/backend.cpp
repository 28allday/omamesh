#include "backend.h"

#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonObject>
#include <QLocale>
#include <QProcess>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <limits>

#include "engine.h"
#include "filepicker.h"
#include "library.h"

namespace {
constexpr int kDefaultSeed = 42;
constexpr int kSaveDelayMs = 300;
// STL has no units; slicers read millimetres. Without a set height a model
// would come out the size of its glTF box (about 1 mm), so give it one.
constexpr double kDefaultPrintHeightMm = 100.0;
const QStringList kImageSuffixes = {
    QStringLiteral("jpg"), QStringLiteral("jpeg"), QStringLiteral("png"),
    QStringLiteral("webp"), QStringLiteral("bmp"), QStringLiteral("tif"),
    QStringLiteral("tiff"),
};

QString outputStem(const QString &imagePath) {
    const QFileInfo image(imagePath);
    const QDir directory = image.dir();
    const QString canonical = directory.canonicalPath();
    return QDir(canonical.isEmpty() ? directory.absolutePath() : canonical)
        .filePath(image.completeBaseName());
}
}

Backend::Backend(QObject *parent, const QString &libraryPath)
    : QObject(parent),
      m_chooser(new PortalFileChooser(this)),
      m_saver(new PortalFileChooser(this)),
      m_engine(new Engine(this)),
      m_libraryPath(libraryPath.isEmpty() ? Library::defaultPath() : libraryPath) {
    m_quality = QSettings().value(QStringLiteral("quality"), QStringLiteral("standard")).toString();
    if (!isQuality(m_quality))
        m_quality = QStringLiteral("standard");

    QList<Job> saved = Library::load(m_libraryPath);
    for (Job &job : saved)
        job.id = nextId();
    m_jobs.reset(saved);

    m_visible.setSourceModel(&m_jobs);
    m_visible.setFilterRole(JobModel::NameRole);
    m_visible.setFilterCaseSensitivity(Qt::CaseInsensitive);
    m_visible.setSortRole(JobModel::CreatedRole);
    m_visible.setDynamicSortFilter(true);
    m_visible.sort(0, Qt::DescendingOrder);

    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(kSaveDelayMs);
    connect(&m_saveTimer, &QTimer::timeout, this, &Backend::saveNow);
    connect(&m_jobs, &QAbstractItemModel::rowsInserted, this, &Backend::scheduleSave);
    connect(&m_jobs, &QAbstractItemModel::rowsRemoved, this, &Backend::scheduleSave);
    connect(&m_jobs, &QAbstractItemModel::dataChanged, this, &Backend::scheduleSave);

    connect(m_chooser, &PortalFileChooser::selectedMany, this, [this](const QList<QUrl> &urls) {
        QVariantList list;
        for (const QUrl &url : urls)
            list.append(url);
        addUrls(list);
    });
    connect(m_saver, &PortalFileChooser::selected, this, [this](const QUrl &url) {
        const int row = m_jobs.rowOf(m_pendingExport.id);
        if (row < 0 || !url.isLocalFile())
            return;
        QString destination = url.toLocalFile();
        const QString suffix = QStringLiteral(".") + m_pendingExport.options.format;
        if (!destination.endsWith(suffix, Qt::CaseInsensitive))
            destination += suffix;
        setStatus(QStringLiteral("Exporting %1…").arg(QFileInfo(destination).fileName()));
        m_exporter.start(m_jobs.at(row).glbPath, destination, m_pendingExport.options);
    });
    for (PortalFileChooser *chooser : {m_chooser, m_saver}) {
        connect(chooser, &PortalFileChooser::failed, this, [this](const QString &message) {
            setStatus(message);
            emit failed(message);
        });
    }
    connect(&m_exporter, &Exporter::busyChanged, this, &Backend::exportingChanged);
    connect(&m_exporter, &Exporter::finished, this, [this](bool ok, const QString &message) {
        setStatus(message);
        emit exportFinished(ok, message);
    });
    connect(m_engine, &Engine::stateChanged, this, [this] {
        emit engineChanged();
        if (m_engine->state() == Engine::State::Failed)
            failPending(m_engine->message());
    });
    connect(m_engine, &Engine::received, this, &Backend::handleEvent);
    connect(m_engine, &Engine::lost, this, &Backend::failPending);
}

Backend::~Backend() {
    if (m_saveTimer.isActive())
        saveNow();
}

void Backend::setFilter(const QString &filter) {
    if (m_filter == filter)
        return;
    m_filter = filter;
    m_visible.setFilterFixedString(filter);
    emit filterChanged();
}

QString Backend::engineState() const {
    switch (m_engine->state()) {
    case Engine::State::Off: return QStringLiteral("off");
    case Engine::State::Loading: return QStringLiteral("loading");
    case Engine::State::Ready: return QStringLiteral("ready");
    case Engine::State::Failed: return QStringLiteral("failed");
    }
    return {};
}

QString Backend::engineMessage() const {
    return m_engine->message();
}

void Backend::setQuality(const QString &quality) {
    if (m_quality == quality || !isQuality(quality))
        return;
    m_quality = quality;
    QSettings().setValue(QStringLiteral("quality"), quality);
    emit qualityChanged();
}

bool Backend::canExport() const {
    return !QStandardPaths::findExecutable(QStringLiteral("blender")).isEmpty();
}

bool Backend::isImageFile(const QString &path) {
    const QFileInfo info(path);
    return kImageSuffixes.contains(info.suffix().toLower());
}

bool Backend::isModelFile(const QString &path) {
    return QFileInfo(path).suffix().toLower() == QLatin1String("glb");
}

bool Backend::isQuality(const QString &quality) {
    return quality == QLatin1String("draft") || quality == QLatin1String("standard")
        || quality == QLatin1String("high");
}

QStringList Backend::blenderArguments(const QString &glbPath) {
    // The path travels as an argument after `--`, never pasted into the Python.
    return {
        QStringLiteral("--python-expr"),
        QStringLiteral("import bpy, sys\n"
                       "bpy.ops.wm.read_factory_settings(use_empty=True)\n"
                       "bpy.ops.import_scene.gltf(filepath=sys.argv[sys.argv.index('--') + 1])"),
        QStringLiteral("--"),
        glbPath,
    };
}

QString Backend::imageFor(const QString &glbPath) {
    const QFileInfo model(glbPath);
    QString stem = model.completeBaseName();
    stem.remove(QRegularExpression(QStringLiteral("-seed\\d+$")));
    for (const QString &suffix : kImageSuffixes) {
        for (const QString &candidate : {suffix, suffix.toUpper()}) {
            const QString path = model.dir().filePath(stem + QLatin1Char('.') + candidate);
            if (QFileInfo::exists(path))
                return path;
        }
    }
    return {};
}

QVector3D Backend::rotatedExtent(const QVector3D &min, const QVector3D &max,
                                 const QQuaternion &rotation) {
    QVector3D lo, hi;
    for (int corner = 0; corner < 8; ++corner) {
        const QVector3D p = rotation.rotatedVector(QVector3D(corner & 1 ? max.x() : min.x(),
                                                             corner & 2 ? max.y() : min.y(),
                                                             corner & 4 ? max.z() : min.z()));
        lo = corner ? QVector3D(qMin(lo.x(), p.x()), qMin(lo.y(), p.y()), qMin(lo.z(), p.z())) : p;
        hi = corner ? QVector3D(qMax(hi.x(), p.x()), qMax(hi.y(), p.y()), qMax(hi.z(), p.z())) : p;
    }
    return hi - lo;
}

QString Backend::cleanName(const QString &name) {
    QString clean = name.trimmed();
    if (clean.endsWith(QLatin1String(".glb"), Qt::CaseInsensitive))
        clean.chop(4);
    clean.replace(QLatin1Char('/'), QLatin1Char('-'));
    clean.remove(QChar(0));
    clean = clean.trimmed();
    if (clean == QLatin1String(".") || clean == QLatin1String(".."))
        return {};
    return clean;
}

QString Backend::formatBytes(qint64 bytes) {
    return QLocale::system().formattedDataSize(bytes, 1, QLocale::DataSizeTraditionalFormat);
}

QString Backend::freePath(const QString &dir, const QString &stem, const QString &suffix) {
    const QDir folder(dir);
    QString path = folder.filePath(stem + QLatin1Char('.') + suffix);
    for (int n = 2; QFileInfo::exists(path); ++n)
        path = folder.filePath(QStringLiteral("%1-%2.%3").arg(stem).arg(n).arg(suffix));
    return path;
}

int Backend::freeSeed(const QString &imagePath, const QList<Job> &jobs, int firstSeed) {
    const QString stem = outputStem(imagePath);
    QSet<QString> reserved;
    for (const Job &job : jobs) {
        // Different image extensions (or directory symlinks) can still name
        // the same output. Reserve queued jobs before their files exist.
        if (!job.imagePath.isEmpty()) {
            const QString suffix = job.seed == kDefaultSeed ? QStringLiteral(".glb")
                : QStringLiteral("-seed%1.glb").arg(job.seed);
            reserved.insert(outputStem(job.imagePath) + suffix);
        }
    }
    const int first = qMax(1, firstSeed);
    int seed = first;
    do {
        const QString path = stem + QStringLiteral("-seed%1.glb").arg(seed);
        const QFileInfo output(path);
        if (seed != kDefaultSeed && !reserved.contains(path) && !output.exists() && !output.isSymLink())
            return seed;
        seed = seed == std::numeric_limits<int>::max() ? 1 : seed + 1;
    } while (seed != first);
    return -1;
}

double Backend::exportScale(const QString &format, double heightMm, double modelHeight) {
    const bool stl = format == QLatin1String("stl");
    if (heightMm <= 0 && !stl)
        return 1.0;  // leave glTF units alone
    if (modelHeight <= 0)
        return 1.0;
    const double mm = heightMm > 0 ? heightMm : kDefaultPrintHeightMm;
    // STL is read as millimetres; glTF and OBJ as metres.
    return mm / modelHeight * (stl ? 1.0 : 0.001);
}

int Backend::visibleRow(const QString &id) const {
    const int row = m_jobs.rowOf(id);
    return row < 0 ? -1 : m_visible.mapFromSource(m_jobs.index(row)).row();
}

void Backend::openDialog() {
    QStringList patterns;
    for (const QString &suffix : kImageSuffixes + QStringList{QStringLiteral("glb")})
        patterns << QStringLiteral("*.") + suffix << QStringLiteral("*.") + suffix.toUpper();
    m_chooser->openFile(QStringLiteral("Add images or models"), QStringLiteral("Images and models"),
                        patterns, true);
}

void Backend::open(const QUrl &url) {
    addUrls({url});
}

int Backend::addUrls(const QVariantList &urls) {
    int images = 0;
    int models = 0;
    int skipped = 0;
    for (const QVariant &value : urls) {
        const QUrl url = value.toUrl();
        const QString path = url.isLocalFile() ? url.toLocalFile() : QString();
        if (path.isEmpty() || !QFileInfo(path).isFile()) {
            ++skipped;
        } else if (isImageFile(path)) {
            queue(path, kDefaultSeed);
            ++images;
        } else if (isModelFile(path)) {
            addModel(path);
            ++models;
        } else {
            ++skipped;
        }
    }
    const int added = images + models;
    if (skipped > 0 && added == 0)
        setStatus(QStringLiteral("Only local images and .glb models can be added."));
    else if (skipped > 0)
        setStatus(QStringLiteral("Added %1, skipped %2 that weren't images or models.")
                      .arg(added).arg(skipped));
    else if (models > 0 && images == 0)
        setStatus(models == 1 ? QStringLiteral("Opened 1 model.")
                              : QStringLiteral("Opened %1 models.").arg(models));
    else if (added > 0)
        setStatus(added == 1 ? QStringLiteral("Added 1 image.")
                             : QStringLiteral("Added %1 images.").arg(added));
    return added;
}

QString Backend::queue(const QString &imagePath, int seed) {
    Job job;
    job.id = nextId();
    job.imagePath = QFileInfo(imagePath).absoluteFilePath();
    job.seed = seed;
    job.quality = m_quality;
    job.created = QDateTime::currentDateTime();
    m_jobs.append(job);
    emit jobAdded(job.id);
    submit(m_jobs.rowCount() - 1);
    return job.id;
}

QString Backend::addModel(const QString &glbPath) {
    const QString path = QFileInfo(glbPath).absoluteFilePath();
    for (const Job &existing : m_jobs.all()) {
        if (existing.glbPath == path) {
            emit jobAdded(existing.id);  // already listed: just show it
            return existing.id;
        }
    }
    Job job;
    job.id = nextId();
    job.glbPath = path;
    job.imagePath = imageFor(path);
    job.state = Job::State::Done;
    job.detail = QStringLiteral("Opened from disk");
    job.created = QDateTime::currentDateTime();
    m_jobs.append(job);
    emit jobAdded(job.id);
    return job.id;
}

void Backend::submit(int row) {
    m_jobs.update(row, [](Job &job) {
        job.state = Job::State::Queued;
        job.stage.clear();
        job.detail.clear();
        job.step = job.total = 0;
    });
    refreshBusy();
    if (!m_engine->ensureStarted(m_jobs.at(row).quality)) {
        // Repeated startup failures need not change the engine's state, so
        // stateChanged alone cannot mark newly queued/retried jobs failed.
        failPending(m_engine->message());
        return;
    }
    const Job &job = m_jobs.at(row);
    m_engine->send({
        {QStringLiteral("cmd"), QStringLiteral("generate")},
        {QStringLiteral("id"), job.id},
        {QStringLiteral("image"), job.imagePath},
        {QStringLiteral("quality"), job.quality},
        {QStringLiteral("seed"), job.seed},
    });
}

void Backend::handleEvent(const QJsonObject &event) {
    const QString kind = event.value(QStringLiteral("event")).toString();
    const QString id = event.value(QStringLiteral("id")).toString();
    const int row = m_jobs.rowOf(id);
    if (row < 0)
        return;

    if (kind == QLatin1String("progress")) {
        m_jobs.update(row, [&event](Job &job) {
            job.state = Job::State::Running;
            job.stage = event.value(QStringLiteral("stage")).toString();
            job.step = event.value(QStringLiteral("step")).toInt();
            job.total = event.value(QStringLiteral("total")).toInt();
        });
    } else if (kind == QLatin1String("done")) {
        m_jobs.update(row, [&event](Job &job) {
            job.state = Job::State::Done;
            job.glbPath = event.value(QStringLiteral("glb")).toString();
            job.stage.clear();
            job.detail = QStringLiteral("%1 s · %2 GB VRAM")
                .arg(qRound(event.value(QStringLiteral("seconds")).toDouble()))
                .arg(event.value(QStringLiteral("vram")).toDouble(), 0, 'f', 1);
        });
        emit jobFinished(id);
    } else if (kind == QLatin1String("error")) {
        m_jobs.update(row, [&event](Job &job) {
            job.state = Job::State::Failed;
            job.detail = event.value(QStringLiteral("message")).toString();
        });
    } else if (kind == QLatin1String("cancelled")) {
        m_jobs.update(row, [](Job &job) {
            job.state = Job::State::Cancelled;
            job.detail = QStringLiteral("Cancelled");
        });
    }
    refreshBusy();
}

void Backend::failPending(const QString &message) {
    for (int row = 0; row < m_jobs.rowCount(); ++row) {
        const Job::State state = m_jobs.at(row).state;
        if (state != Job::State::Queued && state != Job::State::Running)
            continue;
        m_jobs.update(row, [&message](Job &job) {
            job.state = Job::State::Failed;
            job.detail = message;
        });
    }
    refreshBusy();
}

void Backend::remove(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0)
        return;
    cancel(id);
    m_jobs.removeAt(row);
    refreshBusy();
}

bool Backend::moveToBin(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0 || m_jobs.at(row).glbPath.isEmpty())
        return false;
    const QString path = m_jobs.at(row).glbPath;
    if (QFileInfo::exists(path) && !QFile::moveToTrash(path)) {
        setStatus(QStringLiteral("Couldn't move %1 to the bin.").arg(QFileInfo(path).fileName()));
        return false;
    }
    m_info.remove(path);
    m_jobs.removeAt(row);
    setStatus(QStringLiteral("Moved %1 to the bin.").arg(QFileInfo(path).fileName()));
    return true;
}

bool Backend::rename(const QString &id, const QString &name) {
    const int row = m_jobs.rowOf(id);
    const QString clean = cleanName(name);
    if (row < 0 || clean.isEmpty() || m_jobs.at(row).glbPath.isEmpty())
        return false;
    const QFileInfo current(m_jobs.at(row).glbPath);
    const QString target = current.dir().filePath(clean + QStringLiteral(".glb"));
    if (target == current.absoluteFilePath())
        return true;
    if (QFileInfo::exists(target)) {
        setStatus(QStringLiteral("There's already a %1 there.").arg(QFileInfo(target).fileName()));
        return false;
    }
    if (!QFile::rename(current.absoluteFilePath(), target)) {
        setStatus(QStringLiteral("Couldn't rename %1.").arg(current.fileName()));
        return false;
    }
    m_info.remove(current.absoluteFilePath());
    m_jobs.update(row, [&target](Job &job) { job.glbPath = target; });
    setStatus(QStringLiteral("Renamed to %1.").arg(QFileInfo(target).fileName()));
    return true;
}

void Backend::cancel(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0)
        return;
    const Job &job = m_jobs.at(row);
    if (job.state != Job::State::Queued && job.state != Job::State::Running)
        return;
    m_engine->send({{QStringLiteral("cmd"), QStringLiteral("cancel")}, {QStringLiteral("id"), job.id}});
    m_jobs.update(row, [](Job &job) { job.detail = QStringLiteral("Cancelling…"); });
}

void Backend::retry(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0 || m_jobs.at(row).imagePath.isEmpty())
        return;
    const Job::State state = m_jobs.at(row).state;
    if (state == Job::State::Queued || state == Job::State::Running)
        return;
    // A fresh engine id, so late events from the old attempt can't land here.
    const QString fresh = nextId();
    m_jobs.update(row, [this, &fresh](Job &job) {
        job.id = fresh;
        job.quality = m_quality;
    });
    submit(row);
}

void Backend::newTake(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0 || m_jobs.at(row).imagePath.isEmpty())
        return;
    const QString imagePath = m_jobs.at(row).imagePath;
    // Prefer short, random seeds; scan past collisions rather than overwriting
    // a previous take or reusing a seed reserved by another queued job.
    const int seed = freeSeed(imagePath, m_jobs.all(), QRandomGenerator::global()->bounded(1, 10000));
    if (seed < 0) {
        setStatus(QStringLiteral("No unused seed is available for another take."));
        return;
    }
    queue(imagePath, seed);
}

void Backend::openInBlender(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0 || m_jobs.at(row).glbPath.isEmpty())
        return;
    const QString blender = QStandardPaths::findExecutable(QStringLiteral("blender"));
    if (blender.isEmpty()) {
        setStatus(QStringLiteral("Blender isn't installed."));
        return;
    }
    if (!QProcess::startDetached(blender, blenderArguments(m_jobs.at(row).glbPath)))
        setStatus(QStringLiteral("Blender could not start."));
}

void Backend::showInFolder(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0)
        return;
    const Job &job = m_jobs.at(row);
    const QString path = job.glbPath.isEmpty() ? job.imagePath : job.glbPath;
    QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(path).absolutePath()));
}

void Backend::restartEngine() {
    m_engine->stop();
    QStringList retryIds;
    for (const Job &job : m_jobs.all()) {
        if (job.state == Job::State::Failed && !job.imagePath.isEmpty())
            retryIds.append(job.id);
    }
    if (retryIds.isEmpty()) {
        m_engine->ensureStarted(m_quality);
        return;
    }
    for (const QString &id : retryIds)
        retry(id);
}

void Backend::rotate(const QString &id, const QString &axis, double degrees) {
    const int row = m_jobs.rowOf(id);
    if (row < 0)
        return;
    const QVector3D around = axis == QLatin1String("x") ? QVector3D(1, 0, 0)
                           : axis == QLatin1String("y") ? QVector3D(0, 1, 0)
                                                        : QVector3D(0, 0, 1);
    const QQuaternion turn = QQuaternion::fromAxisAndAngle(around, float(degrees));
    m_jobs.update(row, [&turn](Job &job) { job.rotation = (turn * job.rotation).normalized(); });
}

void Backend::resetOrientation(const QString &id) {
    m_jobs.update(m_jobs.rowOf(id), [](Job &job) { job.rotation = QQuaternion(); });
}

void Backend::setHeightMm(const QString &id, double heightMm) {
    m_jobs.update(m_jobs.rowOf(id), [heightMm](Job &job) { job.heightMm = qMax(0.0, heightMm); });
}

const GlbInfo &Backend::glbInfo(const QString &path) {
    const QDateTime modified = QFileInfo(path).lastModified();
    auto it = m_info.find(path);
    if (it == m_info.end() || it->modified != modified)
        it = m_info.insert(path, {modified, GlbInfo::read(path)});
    return it->info;
}

QVariantMap Backend::info(const QString &id) {
    const int row = m_jobs.rowOf(id);
    if (row < 0 || m_jobs.at(row).glbPath.isEmpty())
        return {{QStringLiteral("ok"), false}};
    const Job &job = m_jobs.at(row);
    const GlbInfo &glb = glbInfo(job.glbPath);
    if (!glb.ok)
        return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), glb.error}};

    const QLocale locale = QLocale::system();
    QStringList textures;
    for (const QSize &size : glb.textures)
        textures << QStringLiteral("%1 × %2").arg(size.width()).arg(size.height());
    const QVector3D extent = rotatedExtent(glb.min, glb.max, job.rotation);
    QString dimensions;
    if (job.heightMm > 0 && extent.y() > 0) {
        const double mm = job.heightMm / extent.y();
        // Width × depth × height, the way a print bed reads.
        dimensions = QStringLiteral("%1 × %2 × %3 mm")
            .arg(locale.toString(extent.x() * mm, 'f', 1), locale.toString(extent.z() * mm, 'f', 1),
                 locale.toString(job.heightMm, 'f', 1));
    }
    return {
        {QStringLiteral("ok"), true},
        {QStringLiteral("faces"), locale.toString(glb.triangles)},
        {QStringLiteral("faceCount"), glb.triangles},
        {QStringLiteral("vertices"), locale.toString(glb.vertices)},
        {QStringLiteral("textures"), textures.isEmpty() ? QStringLiteral("None")
                                                        : textures.join(QStringLiteral(", "))},
        {QStringLiteral("fileSize"), formatBytes(glb.fileSize)},
        {QStringLiteral("dimensions"), dimensions},
        {QStringLiteral("path"), job.glbPath},
    };
}

void Backend::exportModel(const QString &id, const QString &format, double ratio, int texture) {
    const int row = m_jobs.rowOf(id);
    if (row < 0 || m_jobs.at(row).glbPath.isEmpty() || m_exporter.busy())
        return;
    if (!canExport()) {
        setStatus(QStringLiteral("Exporting needs Blender, which isn't installed."));
        return;
    }
    const Job &job = m_jobs.at(row);
    const GlbInfo &glb = glbInfo(job.glbPath);
    ExportOptions options;
    options.format = format;
    options.ratio = qBound(0.01, ratio, 1.0);
    options.texture = format == QLatin1String("stl") ? 0 : qMax(0, texture);
    options.rotation = job.rotation;
    options.scale = exportScale(format, job.heightMm,
                                rotatedExtent(glb.min, glb.max, job.rotation).y());
    // Accessor boxes may overestimate rotated geometry. Let Blender enforce
    // the requested height using the mesh itself, in the format's units.
    if (job.heightMm > 0 || format == QLatin1String("stl"))
        options.height = exportScale(format, job.heightMm, 1.0);
    m_pendingExport = {id, options};

    QString name = QFileInfo(job.glbPath).completeBaseName();
    if (options.ratio < 1 || options.texture > 0)
        name += QStringLiteral("-light");
    m_saver->saveFile(QStringLiteral("Export model"), name + QLatin1Char('.') + format,
                      format.toUpper(), {QStringLiteral("*.") + format});
}

QString Backend::snapshotPath(const QString &id) const {
    const int row = m_jobs.rowOf(id);
    if (row < 0 || m_jobs.at(row).glbPath.isEmpty())
        return {};
    const QFileInfo model(m_jobs.at(row).glbPath);
    return freePath(model.absolutePath(), model.completeBaseName() + QStringLiteral("-view"),
                    QStringLiteral("png"));
}

void Backend::snapshotSaved(const QString &path, bool ok) {
    setStatus(ok ? QStringLiteral("Saved %1").arg(QFileInfo(path).fileName())
                 : QStringLiteral("Couldn't save the snapshot."));
}

void Backend::refreshBusy() {
    const bool busy = m_jobs.hasPendingWork();
    if (m_busy == busy)
        return;
    m_busy = busy;
    emit busyChanged();
}

void Backend::setStatus(const QString &status) {
    if (m_status == status)
        return;
    m_status = status;
    emit statusChanged();
}

void Backend::scheduleSave() {
    m_saveTimer.start();
}

void Backend::saveNow() {
    m_saveTimer.stop();
    if (!Library::save(m_libraryPath, m_jobs.all()))
        setStatus(QStringLiteral("Couldn't save the list to %1").arg(m_libraryPath));
}
