import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// One image in the sidebar list.
ItemDelegate {
    id: row

    required property int index
    required property url imageUrl
    required property string name
    required property string jobState
    required property string stage
    required property real progress
    required property string detail
    required property url glbUrl
    required property string jobId
    required property quaternion orientation
    required property real heightMm
    required property bool hasImage

    property color textColor
    property color accent
    property color selectionColor
    property bool selected: false

    signal menuRequested(real x, real y)

    height: 64
    padding: 8
    background: Rectangle {
        color: row.selected ? row.selectionColor
             : row.hovered ? Qt.rgba(row.textColor.r, row.textColor.g, row.textColor.b, 0.05)
             : "transparent"
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: (point) => row.menuRequested(point.position.x, point.position.y)
    }

    contentItem: RowLayout {
        spacing: 10

        Image {
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48
            visible: row.hasImage
            source: row.imageUrl
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 96
            sourceSize.height: 96
        }
        // A model opened without its photo.
        Rectangle {
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48
            visible: !row.hasImage
            radius: 4
            color: Qt.rgba(row.textColor.r, row.textColor.g, row.textColor.b, 0.08)
            Label {
                anchors.centerIn: parent
                text: "3D"
                color: row.textColor
                opacity: 0.6
                font.weight: Font.DemiBold
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                Layout.fillWidth: true
                text: row.name
                color: row.textColor
                elide: Text.ElideMiddle
            }

            Label {
                Layout.fillWidth: true
                color: row.textColor
                opacity: row.jobState === "failed" ? 0.9 : 0.6
                font.pixelSize: 12
                elide: Text.ElideRight
                text: {
                    switch (row.jobState) {
                    case "queued": return row.detail || "Waiting"
                    case "running": return row.detail || row.stage
                    default: return row.detail
                    }
                }
            }

            ProgressBar {
                Layout.fillWidth: true
                Layout.preferredHeight: 4
                visible: row.jobState === "running"
                indeterminate: row.progress < 0
                value: Math.max(0, row.progress)
                Material.accent: row.accent
            }
        }
    }
}
