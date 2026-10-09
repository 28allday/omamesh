import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// How the model is shown: display mode, scene, turntable, compare, snapshot,
// and the details panel. Acts on `viewer` (a ModelView).
Rectangle {
    id: bar

    required property Item viewer
    property bool detailsOpen: false
    property color textColor
    property color lineColor
    signal snapshotRequested()
    signal detailsToggled()

    implicitHeight: 44
    color: "transparent"

    component Toggle: ToolButton {
        checkable: true
        font.pixelSize: 13
        ToolTip.visible: hovered && ToolTip.text !== ""
        ToolTip.delay: 600
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 2

        ButtonGroup { id: modes }
        Repeater {
            model: [
                { mode: "textured", label: "Textured", key: "1" },
                { mode: "clay", label: "Clay", key: "2" },
                { mode: "normals", label: "Normals", key: "3" }
            ]
            delegate: Toggle {
                required property var modelData
                text: modelData.label
                ButtonGroup.group: modes
                checked: bar.viewer.displayMode === modelData.mode
                onClicked: bar.viewer.displayMode = modelData.mode
                ToolTip.text: modelData.key
            }
        }
        Toggle {
            text: "Wireframe"
            checked: bar.viewer.wireframe
            onClicked: bar.viewer.wireframe = checked
            ToolTip.text: "W"
        }

        Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 20; color: bar.lineColor }

        ToolButton {
            text: "Scene ▾"
            font.pixelSize: 13
            onClicked: scenePopup.opened ? scenePopup.close() : scenePopup.open()

            Popup {
                id: scenePopup
                y: parent.height
                padding: 16
                width: 280

                GridLayout {
                    anchors.fill: parent
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 8

                    Label { text: "Lighting"; color: bar.textColor; opacity: 0.7 }
                    ComboBox {
                        Layout.fillWidth: true
                        textRole: "label"
                        valueRole: "value"
                        model: [
                            { value: "studio", label: "Studio" },
                            { value: "soft", label: "Soft" },
                            { value: "dramatic", label: "Dramatic" },
                            { value: "neutral", label: "Even (no key light)" }
                        ]
                        currentIndex: Math.max(0, indexOfValue(bar.viewer.lighting))
                        onActivated: bar.viewer.lighting = currentValue
                    }

                    Label { text: "Exposure"; color: bar.textColor; opacity: 0.7 }
                    RowLayout {
                        Layout.fillWidth: true
                        // log2 scale: −2 … +2 stops
                        Slider {
                            id: exposureSlider
                            Layout.fillWidth: true
                            from: -2
                            to: 2
                            value: Math.log2(bar.viewer.exposure)
                            onMoved: bar.viewer.exposure = Math.pow(2, value)
                        }
                        ToolButton {
                            text: "0"
                            font.pixelSize: 12
                            onClicked: bar.viewer.exposure = 1
                        }
                    }

                    Label { text: "Background"; color: bar.textColor; opacity: 0.7 }
                    ComboBox {
                        Layout.fillWidth: true
                        textRole: "label"
                        valueRole: "value"
                        model: [
                            { value: "theme", label: "Theme" },
                            { value: "dark", label: "Dark" },
                            { value: "grey", label: "Grey" },
                            { value: "light", label: "Light" }
                        ]
                        currentIndex: Math.max(0, indexOfValue(bar.viewer.background))
                        onActivated: bar.viewer.background = currentValue
                    }

                    Label { text: "Floor"; color: bar.textColor; opacity: 0.7 }
                    Switch {
                        text: "With shadow"
                        checked: bar.viewer.floor
                        onToggled: bar.viewer.floor = checked
                    }
                }
            }
        }
        Toggle {
            text: "Turntable"
            checked: bar.viewer.turntable
            onClicked: bar.viewer.turntable = checked
            ToolTip.text: "T"
        }
        Toggle {
            text: "Compare"
            enabled: bar.viewer.hasImage
            checked: bar.viewer.compare
            onClicked: bar.viewer.compare = checked
            ToolTip.text: "C · the photo beside the model"
        }

        Item { Layout.fillWidth: true }

        ToolButton {
            text: "Snapshot"
            font.pixelSize: 13
            onClicked: bar.snapshotRequested()
            ToolTip.visible: hovered
            ToolTip.delay: 600
            ToolTip.text: "P · saves a PNG next to the model"
        }
        Toggle {
            text: "Details"
            checked: bar.detailsOpen
            onClicked: bar.detailsToggled()
            ToolTip.text: "I"
        }
    }

    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: bar.lineColor
    }
}
