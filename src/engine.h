#pragma once

#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QStringList>

// The img2mesh worker: one long-lived `img2mesh --serve` process that keeps the
// models in VRAM and speaks JSON lines over stdin/stdout.
class Engine : public QObject {
    Q_OBJECT

public:
    enum class State { Off, Loading, Ready, Failed };

    explicit Engine(QObject *parent = nullptr);
    ~Engine() override;

    State state() const { return m_state; }
    QString message() const { return m_message; }

    // Starts the worker if it is not already running. Returns false (and goes
    // to Failed) when no engine command can be found.
    // `quality` is the one the engine loads its models for up front.
    bool ensureStarted(const QString &quality);
    void send(const QJsonObject &command);
    void stop();

    // $OMAMESH_ENGINE, else `img2mesh` on PATH. Empty when neither exists.
    static QString findCommand(const QProcessEnvironment &env);
    // One protocol line → object; an empty object for anything that is not one.
    static QJsonObject parseLine(const QByteArray &line);

signals:
    void stateChanged();
    void received(const QJsonObject &event);
    // The worker went away while it should have been running.
    void lost(const QString &message);

private:
    void setState(State state, const QString &message = QString());
    void readStdout();
    void readStderr();

    QProcess *m_process = nullptr;
    QByteArray m_stdoutBuffer;
    QStringList m_stderrTail;
    State m_state = State::Off;
    QString m_message;
    bool m_stopping = false;
};
