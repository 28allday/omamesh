#include "exporter.h"

#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

namespace {
constexpr char kResultTag[] = "OMAMESH_EXPORT ";
constexpr int kTailChars = 600;
}

Exporter::Exporter(QObject *parent) : QObject(parent) {}

Exporter::~Exporter() {
    if (m_process) {
        m_process->kill();
        m_process->waitForFinished(1000);
    }
}

QStringList Exporter::arguments(const QString &script, const QString &source,
                                const QString &destination, const ExportOptions &options) {
    const QQuaternion &r = options.rotation;
    // The paths travel as arguments after `--`, never pasted into the Python.
    return {
        QStringLiteral("-b"), QStringLiteral("--factory-startup"),
        QStringLiteral("--python-exit-code"), QStringLiteral("1"),
        QStringLiteral("--python-expr"), script,
        QStringLiteral("--"),
        source, destination, options.format,
        QString::number(options.ratio), QString::number(options.texture),
        QString::number(r.scalar()), QString::number(r.x()),
        QString::number(r.y()), QString::number(r.z()),
        QString::number(options.scale, 'g', 10),
        QString::number(options.height, 'g', 10),
    };
}

bool Exporter::start(const QString &source, const QString &destination,
                     const ExportOptions &options) {
    if (m_process)
        return false;
    const QString blender = QStandardPaths::findExecutable(QStringLiteral("blender"));
    if (blender.isEmpty()) {
        emit finished(false, QStringLiteral("Exporting needs Blender, which isn't installed."));
        return false;
    }
    QFile script(QStringLiteral(":/export.py"));
    if (!script.open(QIODevice::ReadOnly)) {
        emit finished(false, QStringLiteral("The export script is missing from this build."));
        return false;
    }

    m_destination = destination;
    m_output.clear();
    m_process = new QProcess(this);
    m_process->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_process, &QProcess::readyRead, this, [this] {
        m_output += QString::fromUtf8(m_process->readAll());
        if (m_output.size() > 64 * 1024)
            m_output = m_output.right(kTailChars * 4);
    });
    connect(m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        m_output += QString::fromUtf8(m_process->readAll());
        m_process->deleteLater();
        m_process = nullptr;
        emit busyChanged();
        const bool ok = status == QProcess::NormalExit && code == 0
            && m_output.contains(QLatin1String(kResultTag));
        if (ok) {
            emit finished(true, QStringLiteral("Exported %1").arg(QFileInfo(m_destination).fileName()));
            return;
        }
        // Blender's last error line says more than an exit code.
        QString reason;
        const QStringList lines = m_output.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
        for (auto it = lines.crbegin(); it != lines.crend(); ++it) {
            if (it->contains(QLatin1String("Error"))) {
                reason = it->trimmed();
                break;
            }
        }
        emit finished(false, QStringLiteral("Export failed: %1")
                                 .arg(reason.isEmpty() ? QStringLiteral("exit %1").arg(code) : reason));
    });
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart)
            return;
        m_process->deleteLater();
        m_process = nullptr;
        emit busyChanged();
        emit finished(false, QStringLiteral("Blender could not start."));
    });

    m_process->start(blender, arguments(QString::fromUtf8(script.readAll()), source, destination, options));
    emit busyChanged();
    return true;
}
