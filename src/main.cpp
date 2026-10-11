// omamesh — drop photos in, get 3D models out. Qt Quick (QML) UI, C++ backend
// driving the img2mesh (TRELLIS.2) engine.

#include <QFileInfo>
#include <QCoreApplication>
#include <QDir>
#include <QGuiApplication>
#include <QFont>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickStyle>
#include <QProcess>
#include <QUrl>

#include <cstdio>

#include "backend.h"
#include "scenetools.h"
#include "theme.h"

int main(int argc, char *argv[]) {
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--version") == 0) {
            std::printf("omamesh %s\n", OMAMESH_VERSION);
            return 0;
        }
    }

    if (argc > 1 && (qstrcmp(argv[1], "--setup") == 0 ||
                     qstrcmp(argv[1], "--img2mesh") == 0)) {
        QCoreApplication app(argc, argv);
        const bool setup = qstrcmp(argv[1], "--setup") == 0;
        const QString script = QDir(app.applicationDirPath()).filePath(
            setup ? QStringLiteral("../share/omamesh/engine/install.sh")
                  : QStringLiteral("../share/omamesh/engine/bin/img2mesh"));
        QProcess process;
        process.setProcessChannelMode(QProcess::ForwardedChannels);
        process.setInputChannelMode(QProcess::ForwardedInputChannel);
        process.start(script, app.arguments().mid(2));
        if (!process.waitForStarted()) {
            std::fprintf(stderr, "Could not start %s: %s\n", setup ? "omamesh-setup" : "img2mesh",
                         qPrintable(process.errorString()));
            return 1;
        }
        if (!process.waitForFinished(-1)) {
            std::fprintf(stderr, "%s failed: %s\n", setup ? "omamesh-setup" : "img2mesh",
                         qPrintable(process.errorString()));
            return 1;
        }
        return process.exitStatus() == QProcess::NormalExit ? process.exitCode() : 1;
    }

    QGuiApplication app(argc, argv);
    app.setApplicationVersion(QStringLiteral(OMAMESH_VERSION));

    // The identity trio. setDesktopFileName is what becomes the Wayland app_id,
    // which is what Hyprland rules, the taskbar and the icon lookup key off.
    app.setApplicationName(QStringLiteral("omamesh"));
    app.setOrganizationName(QStringLiteral("omamesh"));
    app.setDesktopFileName(QStringLiteral("omamesh"));
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("omamesh")));

    // The same Qt Controls family Quickshell — the Omarchy shell — builds on.
    QQuickStyle::setStyle(QStringLiteral("Material"));

    OmarchyTheme theme;
    Backend backend;
    SceneTools sceneTools;

    // Carry the desktop's text size into the default font so every control
    // grows with `omarchy display text size`, without a restart.
    const qreal basePointSize = app.font().pointSizeF();
    const auto scaleFont = [&app, basePointSize](qreal scale) {
        QFont font = app.font();
        font.setPointSizeF(basePointSize * scale);
        app.setFont(font);
    };
    scaleFont(theme.textScale());
    QObject::connect(&theme, &OmarchyTheme::textScaleChanged, &app, [&theme, scaleFont] {
        scaleFont(theme.textScale());
    });

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app,
                     [](const QList<QQmlError> &warnings) {
        for (const QQmlError &warning : warnings)
            qWarning().noquote() << warning.toString();
    });
    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    engine.rootContext()->setContextProperty(QStringLiteral("theme"), &theme);
    engine.rootContext()->setContextProperty(QStringLiteral("sceneTools"), &sceneTools);

    engine.load(QUrl(QStringLiteral("qrc:/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical() << "Could not load the omamesh interface.";
        return -1;
    }

    // "Open with", and `omamesh *.jpg` from a terminal.
    QVariantList files;
    for (const QString &arg : app.arguments().mid(1))
        files.append(QUrl::fromLocalFile(QFileInfo(arg).absoluteFilePath()));
    if (!files.isEmpty())
        backend.addUrls(files);

    return app.exec();
}
