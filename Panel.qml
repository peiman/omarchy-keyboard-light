import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar button and popup. The service owns the LED; this file owns the settings
// that live on the widget's shell.json entry, and pushes them across.
Panel {
  id: root
  moduleName: "io.github.peiman.keyboard-light"
  ipcTarget: "io.github.peiman.keyboard-light"
  manageIpc: false

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var config: Model.withDefaults(settings)

  readonly property bool available: service ? service.available : false
  readonly property bool hasSensor: service ? service.hasSensor : false
  readonly property int livePercent: service ? service.percent : 0
  readonly property var liveLux: service ? service.rawLux : null
  readonly property string sensorKind: service && service.sensorKind ? service.sensorKind : "none"
  readonly property bool held: service ? service.hold : false
  readonly property bool userIdle: service ? service.userIdle : false
  readonly property bool autoOn: config.auto && hasSensor && !held

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property int cursorIndex: 0
  property bool cursorActive: false

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  readonly property var rows: {
    var language = strings.language
    var list = []
    if (hasSensor) list.push("auto")
    list.push("idle")
    if (autoOn) {
      list.push("maxPercent")
      list.push("minPercent")
      list.push("luxDark")
      list.push("luxBright")
    } else {
      list.push("manualPercent")
    }
    return list
  }

  readonly property string statusText: {
    var language = strings.language
    if (!available) return strings.t("bar.noKeyboard")
    var level = strings.t("bar.level").arg(Commons.I18n.formatNumber(livePercent))
    var mode = userIdle ? strings.t("bar.idle")
      : (held ? strings.t("bar.held") : (config.auto && hasSensor ? strings.t("bar.auto") : strings.t("bar.manual")))
    if (!hasSensor || liveLux === null || liveLux === undefined)
      return strings.t("bar.statusPlain").arg(level).arg(mode)
    var light = strings.t(sensorKind === "raw" ? "bar.raw" : "bar.lux")
      .arg(Commons.I18n.formatNumber(Number(liveLux), Number(liveLux) < 10 ? 1 : 0))
    return strings.t("bar.status").arg(level).arg(light).arg(mode)
  }

  function rowIndex(key) { return rows.indexOf(key) }
  function hasCursorOn(key) { return cursorActive && rows[cursorIndex] === key }

  function moveCursor(delta) {
    cursorActive = true
    var next = cursorIndex + delta
    cursorIndex = Math.max(0, Math.min(rows.length - 1, next))
  }

  function sliderSpec(key) {
    if (key === "manualPercent" || key === "maxPercent" || key === "minPercent")
      return { minimum: 0, maximum: 100, step: 5 }
    if (key === "luxDark") return { minimum: 0, maximum: 500, step: 1 }
    if (key === "luxBright") return { minimum: 1, maximum: 2000, step: 10 }
    return null
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    pushSettings()
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function commitSetting(key, value) {
    var spec = sliderSpec(key)
    var next = value
    if (spec) next = Math.round(Math.max(spec.minimum, Math.min(spec.maximum, value)))
    if (Number(config[key]) === next) return
    var patch = {}
    patch[key] = next
    persistSettings(patch)
  }

  function toggleAuto() {
    if (!hasSensor) return
    if (config.auto) persistSettings({ auto: false, manualPercent: livePercent })
    else {
      persistSettings({ auto: true })
      if (service) service.clearHold()
    }
  }

  function setIdle(seconds) {
    persistSettings({ idleSeconds: Model.nearestPreset(seconds) })
  }

  function nudge(delta) {
    var base = config.auto && !held ? livePercent : (held && service ? service.holdPercent : config.manualPercent)
    var next = Model.clampPercent(base + delta)
    persistSettings({ auto: false, manualPercent: next })
    if (service) service.applyImmediate(next)
  }

  function useCurrentReading(key) {
    if (liveLux === null || liveLux === undefined) return
    commitSetting(key, Math.round(Number(liveLux)))
  }

  function adjustCursorRow(delta) {
    if (!cursorActive) return
    var key = rows[cursorIndex]
    if (key === "idle") {
      setIdle(Model.stepPreset(config.idleSeconds, delta))
      return
    }
    var spec = sliderSpec(key)
    if (!spec) return
    commitSetting(key, Number(config[key]) + spec.step * delta)
  }

  function activateCursorRow() {
    if (!cursorActive) return
    var key = rows[cursorIndex]
    if (key === "auto") toggleAuto()
    else if (key === "luxDark" || key === "luxBright") useCurrentReading(key)
  }

  function pushSettings() {
    if (service) service.settings = root.settings
  }

  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()
  onRowsChanged: if (cursorIndex >= rows.length) cursorIndex = Math.max(0, rows.length - 1)
  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (service) service.poll()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  visible: available
  implicitWidth: available ? button.implicitWidth : 0
  implicitHeight: available ? button.implicitHeight : 0

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onExternalSerialChanged() {
      if (!root.service || root.service.externalSerial === 0) return
      var pct = root.service.externalPercent
      if (!root.config.auto && Number(root.config.manualPercent) === pct) return
      root.persistSettings({ auto: false, manualPercent: pct })
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleAuto(): string { root.toggleAuto(); return root.config.auto ? "auto" : "manual" }
    function up(): string { root.nudge(10); return String(root.config.manualPercent) }
    function down(): string { root.nudge(-10); return String(root.config.manualPercent) }
    function status(): string {
      var mode = root.userIdle ? "idle" : (root.held ? "held" : (root.config.auto && root.hasSensor ? "auto" : "manual"))
      return Model.statusLine(root.livePercent, root.hasSensor ? root.liveLux : null, root.sensorKind, mode)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF030C)
    foreground: root.livePercent <= 0
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45 + 0.55 * root.livePercent / 100)
    tooltipText: root.statusText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.hasSensor) root.toggleAuto()
        else {
          var next = root.livePercent > 0 ? 0 : Math.max(root.config.manualPercent, 40)
          root.persistSettings({ auto: false, manualPercent: next })
          if (root.service) root.service.applyImmediate(next)
        }
      } else {
        root.toggle()
      }
    }
    onWheelMoved: function(delta) { root.nudge(delta > 0 ? 10 : -10) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursorRow(dx)
      }
      onActivateRequested: root.activateCursorRow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "a" || text === "A") root.toggleAuto()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: strings.t("panel.title")
              meta: root.statusText
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: String.fromCodePoint(0xF030C)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: autoSwitch
                  visible: root.hasSensor
                  checked: root.config.auto
                  hasCursor: root.hasCursorOn("auto")
                  foreground: root.foreground
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.cursorIndex = Math.max(0, root.rowIndex("auto"))
                  }
                  onToggled: root.toggleAuto()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.hasSensor
            width: parent.width
            text: strings.t("panel.noSensor")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.held
            width: parent.width
            text: strings.t("panel.held").arg(Commons.I18n.formatNumber(root.service ? root.service.holdPercent : root.livePercent))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: strings.t("panel.idle")
            foreground: root.hasCursorOn("idle") ? root.foreground : root.dim
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: strings.t("panel.idleHelp")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.controlGap

            Repeater {
              model: [
                { seconds: 0, key: "panel.idle0" },
                { seconds: 5, key: "panel.idle5" },
                { seconds: 10, key: "panel.idle10" },
                { seconds: 30, key: "panel.idle30" },
                { seconds: 60, key: "panel.idle60" },
                { seconds: 300, key: "panel.idle300" }
              ]
              delegate: Button {
                required property var modelData
                readonly property bool chosen: root.config.idleSeconds === modelData.seconds
                text: strings.t(modelData.key)
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                bordered: true
                selected: chosen
                hasCursor: root.hasCursorOn("idle") && chosen
                onClicked: root.setIdle(modelData.seconds)
                onHovered: function(on) {
                  if (!on) return
                  root.cursorActive = true
                  root.cursorIndex = Math.max(0, root.rowIndex("idle"))
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            visible: !root.autoOn
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("panel.level")
              foreground: root.hasCursorOn("manualPercent") ? root.foreground : root.dim
              fontFamily: root.fontFamily
            }

            SettingSlider {
              width: parent.width
              settingKey: "manualPercent"
              label: strings.t("panel.level")
              suffix: "%"
              live: true
            }
          }

          Column {
            visible: root.autoOn
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("panel.room")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.roomHelp")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            SettingSlider {
              width: parent.width
              settingKey: "maxPercent"
              label: strings.t("panel.inDark")
              suffix: "%"
            }

            SettingSlider {
              width: parent.width
              settingKey: "minPercent"
              label: strings.t("panel.inBright")
              suffix: "%"
            }

            SettingSlider {
              width: parent.width
              settingKey: "luxDark"
              label: strings.t("panel.darkBelow")
              suffix: root.sensorKind === "raw" ? "" : " lx"
              showUseCurrent: true
            }

            SettingSlider {
              width: parent.width
              settingKey: "luxBright"
              label: strings.t("panel.brightAbove")
              suffix: root.sensorKind === "raw" ? "" : " lx"
              showUseCurrent: true
            }
          }

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: strings.t("panel.hint")
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component SettingSlider: Column {
    id: rowRoot

    property string settingKey: ""
    property string label: ""
    property string suffix: ""
    property bool showUseCurrent: false
    property bool live: false

    readonly property var spec: root.sliderSpec(settingKey)
    readonly property int currentValue: Math.round(Number(root.config[settingKey]))
    readonly property bool focused: root.hasCursorOn(settingKey)
    readonly property bool canUseReading: showUseCurrent && root.liveLux !== null && root.liveLux !== undefined

    spacing: Style.spacing.labelGap

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Text {
        textFormat: Text.PlainText
        width: parent.width - valueText.implicitWidth - parent.spacing
          - (useCurrent.visible ? useCurrent.implicitWidth + parent.spacing : 0)
        text: rowRoot.label
        color: rowRoot.focused ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }

      Button {
        id: useCurrent
        visible: rowRoot.canUseReading
        text: strings.t("panel.useReading").arg(Commons.I18n.formatNumber(Math.round(Number(root.liveLux))))
        fontSize: Style.font.caption
        foreground: root.foreground
        bordered: true
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.useCurrentReading(rowRoot.settingKey)
        onHovered: function(on) {
          if (!on) return
          root.cursorActive = true
          root.cursorIndex = Math.max(0, root.rowIndex(rowRoot.settingKey))
        }
      }

      Text {
        id: valueText
        textFormat: Text.PlainText
        text: rowRoot.currentValue + rowRoot.suffix
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelSlider {
      width: parent.width
      bar: root.bar
      value: rowRoot.currentValue
      minimum: rowRoot.spec ? rowRoot.spec.minimum : 0
      maximum: rowRoot.spec ? rowRoot.spec.maximum : 100
      step: rowRoot.spec ? rowRoot.spec.step : 1
      integer: true
      fillColor: rowRoot.focused ? root.foreground : Qt.darker(root.foreground, 1.25)
      onMoved: function(value) {
        root.cursorActive = true
        root.cursorIndex = Math.max(0, root.rowIndex(rowRoot.settingKey))
        if (rowRoot.live && root.service) root.service.applyImmediate(value)
      }
      onReleased: function(value) { root.commitSetting(rowRoot.settingKey, value) }
    }
  }
}
