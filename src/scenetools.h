#pragma once

#include <QObject>

// Things QML can't do to a loaded 3D scene by itself. Exposed as `sceneTools`.
class SceneTools : public QObject {
    Q_OBJECT

public:
    using QObject::QObject;

    // Gives every model under `root` the one `material` (the clay look), or
    // with a null material puts the models' own materials back.
    Q_INVOKABLE int overrideMaterials(QObject *root, QObject *material);
};
