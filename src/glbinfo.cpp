#include "glbinfo.h"

#include <QBuffer>
#include <QFile>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMatrix4x4>
#include <QQuaternion>
#include <QSet>
#include <QtEndian>

namespace {
constexpr quint32 kMagic = 0x46546C67;      // "glTF"
constexpr quint32 kJsonChunk = 0x4E4F534A;  // "JSON"
constexpr quint32 kBinChunk = 0x004E4942;   // "BIN\0"

quint32 word(const QByteArray &bytes, qsizetype at) {
    return qFromLittleEndian<quint32>(bytes.constData() + at);
}

GlbInfo failure(const QString &error) {
    GlbInfo info;
    info.error = error;
    return info;
}

QMatrix4x4 nodeTransform(const QJsonObject &node) {
    QMatrix4x4 transform;
    const QJsonArray matrix = node.value(QStringLiteral("matrix")).toArray();
    if (matrix.size() == 16) {
        // glTF stores matrices column first; QMatrix4x4 indexes row, column.
        for (int column = 0; column < 4; ++column)
            for (int row = 0; row < 4; ++row)
                transform(row, column) = float(matrix[column * 4 + row].toDouble());
        return transform;
    }
    // Local transforms are T * R * S, inherited through the node hierarchy.
    const QJsonArray translation = node.value(QStringLiteral("translation")).toArray();
    if (translation.size() == 3)
        transform.translate(float(translation[0].toDouble()), float(translation[1].toDouble()),
                            float(translation[2].toDouble()));
    const QJsonArray rotation = node.value(QStringLiteral("rotation")).toArray();
    if (rotation.size() == 4)
        transform.rotate(QQuaternion(float(rotation[3].toDouble()), float(rotation[0].toDouble()),
                                     float(rotation[1].toDouble()), float(rotation[2].toDouble())));
    const QJsonArray scale = node.value(QStringLiteral("scale")).toArray();
    if (scale.size() == 3)
        transform.scale(float(scale[0].toDouble()), float(scale[1].toDouble()), float(scale[2].toDouble()));
    return transform;
}
}

GlbInfo GlbInfo::read(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return failure(file.errorString());
    GlbInfo info = fromBytes(file.readAll());
    info.fileSize = file.size();
    return info;
}

GlbInfo GlbInfo::fromBytes(const QByteArray &bytes) {
    if (bytes.size() < 20 || word(bytes, 0) != kMagic)
        return failure(QStringLiteral("Not a binary glTF file"));

    QJsonObject gltf;
    QByteArray bin;
    for (qsizetype at = 12; at + 8 <= bytes.size();) {
        const quint32 length = word(bytes, at);
        const quint32 type = word(bytes, at + 4);
        if (at + 8 + qsizetype(length) > bytes.size())
            return failure(QStringLiteral("The file is cut short"));
        const QByteArray chunk = bytes.mid(at + 8, length);
        if (type == kJsonChunk)
            gltf = QJsonDocument::fromJson(chunk).object();
        else if (type == kBinChunk && bin.isEmpty())
            bin = chunk;
        at += 8 + ((qsizetype(length) + 3) & ~qsizetype(3));
    }
    if (gltf.isEmpty())
        return failure(QStringLiteral("The file has no glTF header"));

    GlbInfo info;
    info.ok = true;
    info.fileSize = bytes.size();
    const QJsonArray accessors = gltf.value(QStringLiteral("accessors")).toArray();
    const QJsonArray meshes = gltf.value(QStringLiteral("meshes")).toArray();
    const QJsonArray nodes = gltf.value(QStringLiteral("nodes")).toArray();
    const QJsonArray scenes = gltf.value(QStringLiteral("scenes")).toArray();
    QJsonArray roots;
    if (!scenes.isEmpty()) {
        roots = scenes.at(gltf.value(QStringLiteral("scene")).toInt(0)).toObject()
            .value(QStringLiteral("nodes")).toArray();
    } else {
        // With no scene declaration, use parentless nodes as the roots.
        QSet<int> children;
        for (const QJsonValue &node : nodes)
            for (const QJsonValue &child : node.toObject().value(QStringLiteral("children")).toArray())
                children.insert(child.toInt(-1));
        for (int index = 0; index < nodes.size(); ++index)
            if (!children.contains(index))
                roots.append(index);
    }

    struct NodeInstance {
        int index;
        QMatrix4x4 parentTransform;
    };
    QList<NodeInstance> pending;
    for (const QJsonValue &root : roots)
        pending.append({root.toInt(-1), QMatrix4x4()});
    QSet<int> visited;
    bool haveBounds = false;
    while (!pending.isEmpty()) {
        const NodeInstance instance = pending.takeLast();
        if (instance.index < 0 || instance.index >= nodes.size() || visited.contains(instance.index))
            return failure(QStringLiteral("The scene has an invalid node hierarchy"));
        visited.insert(instance.index);
        const QJsonObject node = nodes.at(instance.index).toObject();
        const QMatrix4x4 world = instance.parentTransform * nodeTransform(node);
        for (const QJsonValue &child : node.value(QStringLiteral("children")).toArray())
            pending.append({child.toInt(-1), world});

        // Count and measure each mesh instance in the selected scene. Unused
        // mesh definitions must not affect the displayed dimensions or scale.
        const QJsonObject mesh = meshes.at(node.value(QStringLiteral("mesh")).toInt(-1)).toObject();
        for (const QJsonValue &value : mesh.value(QStringLiteral("primitives")).toArray()) {
            const QJsonObject primitive = value.toObject();
            const QJsonObject position = accessors.at(
                primitive.value(QStringLiteral("attributes")).toObject()
                    .value(QStringLiteral("POSITION")).toInt(-1)).toObject();
            const qint64 vertices = position.value(QStringLiteral("count")).toInteger();
            info.vertices += vertices;
            const int indices = primitive.value(QStringLiteral("indices")).toInt(-1);
            info.triangles += (indices >= 0
                ? accessors.at(indices).toObject().value(QStringLiteral("count")).toInteger()
                : vertices) / 3;

            const QJsonArray lo = position.value(QStringLiteral("min")).toArray();
            const QJsonArray hi = position.value(QStringLiteral("max")).toArray();
            if (lo.size() != 3 || hi.size() != 3)
                continue;
            const QVector3D a(lo[0].toDouble(), lo[1].toDouble(), lo[2].toDouble());
            const QVector3D b(hi[0].toDouble(), hi[1].toDouble(), hi[2].toDouble());
            for (int corner = 0; corner < 8; ++corner) {
                const QVector3D point = world.map(QVector3D(corner & 1 ? b.x() : a.x(),
                                                            corner & 2 ? b.y() : a.y(),
                                                            corner & 4 ? b.z() : a.z()));
                info.min = haveBounds ? QVector3D(qMin(info.min.x(), point.x()), qMin(info.min.y(), point.y()),
                                                  qMin(info.min.z(), point.z())) : point;
                info.max = haveBounds ? QVector3D(qMax(info.max.x(), point.x()), qMax(info.max.y(), point.y()),
                                                  qMax(info.max.z(), point.z())) : point;
                haveBounds = true;
            }
        }
    }

    // Image sizes come from their headers; nothing gets decoded.
    const QJsonArray views = gltf.value(QStringLiteral("bufferViews")).toArray();
    for (const QJsonValue &value : gltf.value(QStringLiteral("images")).toArray()) {
        const QJsonObject view = views.at(value.toObject()
            .value(QStringLiteral("bufferView")).toInt(-1)).toObject();
        if (view.isEmpty())
            continue;
        QByteArray data = bin.mid(view.value(QStringLiteral("byteOffset")).toInteger(),
                                  view.value(QStringLiteral("byteLength")).toInteger());
        QBuffer buffer(&data);
        buffer.open(QIODevice::ReadOnly);
        const QSize size = QImageReader(&buffer).size();
        if (size.isValid())
            info.textures.append(size);
    }
    return info;
}
