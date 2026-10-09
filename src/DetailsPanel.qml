import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The selected model's facts and the things to do with it: rename, set it
// upright, give it a real size, export it, bin it.
Rectangle {
    id: panel

    property string jobId: ""
    property string name: ""
    property url glbUrl
    property quaternion orientation
    property real heightMm: 0
    property color textColor
    property color accent
    property color lineColor

    property var info: ({})

    function refresh() {
        info = jobId !== "" ? backend.info(jobId) : ({})
    }
    function focusRename() {
        nameField.forceActiveFocus()
        nameField.selectAll()
    }

    onJobIdChanged: refresh()
    onGlbUrlChanged: refresh()
    onOrientationChanged: refresh()
    onHeightMmChanged: {
        refresh()
        heightField.text = heightMm > 0 ? Number(heightMm).toLocaleString(Qt.locale(), "f", 1) : ""
    }
    onNameChanged: nameField.text = name

    component Heading: Label {
        Layout.fillWidth: true
        Layout.topMargin: 14
        color: panel.textColor
        font.pixelSize: 12
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        opacity: 0.55
    }
    component Key: Label {
        color: panel.textColor
        opacity: 0.65
    }
    component Value: Label {
        Layout.fillWidth: true
        color: panel.textColor
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideMiddle
    }
    component TurnButton: Button {
        required property string axis
        required property int degrees
        flat: true
        implicitHeight: 34
        topInset: 0
        bottomInset: 0
        Layout.fillWidth: true
        font.pixelSize: 13
        onClicked: backend.rotate(panel.jobId, axis, degrees)
    }

    ScrollView {
        id: scroll
        anchors.fill: parent
        contentWidth: availableWidth

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 6

            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: 16
                spacing: 6

                Heading { text: "Model"; Layout.topMargin: 0 }
                RowLayout {
                    Layout.fillWidth: true
                    TextField {
                        id: nameField
                        Layout.fillWidth: true
                        implicitHeight: 40
                        selectByMouse: true
                        onAccepted: if (!backend.rename(panel.jobId, text)) text = panel.name
                        Keys.onEscapePressed: {
                            text = panel.name
                            focus = false
                        }
                    }
                    Button {
                        text: "Rename"
                        flat: true
                        enabled: nameField.text.trim() !== "" && nameField.text !== panel.name
                        onClicked: if (!backend.rename(panel.jobId, nameField.text)) nameField.text = panel.name
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    rowSpacing: 4
                    visible: panel.info.ok === true
                    Key { text: "Faces" }
                    Value { text: panel.info.faces || "" }
                    Key { text: "Vertices" }
                    Value { text: panel.info.vertices || "" }
                    Key { text: "Textures" }
                    Value { text: panel.info.textures || "" }
                    Key { text: "File size" }
                    Value { text: panel.info.fileSize || "" }
                }
                Label {
                    Layout.fillWidth: true
                    visible: panel.info.ok === false && (panel.info.error || "") !== ""
                    text: "Can't read this file: " + (panel.info.error || "")
                    color: panel.textColor
                    wrapMode: Text.Wrap
                }

                Heading { text: "Which way is up" }
                Label {
                    Layout.fillWidth: true
                    text: "Turn the model a quarter at a time until it stands the right way. Exports keep it."
                    color: panel.textColor
                    opacity: 0.6
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: 2
                    rowSpacing: -4
                    Key { text: "Tip" }
                    TurnButton { text: "Forward"; axis: "x"; degrees: 90 }
                    TurnButton { text: "Back"; axis: "x"; degrees: -90 }
                    Key { text: "Turn" }
                    TurnButton { text: "Left"; axis: "y"; degrees: -90 }
                    TurnButton { text: "Right"; axis: "y"; degrees: 90 }
                    Key { text: "Roll" }
                    TurnButton { text: "Left"; axis: "z"; degrees: 90 }
                    TurnButton { text: "Right"; axis: "z"; degrees: -90 }
                }
                Button {
                    text: "Reset orientation"
                    flat: true
                    enabled: !(panel.orientation.scalar === 1 && panel.orientation.x === 0
                               && panel.orientation.y === 0 && panel.orientation.z === 0)
                    onClicked: backend.resetOrientation(panel.jobId)
                }

                Heading { text: "Real size" }
                RowLayout {
                    Layout.fillWidth: true
                    Key { text: "Height" }
                    TextField {
                        id: heightField
                        Layout.fillWidth: true
                        implicitHeight: 40
                        placeholderText: text === "" ? "not set" : ""
                        horizontalAlignment: Text.AlignRight
                        inputMethodHints: Qt.ImhFormattedNumbersOnly
                        validator: DoubleValidator { bottom: 0; top: 100000; decimals: 1 }
                        onEditingFinished: {
                            const mm = Number.fromLocaleString(Qt.locale(), text || "0")
                            backend.setHeightMm(panel.jobId, isNaN(mm) ? 0 : mm)
                        }
                    }
                    Key { text: "mm" }
                }
                Label {
                    Layout.fillWidth: true
                    color: panel.textColor
                    opacity: 0.6
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    text: (panel.info.dimensions || "") !== ""
                        ? "W × D × H: " + panel.info.dimensions
                        : "Set a height to print at real size. STL exports at 100 mm tall until you do."
                }

                Heading { text: "Export" }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 4

                    Key { text: "Format" }
                    ComboBox {
                        id: formatBox
                        Layout.fillWidth: true
                        implicitHeight: 40
                        topInset: 0
                        bottomInset: 0
                        textRole: "label"
                        valueRole: "value"
                        model: [
                            { value: "glb", label: "GLB (web, games, Blender)" },
                            { value: "obj", label: "OBJ + textures" },
                            { value: "stl", label: "STL (3D printing)" }
                        ]
                    }

                    Key { text: "Detail" }
                    ComboBox {
                        id: detailBox
                        Layout.fillWidth: true
                        implicitHeight: 40
                        topInset: 0
                        bottomInset: 0
                        textRole: "label"
                        valueRole: "value"
                        readonly property real faceCount: panel.info.faceCount || 0
                        function faces(ratio) {
                            return faceCount > 0 ? " · " + Math.round(faceCount * ratio).toLocaleString(Qt.locale(), "f", 0) : ""
                        }
                        model: [
                            { value: 1.0, label: "Full" + faces(1.0) },
                            { value: 0.5, label: "Half" + faces(0.5) },
                            { value: 0.2, label: "Light" + faces(0.2) },
                            { value: 0.05, label: "Very light" + faces(0.05) }
                        ]
                    }

                    Key { text: "Textures"; opacity: formatBox.currentValue === "stl" ? 0.3 : 0.65 }
                    ComboBox {
                        id: textureBox
                        Layout.fillWidth: true
                        implicitHeight: 40
                        topInset: 0
                        bottomInset: 0
                        enabled: formatBox.currentValue !== "stl"
                        textRole: "label"
                        valueRole: "value"
                        model: [
                            { value: 0, label: "Keep" },
                            { value: 2048, label: "2048 px" },
                            { value: 1024, label: "1024 px" },
                            { value: 512, label: "512 px" }
                        ]
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Button {
                        text: backend.exporting ? "Exporting…" : "Export…"
                        highlighted: true
                        enabled: backend.canExport && !backend.exporting && panel.info.ok === true
                        onClicked: backend.exportModel(panel.jobId, formatBox.currentValue,
                                                       detailBox.currentValue, textureBox.currentValue)
                    }
                    BusyIndicator {
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                        running: backend.exporting
                        visible: running
                    }
                }
                Label {
                    Layout.fillWidth: true
                    visible: !backend.canExport
                    text: "Exporting uses Blender, which isn't installed."
                    color: panel.textColor
                    opacity: 0.6
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                Rectangle { Layout.fillWidth: true; Layout.topMargin: 14; height: 1; color: panel.lineColor }
                RowLayout {
                    Layout.fillWidth: true
                    Button {
                        text: "Move to Bin"
                        flat: true
                        Material.foreground: Material.color(Material.Red, Material.Shade300)
                        onClicked: backend.moveToBin(panel.jobId)
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "Remove from list"
                        flat: true
                        onClicked: backend.remove(panel.jobId)
                    }
                }
            }
        }
    }
}
