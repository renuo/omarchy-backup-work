.pragma library

// Nerd Font Material Design glyphs.
var GLYPHS = {
  idle: "󰁯", // backup-restore
  running: "󰓦", // sync
  failed: "󰀨" // alert-circle
}

// A scheduled backup older than this has silently stopped working.
var STALE_SECONDS = 3 * 24 * 3600

var STEPS = ["settings", "remote", "password", "repository", "schedule"]

function pathFromUrl(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) s = s.substring(7)
  try {
    return decodeURIComponent(s)
  } catch (e) {
    return s
  }
}

function emptyState() {
  return {
    installed: true,
    config: false,
    excludes: false,
    password: false,
    repository: "",
    paths: "",
    forget: "",
    remote: "",
    remoteReady: false,
    initialized: false,
    timerEnabled: false,
    running: false,
    nextRun: 0,
    result: "",
    lastRun: 0,
    lastSuccess: 0
  }
}

function parseState(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null
  var state = emptyState()
  for (var key in state) {
    var value = parsed[key]
    if (typeof value === typeof state[key]) state[key] = value
  }
  return state
}

// Each setup step and whether it is done. The rclone step only exists for a
// repository that goes through rclone.
function steps(state) {
  var done = {
    settings: state.config && state.repository !== "" && state.paths !== "",
    remote: state.remoteReady,
    password: state.password,
    repository: state.initialized,
    schedule: state.timerEnabled
  }
  return STEPS.filter(function (id) {
    return id !== "remote" || state.remote !== ""
  }).map(function (id) {
    return { id: id, done: done[id] }
  })
}

// Everything a backup needs; the schedule is optional.
function ready(state) {
  return steps(state).every(function (step) {
    return step.done || step.id === "schedule"
  })
}

function phase(state, now) {
  if (!state) return "loading"
  if (!state.installed) return "missing"
  if (state.running) return "running"
  if (!ready(state)) return "setup"
  if (state.result !== "" && state.result !== "success") return "failed"
  if (state.lastSuccess === 0) return "never"
  if (!state.timerEnabled) return "off"
  if (now - state.lastSuccess > STALE_SECONDS) return "stale"
  return "ok"
}

function glyph(phase) {
  if (phase === "running") return GLYPHS.running
  if (phase === "failed" || phase === "stale") return GLYPHS.failed
  return GLYPHS.idle
}

function urgent(phase) {
  return phase === "failed" || phase === "stale"
}

function dimmed(phase) {
  return phase === "loading" || phase === "missing" || phase === "setup" || phase === "off"
}

// Single pass, so a "%2" or "$&" inside a value stays literal text.
function format(template, values) {
  return String(template).replace(/%(\d)/g, function (match, n) {
    var value = values[Number(n) - 1]
    return value === undefined ? match : String(value)
  })
}

function ago(seconds, now, strings) {
  var elapsed = Math.max(0, now - seconds)
  if (elapsed < 60) return strings.t("ago.now")
  if (elapsed < 3600) return format(strings.tn("ago.minutes", Math.floor(elapsed / 60)), [Math.floor(elapsed / 60)])
  if (elapsed < 2 * 86400) return format(strings.tn("ago.hours", Math.floor(elapsed / 3600)), [Math.floor(elapsed / 3600)])
  return format(strings.tn("ago.days", Math.floor(elapsed / 86400)), [Math.floor(elapsed / 86400)])
}

function heroMeta(state, now, strings) {
  var p = phase(state, now)
  if (p === "loading" || p === "missing" || p === "running" || p === "setup") return strings.t("phase." + p)
  if (p === "never") return strings.t("phase.never")
  var last = format(strings.t("last.success"), [ago(state.lastSuccess, now, strings)])
  if (p === "failed") return strings.t("phase.failed") + " · " + last
  return last
}

function tooltip(state, now, strings) {
  var p = phase(state, now)
  var meta = heroMeta(state, now, strings)
  if (p === "off") return meta + "\n" + strings.t("phase.off")
  if (p === "stale") return meta + "\n" + strings.t("phase.stale")
  return meta
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// Interactive steps run in Omarchy's floating terminal, which ends with a
// Done/Failed prompt so the outcome stays readable.
function terminalCommand(scriptPath, args) {
  var words = ["bash", scriptPath].concat(args).map(shellQuote)
  return ["omarchy-launch-floating-terminal-with-presentation", words.join(" ")]
}

// The first non-empty line of what ctl.sh printed is the error worth showing.
function replyError(text) {
  var lines = String(text || "").split("\n").map(function (line) { return line.trim() })
  for (var i = 0; i < lines.length; i++) if (lines[i] !== "") return lines[i]
  return ""
}
