#pragma once

#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QQuaternion>
#include <QString>
#include <QStringList>

// What an export should do to the model on the way out.
struct ExportOptions {
    QString format = QStringLiteral("glb");  // glb, obj or stl
    double ratio = 1.0;                       // share of faces to keep
    int texture = 0;                          // longest texture side, 0 keeps them
    QQuaternion rotation;                     // glTF space, as shown in the viewer
    double scale = 1.0;
    // Exact final height in output units (mm for STL, metres otherwise).
    // Zero keeps `scale`; a positive value is measured from the geometry.
    double height = 0.0;
};

// Writes models out through Blender, in the background. One export at a time.
class Exporter : public QObject {
    Q_OBJECT

public:
    explicit Exporter(QObject *parent = nullptr);
    ~Exporter() override;

    bool busy() const { return m_process != nullptr; }
    // False (and a `finished` with the reason) when Blender isn't installed.
    bool start(const QString &source, const QString &destination, const ExportOptions &options);

    static QStringList arguments(const QString &script, const QString &source,
                                 const QString &destination, const ExportOptions &options);

signals:
    void busyChanged();
    void finished(bool ok, const QString &message);

private:
    QPointer<QProcess> m_process;
    QString m_destination;
    QString m_output;
};
