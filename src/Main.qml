import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 1280
    height: 800
    minimumWidth: 900
    minimumHeight: 520
    visible: true
    title: current ? "omamesh — " + current.name : "omamesh"

    readonly property color accent: theme.accent
    readonly property color pageColor: theme.background
    readonly property color textColor: theme.foreground
    readonly property color sideColor: Qt.tint(pageColor, Qt.rgba(textColor.r, textColor.g, textColor.b, 0.04))
    readonly property color lineColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.1)
    readonly property var current: jobList.currentItem
    readonly property string currentId: current ? current.jobId : ""
    readonly property bool hasModel: viewer.showingModel
    // Single-key shortcuts stay quiet while a text field has the keyboard.
    readonly property bool typing: activeFocusItem !== null && activeFocusItem.cursorPosition !== undefined
    property bool detailsOpen: true
    property bool quitting: false

    Material.theme: theme.darkMode ? Material.Dark : Material.Light
    Material.accent: win.accent
    color: pageColor

    // How the viewer looks, kept between runs.
    Settings {
        category: "view"
        property alias displayMode: viewer.displayMode
        property alias wireframe: viewer.wireframe
        property alias lighting: viewer.lighting
        property alias exposure: viewer.exposure
        property alias background: viewer.background
        property alias floor: viewer.floor
        property alias turntable: viewer.turntable
        property alias detailsOpen: win.detailsOpen
    }

    onClosing: (close) => {
        if (backend.busy && !quitting) {
            close.accepted = false
            quitDialog.open()
        }
    }

    function select(id) {
        let row = backend.visibleRow(id)
        if (row < 0 && backend.filter !== "") {
            backend.filter = ""
            row = backend.visibleRow(id)
        }
        if (row >= 0)
            jobList.currentIndex = row
    }

    Connections {
        target: backend
        function onJobAdded(id) { win.select(id) }
    }

    component Key: Shortcut {
        context: Qt.ApplicationShortcut
    }
    // A plain letter: only when nobody's typing.
    component LetterKey: Shortcut {
        context: Qt.ApplicationShortcut
        property bool when: true
        enabled: when && !win.typing
    }

    Key { sequences: [StandardKey.Open]; onActivated: backend.openDialog() }
    Key { sequences: [StandardKey.Find]; onActivated: { searchField.forceActiveFocus(); searchField.selectAll() } }
    Key { sequence: "Ctrl+Q"; onActivated: win.close() }
    Key { sequence: "Ctrl+R"; enabled: win.current !== null; onActivated: backend.retry(win.currentId) }
    Key { sequence: "Ctrl+B"; enabled: win.hasModel; onActivated: backend.openInBlender(win.currentId) }
    Key { sequence: "Ctrl+E"; enabled: win.current !== null; onActivated: backend.showInFolder(win.currentId) }
    Key { sequence: "F2"; enabled: win.hasModel; onActivated: { win.detailsOpen = true; details.focusRename() } }
    LetterKey { sequence: "?"; onActivated: helpSheet.visible ? helpSheet.close() : helpSheet.open() }
    LetterKey { sequences: [StandardKey.Delete]; when: win.current !== null; onActivated: backend.remove(win.currentId) }
    LetterKey { sequence: "Shift+Delete"; when: win.hasModel; onActivated: backend.moveToBin(win.currentId) }
    LetterKey {
        sequence: "Escape"
        when: win.current !== null && !helpSheet.visible
        onActivated: backend.cancel(win.currentId)
    }
    LetterKey { sequence: "N"; when: win.current !== null && win.current.hasImage; onActivated: backend.newTake(win.currentId) }
    LetterKey { sequence: "R"; onActivated: viewer.resetView() }
    LetterKey { sequence: "W"; onActivated: viewer.wireframe = !viewer.wireframe }
    LetterKey { sequence: "1"; onActivated: viewer.displayMode = "textured" }
    LetterKey { sequence: "2"; onActivated: viewer.displayMode = "clay" }
    LetterKey { sequence: "3"; onActivated: viewer.displayMode = "normals" }
    LetterKey { sequence: "T"; onActivated: viewer.turntable = !viewer.turntable }
    LetterKey { sequence: "F"; onActivated: viewer.floor = !viewer.floor }
    LetterKey { sequence: "C"; when: viewer.hasImage; onActivated: viewer.compare = !viewer.compare }
    LetterKey { sequence: "I"; onActivated: win.detailsOpen = !win.detailsOpen }
    LetterKey { sequence: "P"; when: win.hasModel; onActivated: win.snapshot() }

    function snapshot() {
        const path = backend.snapshotPath(win.currentId)
        if (path !== "")
            viewer.snapshot(path)
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Sidebar: the models, the quality setting and the engine's state.
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 270
            color: win.sideColor

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 12
                    Layout.bottomMargin: 4
                    Label {
                        Layout.fillWidth: true
                        text: "Models"
                        color: win.textColor
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                    }
                    Button {
                        text: "Add…"
                        flat: true
                        onClicked: backend.openDialog()
                    }
                }

                TextField {
                    id: searchField
                    Layout.fillWidth: true
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    Layout.bottomMargin: 4
                    visible: backend.jobs.count > 0
                    placeholderText: "Search"
                    text: backend.filter
                    onTextEdited: backend.filter = text
                    Keys.onEscapePressed: {
                        backend.filter = ""
                        jobList.forceActiveFocus()
                    }
                    Keys.onDownPressed: jobList.forceActiveFocus()
                }

                ListView {
                    id: jobList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    focus: true
                    currentIndex: count > 0 ? 0 : -1
                    model: backend.visibleJobs
                    keyNavigationEnabled: true
                    ScrollBar.vertical: ScrollBar {}

                    delegate: JobRow {
                        width: ListView.view.width
                        textColor: win.textColor
                        accent: win.accent
                        selectionColor: theme.selection
                        selected: ListView.isCurrentItem
                        onClicked: {
                            jobList.currentIndex = index
                            jobList.forceActiveFocus()
                        }
                        onMenuRequested: (x, y) => {
                            jobList.currentIndex = index
                            rowMenu.popup(this, x, y)
                        }
                    }

                    Label {
                        anchors.centerIn: parent
                        width: parent.width - 48
                        visible: jobList.count === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        color: win.textColor
                        opacity: 0.5
                        text: backend.filter !== "" ? "Nothing called “" + backend.filter + "”."
                            : "Drop photos (or .glb models) anywhere in the window, or press Ctrl+O."
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: win.lineColor }

                GridLayout {
                    Layout.fillWidth: true
                    Layout.margins: 12
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 4

                    Label { text: "Quality"; color: win.textColor; opacity: 0.7 }
                    ComboBox {
                        id: qualityBox
                        Layout.fillWidth: true
                        textRole: "label"
                        valueRole: "value"
                        model: [
                            { value: "draft", label: "Draft (512)" },
                            { value: "standard", label: "Standard (1024)" },
                            { value: "high", label: "High (1536)" }
                        ]
                        Component.onCompleted: currentIndex = indexOfValue(backend.quality)
                        onActivated: backend.quality = currentValue
                    }

                    Label { text: "Engine"; color: win.textColor; opacity: 0.7 }
                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            color: win.textColor
                            elide: Text.ElideRight
                            text: {
                                switch (backend.engineState) {
                                case "off": return "Starts with the first image"
                                case "loading": return backend.engineMessage
                                case "ready": return "Ready"
                                case "failed": return "Stopped"
                                }
                                return ""
                            }
                        }
                        Button {
                            visible: backend.engineState === "failed"
                            text: "Restart"
                            flat: true
                            onClicked: backend.restartEngine()
                        }
                    }
                }

                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    Layout.bottomMargin: 12
                    visible: backend.engineState === "failed" && text !== ""
                    text: backend.engineMessage
                    wrapMode: Text.Wrap
                    maximumLineCount: 6
                    elide: Text.ElideRight
                    font.pixelSize: 12
                    color: win.textColor
                    opacity: 0.7
                }
            }
        }

        Rectangle { Layout.fillHeight: true; width: 1; color: win.lineColor }

        // The model, how it's shown, and the actions that go with it.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ViewToolbar {
                Layout.fillWidth: true
                visible: win.hasModel
                viewer: viewer
                detailsOpen: win.detailsOpen
                textColor: win.textColor
                lineColor: win.lineColor
                onSnapshotRequested: win.snapshot()
                onDetailsToggled: win.detailsOpen = !win.detailsOpen
            }

            ModelView {
                id: viewer
                Layout.fillWidth: true
                Layout.fillHeight: true
                pageColor: win.pageColor
                textColor: win.textColor
                accent: win.accent
                imageUrl: win.current ? win.current.imageUrl : ""
                glbUrl: win.current ? win.current.glbUrl : ""
                jobState: win.current ? win.current.jobState : ""
                stage: win.current ? win.current.stage : ""
                progress: win.current ? win.current.progress : -1
                detail: win.current ? win.current.detail : ""
                orientation: win.current ? win.current.orientation : Qt.quaternion(1, 0, 0, 0)

                Label {
                    anchors.centerIn: parent
                    visible: win.current === null
                    text: "Drop a photo to turn it into a 3D model"
                    color: win.textColor
                    opacity: 0.5
                    font.pixelSize: 18
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: win.lineColor; visible: win.current !== null }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 8
                visible: win.current !== null
                spacing: 4

                Button {
                    text: "Cancel"
                    flat: true
                    visible: viewer.jobState === "running" || viewer.jobState === "queued"
                    onClicked: backend.cancel(win.currentId)
                }
                Button {
                    text: "Try again"
                    flat: true
                    visible: (viewer.jobState === "failed" || viewer.jobState === "cancelled")
                             && viewer.hasImage
                    onClicked: backend.retry(win.currentId)
                }
                Button {
                    text: "New take"
                    flat: true
                    visible: viewer.jobState === "done" && viewer.hasImage
                    onClicked: backend.newTake(win.currentId)
                }
                Button {
                    text: "Open in Blender"
                    flat: true
                    visible: win.hasModel
                    onClicked: backend.openInBlender(win.currentId)
                }
                Button {
                    text: "Show in folder"
                    flat: true
                    onClicked: backend.showInFolder(win.currentId)
                }

                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                    color: win.textColor
                    opacity: 0.6
                    // A fresh message shows for a while, then the model's own detail returns.
                    text: statusTimer.running || viewer.jobState !== "done" ? backend.status : viewer.detail

                    Timer { id: statusTimer; interval: 6000 }
                    Connections {
                        target: backend
                        function onStatusChanged() { statusTimer.restart() }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillHeight: true
            width: 1
            color: win.lineColor
            visible: details.visible
        }

        DetailsPanel {
            id: details
            Layout.fillHeight: true
            Layout.preferredWidth: 300
            visible: win.detailsOpen && win.hasModel
            color: win.sideColor
            jobId: win.currentId
            name: win.current ? win.current.name : ""
            glbUrl: win.current ? win.current.glbUrl : ""
            orientation: win.current ? win.current.orientation : Qt.quaternion(1, 0, 0, 0)
            heightMm: win.current ? win.current.heightMm : 0
            textColor: win.textColor
            accent: win.accent
            lineColor: win.lineColor
        }
    }

    // Drop anywhere in the window.
    DropArea {
        id: drop
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: (event) => {
            if (event.hasUrls && backend.addUrls(event.urls) > 0)
                event.acceptProposedAction()
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 8
            visible: drop.containsDrag
            color: Qt.rgba(win.pageColor.r, win.pageColor.g, win.pageColor.b, 0.85)
            border.color: win.accent
            border.width: 2
            radius: 6

            Label {
                anchors.centerIn: parent
                text: "Drop photos to make 3D models, or .glb files to open them"
                color: win.textColor
                font.pixelSize: 20
            }
        }
    }

    Menu {
        id: rowMenu
        MenuItem {
            text: "Cancel"
            enabled: viewer.jobState === "running" || viewer.jobState === "queued"
            onTriggered: backend.cancel(win.currentId)
        }
        MenuItem {
            text: "Try again"
            enabled: (viewer.jobState === "failed" || viewer.jobState === "cancelled") && viewer.hasImage
            onTriggered: backend.retry(win.currentId)
        }
        MenuItem {
            text: "New take"
            enabled: viewer.hasImage
            onTriggered: backend.newTake(win.currentId)
        }
        MenuItem {
            text: "Rename…"
            enabled: win.hasModel
            onTriggered: {
                win.detailsOpen = true
                details.focusRename()
            }
        }
        MenuItem {
            text: "Open in Blender"
            enabled: win.hasModel
            onTriggered: backend.openInBlender(win.currentId)
        }
        MenuItem {
            text: "Show in folder"
            onTriggered: backend.showInFolder(win.currentId)
        }
        MenuSeparator {}
        MenuItem {
            text: "Remove from list"
            onTriggered: backend.remove(win.currentId)
        }
        MenuItem {
            text: "Move to Bin"
            enabled: win.hasModel
            onTriggered: backend.moveToBin(win.currentId)
        }
    }

    Dialog {
        id: quitDialog
        anchors.centerIn: parent
        modal: true
        title: "Models are still being made"
        Label {
            text: "Quitting stops the engine. Unfinished ones stay in the list to try again."
            color: win.textColor
        }
        footer: DialogButtonBox {
            Button {
                text: "Keep working"
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
            }
            Button {
                text: "Quit"
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
        }
        onAccepted: {
            win.quitting = true
            win.close()
        }
    }

    Popup {
        id: helpSheet
        anchors.centerIn: parent
        modal: true
        padding: 24

        GridLayout {
            columns: 2
            columnSpacing: 32
            rowSpacing: 6

            Repeater {
                model: [
                    [
                        ["Ctrl+O", "Add images or models (or drag them in)"],
                        ["Ctrl+F", "Search the list"],
                        ["Up / Down", "Select"],
                        ["N", "New take (different seed)"],
                        ["Ctrl+R", "Try again"],
                        ["Esc", "Cancel"],
                        ["F2", "Rename the model file"],
                        ["Delete", "Remove from the list"],
                        ["Shift+Delete", "Move the model to the bin"],
                        ["Ctrl+B", "Open in Blender"],
                        ["Ctrl+E", "Show in folder"],
                        ["Ctrl+Q", "Quit"]
                    ],
                    [
                        ["Drag / scroll", "Orbit / zoom"],
                        ["R", "Reset the view"],
                        ["1 / 2 / 3", "Textured / clay / normals"],
                        ["W", "Wireframe"],
                        ["T", "Turntable"],
                        ["F", "Floor and shadow"],
                        ["C", "Compare with the photo"],
                        ["I", "Details panel"],
                        ["P", "Snapshot (PNG next to the model)"],
                        ["?", "This help"]
                    ]
                ]
                delegate: Column {
                    required property var modelData
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    Repeater {
                        model: parent.modelData
                        delegate: Row {
                            required property var modelData
                            spacing: 16
                            Label {
                                width: 110
                                text: modelData[0]
                                font.family: "monospace"
                                color: win.accent
                            }
                            Label {
                                text: modelData[1]
                                color: win.textColor
                            }
                        }
                    }
                }
            }
        }
    }
}
