#include "engine.h"

#include <QFileInfo>
#include <QCoreApplication>
#include <QDir>
#include <QJsonDocument>
#include <QStandardPaths>

namespace {
constexpr int kStderrTailLines = 40;
constexpr int kQuitGraceMs = 3000;
}

Engine::Engine(QObject *parent) : QObject(parent) {}

Engine::~Engine() {
    stop();
}

QString Engine::findCommand(const QProcessEnvironment &env) {
    const QString configured = env.value(QStringLiteral("OMAMESH_ENGINE"));
    if (!configured.isEmpty()) {
        const QFileInfo info(configured);
        if (info.isFile() && info.isExecutable())
            return info.absoluteFilePath();
        return QStandardPaths::findExecutable(configured);
    }
    const QString bundled = QDir(QCoreApplication::applicationDirPath()).filePath(
        QStringLiteral("../share/omamesh/engine/bin/img2mesh"));
    if (QFileInfo(bundled).isExecutable())
        return bundled;
    return QStandardPaths::findExecutable(QStringLiteral("img2mesh"));
}

QJsonObject Engine::parseLine(const QByteArray &line) {
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(line.trimmed(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return {};
    const QJsonObject object = doc.object();
    if (!object.value(QStringLiteral("event")).isString())
        return {};
    return object;
}

bool Engine::ensureStarted(const QString &quality) {
    if (m_process && m_process->state() != QProcess::NotRunning)
        return true;

    const QString command = findCommand(QProcessEnvironment::systemEnvironment());
    if (command.isEmpty()) {
        setState(State::Failed,
                 QStringLiteral("The 3D engine isn't installed. Run omamesh --setup in a terminal."));
        return false;
    }

    delete m_process;
    m_process = new QProcess(this);
    m_stdoutBuffer.clear();
    m_stderrTail.clear();
    m_stopping = false;

    connect(m_process, &QProcess::readyReadStandardOutput, this, &Engine::readStdout);
    connect(m_process, &QProcess::readyReadStandardError, this, &Engine::readStderr);
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            setState(State::Failed, QStringLiteral("img2mesh could not start: %1")
                                        .arg(m_process->errorString()));
    });
    connect(m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus) {
        if (m_stopping) {
            setState(State::Off);
            return;
        }
        if (m_state == State::Failed)
            return;  // already explained by a fatal event
        const QString last = m_stderrTail.isEmpty() ? QString() : m_stderrTail.constLast();
        const QString message = last.isEmpty()
            ? QStringLiteral("img2mesh stopped (exit %1).").arg(code)
            : QStringLiteral("img2mesh stopped: %1").arg(last);
        setState(State::Failed, message);
        emit lost(message);
    });

    setState(State::Loading, QStringLiteral("Starting img2mesh…"));
    m_process->start(command, {QStringLiteral("--serve"), QStringLiteral("-q"), quality});
    return true;
}

void Engine::send(const QJsonObject &command) {
    if (!m_process || m_process->state() == QProcess::NotRunning)
        return;
    m_process->write(QJsonDocument(command).toJson(QJsonDocument::Compact) + '\n');
}

void Engine::stop() {
    if (!m_process || m_process->state() == QProcess::NotRunning)
        return;
    m_stopping = true;
    send({{QStringLiteral("cmd"), QStringLiteral("quit")}});
    m_process->closeWriteChannel();
    // A job mid-sampling only checks in between steps; don't hang the quit on it.
    if (!m_process->waitForFinished(kQuitGraceMs)) {
        m_process->terminate();
        if (!m_process->waitForFinished(kQuitGraceMs))
            m_process->kill();
    }
}

void Engine::setState(State state, const QString &message) {
    if (m_state == state && m_message == message)
        return;
    m_state = state;
    m_message = message;
    emit stateChanged();
}

void Engine::readStdout() {
    m_stdoutBuffer += m_process->readAllStandardOutput();
    qsizetype newline;
    while ((newline = m_stdoutBuffer.indexOf('\n')) >= 0) {
        const QByteArray line = m_stdoutBuffer.left(newline);
        m_stdoutBuffer.remove(0, newline + 1);
        const QJsonObject object = parseLine(line);
        if (object.isEmpty())
            continue;

        const QString kind = object.value(QStringLiteral("event")).toString();
        if (kind == QLatin1String("loading"))
            setState(State::Loading, QStringLiteral("Loading models…"));
        else if (kind == QLatin1String("ready"))
            setState(State::Ready, QStringLiteral("Ready"));
        else if (kind == QLatin1String("fatal"))
            setState(State::Failed, object.value(QStringLiteral("message")).toString());
        emit received(object);
    }
}

void Engine::readStderr() {
    const QString text = QString::fromUtf8(m_process->readAllStandardError());
    for (const QString &line : text.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        const QString trimmed = line.trimmed();
        if (trimmed.isEmpty())
            continue;
        m_stderrTail.append(trimmed);
        if (m_stderrTail.size() > kStderrTailLines)
            m_stderrTail.removeFirst();
    }
}
