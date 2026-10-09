#pragma once

#include <QList>
#include <QSize>
#include <QString>
#include <QVector3D>

// What's inside a binary glTF (.glb): read from its JSON header and image
// headers, without loading the mesh. Counts and bounds describe the selected
// scene's mesh instances, including inherited node transforms.
struct GlbInfo {
    bool ok = false;
    QString error;
    qint64 fileSize = 0;
    qint64 vertices = 0;
    qint64 triangles = 0;
    QList<QSize> textures;
    QVector3D min;
    QVector3D max;

    QVector3D extent() const { return max - min; }

    static GlbInfo read(const QString &path);
    static GlbInfo fromBytes(const QByteArray &bytes);
};
