import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick3D
import QtQuick3D.Helpers
import QtQuick3D.AssetUtils

// The selected job: its 3D model when finished, otherwise the source photo
// with where the job has got to.
Item {
    id: viewer

    property url imageUrl
    property url glbUrl
    property string jobState: ""
    property string stage: ""
    property real progress: -1
    property string detail: ""
    property quaternion orientation: Qt.quaternion(1, 0, 0, 0)
    property color pageColor
    property color textColor
    property color accent

    // How it's shown; Main keeps these between runs.
    property string displayMode: "textured"  // textured, clay, normals
    property bool wireframe: false
    property string lighting: "studio"       // studio, soft, dramatic, neutral
    property real exposure: 1.0
    property string background: "theme"      // theme, dark, grey, light
    property bool floor: true
    property bool turntable: false
    property bool compare: false

    readonly property bool showingModel: jobState === "done" && glbUrl.toString() !== ""
    readonly property bool hasImage: imageUrl.toString() !== ""
    readonly property bool loaded: loader.status === RuntimeLoader.Success
    // The normals view would paint the floor too.
    readonly property bool floorShown: floor && displayMode !== "normals"
    readonly property color backgroundColor: {
        switch (background) {
        case "dark": return "#1c1c1e"
        case "grey": return "#7a7a7a"
        case "light": return "#ececec"
        }
        return pageColor
    }

    // Linear tone mapping throughout: filmic lifted the whole frame (background
    // included) and washed models out, so textures looked paler than they are.
    readonly property var presets: ({
        studio:   { probe: 0.9,  key: 0.6, pitch: -40, yaw: -35 },
        soft:     { probe: 1.2,  key: 0.0, pitch: -40, yaw: -35 },
        dramatic: { probe: 0.12, key: 2.6, pitch: -22, yaw: -75 },
        neutral:  { probe: 1.0,  key: 0.0, pitch: -40, yaw: -35 }
    })
    readonly property var preset: presets[lighting] || presets.studio

    function resetView() {
        orbitOrigin.eulerRotation = Qt.vector3d(-12, 30, 0)
        camera.position = Qt.vector3d(0, 0, 2.4)
        spin.eulerRotation = Qt.vector3d(0, 0, 0)
    }

    // The model's box once turned upright, in its own units.
    function rotatedExtent(lo, hi, q) {
        let min = null, max = null
        for (let corner = 0; corner < 8; ++corner) {
            const p = q.times(Qt.vector3d(corner & 1 ? hi.x : lo.x,
                                          corner & 2 ? hi.y : lo.y,
                                          corner & 4 ? hi.z : lo.z))
            min = min ? Qt.vector3d(Math.min(min.x, p.x), Math.min(min.y, p.y), Math.min(min.z, p.z)) : p
            max = max ? Qt.vector3d(Math.max(max.x, p.x), Math.max(max.y, p.y), Math.max(max.z, p.z)) : p
        }
        return max.minus(min)
    }

    function applyMaterials() {
        if (loaded)
            sceneTools.overrideMaterials(loader, displayMode === "clay" ? clay : null)
    }

    // Saves what the 3D view shows (without the photo) as a PNG.
    function snapshot(path) {
        view.grabToImage(result => backend.snapshotSaved(path, result.saveToFile(path)))
    }

    onGlbUrlChanged: resetView()
    onDisplayModeChanged: applyMaterials()

    // Side-by-side: the photo takes the left half.
    Item {
        id: photoSide
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: viewer.compare && viewer.showingModel && viewer.hasImage ? parent.width / 2 : 0
        visible: width > 0
        clip: true

        Rectangle { anchors.fill: parent; color: viewer.backgroundColor }
        Image {
            anchors.fill: parent
            anchors.margins: 24
            source: photoSide.visible ? viewer.imageUrl : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            sourceSize.width: 1600
        }
    }

    View3D {
        id: view
        anchors { left: photoSide.right; right: parent.right; top: parent.top; bottom: parent.bottom }
        visible: viewer.showingModel
        camera: camera

        environment: ExtendedSceneEnvironment {
            backgroundMode: SceneEnvironment.Color
            clearColor: viewer.backgroundColor
            antialiasingMode: SceneEnvironment.MSAA
            antialiasingQuality: SceneEnvironment.High
            lightProbe: Texture { source: "qrc:/studio.hdr" }
            probeExposure: viewer.preset.probe
            tonemapMode: SceneEnvironment.TonemapModeLinear
            exposure: viewer.exposure
            debugSettings: DebugSettings {
                wireframeEnabled: viewer.wireframe
                materialOverride: viewer.displayMode === "normals" ? DebugSettings.Normals
                                                                   : DebugSettings.None
            }
        }

        PrincipledMaterial {
            id: clay
            baseColor: "#bdb8b0"
            roughness: 0.6
            metalness: 0
        }

        Node {
            id: orbitOrigin
            eulerRotation: Qt.vector3d(-12, 30, 0)

            PerspectiveCamera {
                id: camera
                position: Qt.vector3d(0, 0, 2.4)
                fieldOfView: 35
                clipNear: 0.01
                clipFar: 100
            }
        }

        DirectionalLight {
            eulerRotation: Qt.vector3d(viewer.preset.pitch, viewer.preset.yaw, 0)
            brightness: viewer.preset.key > 0 ? viewer.preset.key : 0.35
            visible: viewer.preset.key > 0 || viewer.floorShown
            castsShadow: viewer.floorShown
            shadowFactor: 55
            shadowMapQuality: Light.ShadowMapQualityHigh
            // Qt's shadow defaults suit centimetre scenes; this one is a unit box.
            shadowMapFar: 6
            shadowBias: 0.005
            softShadowQuality: Light.PCF16
            pcfFactor: 0.05
            csmNumSplits: 0
        }

        // Spins for the turntable; the model inside is fitted into a unit box
        // and turned the way the user set it upright.
        Node {
            id: spin

            Node {
                id: fit
                readonly property vector3d lo: loader.bounds.minimum
                readonly property vector3d hi: loader.bounds.maximum
                readonly property vector3d extent: viewer.loaded
                    ? viewer.rotatedExtent(lo, hi, viewer.orientation) : Qt.vector3d(1, 1, 1)
                readonly property real size: Math.max(extent.x, extent.y, extent.z)
                scale: size > 0 ? Qt.vector3d(1 / size, 1 / size, 1 / size) : Qt.vector3d(1, 1, 1)

                Node {
                    rotation: viewer.orientation

                    RuntimeLoader {
                        id: loader
                        source: viewer.showingModel ? viewer.glbUrl : ""
                        position: Qt.vector3d(-(fit.lo.x + fit.hi.x) / 2,
                                              -(fit.lo.y + fit.hi.y) / 2,
                                              -(fit.lo.z + fit.hi.z) / 2)
                        onStatusChanged: viewer.applyMaterials()
                    }
                }
            }
        }

        Model {
            visible: viewer.floorShown && viewer.loaded
            source: "#Rectangle"
            y: fit.size > 0 ? -fit.extent.y / fit.size / 2 - 0.001 : -0.5
            eulerRotation.x: -90
            scale: Qt.vector3d(0.6, 0.6, 1)
            castsShadows: false
            receivesShadows: true
            // Invisible apart from the shadow on it.
            materials: CustomMaterial {
                shadingMode: CustomMaterial.Shaded
                fragmentShader: "qrc:/shadowcatcher.frag"
                property color floorColor: viewer.backgroundColor
                property real strength: 0.55
            }
        }
    }

    FrameAnimation {
        running: viewer.turntable && viewer.showingModel
        onTriggered: spin.eulerRotation.y = (spin.eulerRotation.y + frameTime * 30) % 360
    }

    OrbitCameraController {
        anchors.fill: view
        enabled: viewer.showingModel
        origin: orbitOrigin
        camera: camera
    }

    Label {
        anchors.centerIn: view
        visible: viewer.showingModel && loader.status === RuntimeLoader.Error
        text: "Couldn't show this model:\n" + loader.errorString
        color: viewer.textColor
        horizontalAlignment: Text.AlignHCenter
    }

    BusyIndicator {
        anchors.centerIn: view
        running: viewer.showingModel && loader.status === RuntimeLoader.Empty
        visible: running
    }

    // Not finished yet: the photo, and the job's progress under it.
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 64, 520)
        visible: !viewer.showingModel && viewer.hasImage
        spacing: 16

        Image {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(viewer.height * 0.55, 420)
            source: viewer.imageUrl
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            sourceSize.width: 1024
            opacity: viewer.jobState === "running" ? 1 : 0.6
        }

        ProgressBar {
            Layout.fillWidth: true
            visible: viewer.jobState === "running" || viewer.jobState === "queued"
            indeterminate: viewer.progress < 0
            value: Math.max(0, viewer.progress)
        }

        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: viewer.textColor
            opacity: 0.75
            text: {
                switch (viewer.jobState) {
                case "queued": return "Waiting for the engine…"
                case "running": return viewer.stage
                case "failed": return "Failed: " + viewer.detail
                case "cancelled": return viewer.detail || "Cancelled"
                }
                return ""
            }
        }
    }

    // The source photo stays in the corner for comparison.
    Rectangle {
        visible: viewer.showingModel && viewer.hasImage && !viewer.compare
        anchors { left: parent.left; top: parent.top; margins: 16 }
        width: 112
        height: 112
        radius: 4
        color: "transparent"
        border.color: Qt.rgba(viewer.textColor.r, viewer.textColor.g, viewer.textColor.b, 0.15)

        Image {
            anchors.fill: parent
            anchors.margins: 1
            source: parent.visible ? viewer.imageUrl : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            sourceSize.width: 224
        }
    }
}
