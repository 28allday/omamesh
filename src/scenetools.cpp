#include "scenetools.h"

#include <QQmlListReference>

namespace {
constexpr char kOriginals[] = "_omameshMaterials";
}

int SceneTools::overrideMaterials(QObject *root, QObject *material) {
    if (!root)
        return 0;
    int changed = 0;
    for (QObject *node : root->findChildren<QObject *>()) {
        if (!node->inherits("QQuick3DModel"))
            continue;
        QQmlListReference materials(node, "materials");
        if (!materials.isValid() || !materials.canClear() || !materials.canAppend())
            continue;

        const QVariant saved = node->property(kOriginals);
        if (material) {
            if (!saved.isValid()) {
                QObjectList originals;
                for (qsizetype i = 0; i < materials.count(); ++i)
                    originals.append(materials.at(i));
                node->setProperty(kOriginals, QVariant::fromValue(originals));
            }
            materials.clear();
            materials.append(material);
        } else if (saved.isValid()) {
            materials.clear();
            for (QObject *original : saved.value<QObjectList>())
                materials.append(original);
            node->setProperty(kOriginals, QVariant());
        }
        ++changed;
    }
    return changed;
}
