import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup. The button says whether backups still happen. The
// popup walks through the setup one step at a time and then offers the
// backups themselves. The settings are restic's own environment variables in
// ~/.config/restic/backup.env, which systemd hands to restic-backup.service;
// the popup opens that file in the editor instead of copying it into
// controls. Everything that talks to a person runs in Omarchy's floating
// terminal through ctl.sh, and the popup steps aside for it.
Panel {
  id: root
  moduleName: "renuo.restic"
  ipcTarget: "restic"

  readonly property string ctlPath: Model.pathFromUrl(Qt.resolvedUrl("ctl.sh"))

  property var backupState: null
  property real now: Date.now() / 1000
  property string actionError: ""
  property string notice: ""
  // What the schedule switch was last asked for, until systemd answers.
  property var pendingTimer: null

  readonly property string phase: Model.phase(backupState, now)
  readonly property var steps: backupState ? Model.steps(backupState) : []
  readonly property bool ready: backupState !== null && Model.ready(backupState)
  readonly property bool timerOn: pendingTimer !== null ? pendingTimer : (backupState !== null && backupState.timerEnabled)

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function refresh() {
    now = Date.now() / 1000
    if (stateProc.running) stateProc.again = true
    else stateProc.running = true
  }

  function run(args) {
    actionError = ""
    notice = ""
    actionProc.command = ["bash", ctlPath].concat(args)
    actionProc.running = true
  }

  function setTimer(on) {
    if (pendingTimer !== null) return
    pendingTimer = on
    run(["timer", on ? "on" : "off"])
  }

  // The terminal, the editor and other panels open behind a popup that holds
  // the keyboard.
  function inTerminal(args) {
    Quickshell.execDetached(Model.terminalCommand(ctlPath, args))
    close()
  }

  function edit(what) {
    Quickshell.execDetached(["bash", ctlPath, "edit", what])
    close()
  }

  function openRclone() {
    close()
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "renuo.rclone"])
  }

  function copyPassword() {
    run(["copy-password"])
    notice = strings.t("copied")
  }

  function stepDetail(step) {
    var s = backupState
    if (!step.done) {
      if (step.id === "remote") return Model.format(strings.t("step.remote.todo"), [s.remote])
      return strings.t("step." + step.id + ".todo")
    }
    if (step.id === "settings") {
      var text = Model.format(strings.t("step.settings.done"), [s.paths, s.repository])
      return s.forget !== "" ? text + "\n" + Model.format(strings.t("keep"), [s.forget]) : text
    }
    if (step.id === "remote") return Model.format(strings.t("step.remote.done"), [s.remote])
    if (step.id === "schedule") return s.nextRun > 0
      ? Model.format(strings.t("step.schedule.done"), [Qt.formatDateTime(new Date(s.nextRun * 1000), "ddd d MMM, HH:mm")])
      : strings.t("step.schedule.unknown")
    return strings.t("step." + step.id + ".done")
  }

  onOpenedChanged: if (opened) {
    actionError = ""
    notice = ""
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: stateProc
    property bool again: false
    command: ["bash", root.ctlPath, "state"]
    onRunningChanged: if (!running && again) {
      again = false
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseState(text)
        if (parsed) root.backupState = parsed
        if (!actionProc.running) root.pendingTimer = null
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.actionError = Model.replyError(text)
        if (root.actionError !== "") root.notice = ""
        root.refresh()
      }
    }
  }

  // Quick while someone looks or a backup runs; a minute otherwise is plenty
  // for a daily job.
  Timer {
    interval: root.opened || root.phase === "running" ? 2000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.glyph(root.phase)
    dimmed: Model.dimmed(root.phase)
    active: Model.urgent(root.phase)
    tooltipText: root.opened ? "" : Model.tooltip(root.backupState, root.now, strings)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(680))

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("title")
            meta: Model.heroMeta(root.backupState, root.now, strings)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: Model.dimmed(root.phase) ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                text: Model.glyph(root.phase)
                textFormat: Text.PlainText
                color: Model.urgent(root.phase) ? root.urgent : hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: timerSwitch
                checked: root.timerOn
                busy: root.pendingTimer !== null
                interactive: root.ready || root.timerOn
                foreground: hero.foreground
                onToggled: root.setTimer(!root.timerOn)

                PanelToolTip {
                  visible: timerSwitch.containsMouse
                  text: strings.t(root.timerOn ? "toggle.off" : root.ready ? "toggle.on" : "toggle.notReady")
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Note {
            visible: root.actionError !== ""
            text: root.actionError
            color: root.urgent
          }

          Note {
            visible: root.notice !== ""
            text: root.notice
          }

          // ---------- Backups, once there is somewhere to put them ----------
          Column {
            visible: root.ready || root.phase === "running"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: strings.t("section.backups")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Action {
                visible: root.phase !== "running"
                text: strings.t("action.backup")
                iconText: "󰐊" // play
                onClicked: root.run(["backup"])
              }

              Action {
                visible: root.phase === "running"
                text: strings.t("action.stop")
                iconText: "󰓛" // stop
                onClicked: root.run(["stop"])
              }

              Action {
                text: strings.t("action.log")
                onClicked: root.inTerminal(["log"])
              }

              Action {
                text: strings.t("action.snapshots")
                onClicked: root.inTerminal(["snapshots"])
              }

              Action {
                text: strings.t("action.browse")
                onClicked: root.inTerminal(["browse"])
              }

              Action {
                text: strings.t("action.shell")
                onClicked: root.inTerminal(["shell"])
              }
            }
          }

          // ---------- Setup, one step after the other ----------
          PanelSectionHeader {
            visible: root.steps.length > 0
            text: strings.t("section.setup")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.steps

            StepRow {
              required property var modelData
              width: column.width
              step: modelData
            }
          }
        }
      }
    }
  }

  component Note: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  component Action: Button {
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  component StepRow: Item {
    id: stepRow
    property var step: ({ id: "", done: false })

    implicitHeight: stepColumn.implicitHeight

    Text {
      id: stepIcon
      anchors.left: parent.left
      anchors.top: parent.top
      text: stepRow.step.done ? "󰗠" : "󰝦" // check-circle, circle-outline
      textFormat: Text.PlainText
      color: stepRow.step.done ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }

    Column {
      id: stepColumn
      anchors.left: stepIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: strings.t("step." + stepRow.step.id)
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Note {
        text: root.backupState ? root.stepDetail(stepRow.step) : ""
      }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        Action {
          visible: stepRow.step.id === "settings"
          text: strings.t("action.edit")
          onClicked: root.edit("config")
        }

        Action {
          visible: stepRow.step.id === "settings"
          text: strings.t("action.excludes")
          onClicked: root.edit("excludes")
        }

        Action {
          visible: stepRow.step.id === "remote" && !stepRow.step.done
          text: strings.t("action.openRclone")
          onClicked: root.openRclone()
        }

        Action {
          visible: stepRow.step.id === "password" && !stepRow.step.done
          text: strings.t("action.createPassword")
          onClicked: root.run(["password"])
        }

        Action {
          visible: stepRow.step.id === "password" && stepRow.step.done
          text: strings.t("action.copyPassword")
          onClicked: root.copyPassword()
        }

        Action {
          visible: stepRow.step.id === "repository" && !stepRow.step.done
          enabled: root.backupState !== null && root.backupState.password && root.backupState.config
          text: strings.t("action.init")
          onClicked: root.inTerminal(["init"])
        }

        Action {
          visible: stepRow.step.id === "schedule"
          text: strings.t("action.schedule")
          onClicked: root.inTerminal(["schedule"])
        }
      }
    }
  }
}
