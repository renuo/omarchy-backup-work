const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { loadModel } = require("./load-model")

const Model = loadModel()

// Values built inside the vm context carry that context's prototypes, which
// deepStrictEqual would reject; compare their JSON shape instead.
const plain = (value) => JSON.parse(JSON.stringify(value))

// Stands in for Commons.Translations, reading the shipped English catalog so a
// renamed or missing key fails here rather than showing up as a raw key.
const catalog = require(path.join(__dirname, "..", "i18n", "en.json"))
const strings = {
  t: (key) => {
    assert.ok(key in catalog, "missing key " + key)
    return catalog[key]
  },
  tn: (key, count) => catalog[key][count === 1 ? "one" : "other"],
}

const NOW = 1762600000
const HOUR = 3600
const DAY = 24 * HOUR

// A machine where everything is set up and the last backup ran an hour ago.
function healthy(fields) {
  return Object.assign(plain(Model.emptyState()), {
    config: true,
    excludes: true,
    password: true,
    repository: "rclone:gdrive:Backups/work",
    paths: "/home/me/Work",
    forget: "--keep-daily 7",
    remote: "gdrive",
    remoteReady: true,
    initialized: true,
    timerEnabled: true,
    result: "success",
    lastRun: NOW - HOUR,
    lastSuccess: NOW - HOUR,
  }, fields)
}

describe("pathFromUrl", () => {
  it("strips file:// and decodes", () => {
    assert.equal(Model.pathFromUrl("file:///a/my%20plugin/ctl.sh"), "/a/my plugin/ctl.sh")
  })

  it("passes plain and undecodable paths through", () => {
    assert.equal(Model.pathFromUrl("/a/ctl.sh"), "/a/ctl.sh")
    assert.equal(Model.pathFromUrl("file:///a/%E0%A4%A"), "/a/%E0%A4%A")
    assert.equal(Model.pathFromUrl(undefined), "")
  })
})

describe("parseState", () => {
  it("reads what ctl.sh state prints", () => {
    const state = healthy({ nextRun: NOW + DAY })
    assert.deepEqual(plain(Model.parseState(JSON.stringify(state))), state)
  })

  it("fills missing fields and drops ones of the wrong type", () => {
    const state = plain(Model.parseState('{"config":"yes","repository":"/r"}'))
    assert.equal(state.config, false)
    assert.equal(state.repository, "/r")
    assert.equal(state.lastRun, 0)
  })

  it("reads anything that is not an object as no state", () => {
    assert.equal(Model.parseState("oops"), null)
    assert.equal(Model.parseState("[]"), null)
    assert.equal(Model.parseState("null"), null)
    assert.equal(Model.parseState(undefined), null)
  })
})

describe("steps", () => {
  it("lists every step in order, done on a healthy machine", () => {
    assert.deepEqual(plain(Model.steps(healthy())), [
      { id: "settings", done: true },
      { id: "remote", done: true },
      { id: "password", done: true },
      { id: "repository", done: true },
      { id: "schedule", done: true },
    ])
  })

  it("starts with nothing done", () => {
    assert.ok(plain(Model.steps(plain(Model.emptyState()))).every((step) => !step.done))
  })

  it("skips the rclone step for a repository rclone does not reach", () => {
    const ids = plain(Model.steps(healthy({ repository: "/mnt/usb", remote: "" }))).map((step) => step.id)
    assert.deepEqual(ids, ["settings", "password", "repository", "schedule"])
  })

  it("wants a repository and paths before the settings count", () => {
    assert.equal(plain(Model.steps(healthy({ paths: "" })))[0].done, false)
    assert.equal(plain(Model.steps(healthy({ repository: "" })))[0].done, false)
    assert.equal(plain(Model.steps(healthy({ config: false })))[0].done, false)
  })
})

describe("ready", () => {
  it("needs every step but the schedule", () => {
    assert.equal(Model.ready(healthy({ timerEnabled: false })), true)
    assert.equal(Model.ready(healthy({ remoteReady: false })), false)
    assert.equal(Model.ready(healthy({ password: false })), false)
    assert.equal(Model.ready(healthy({ initialized: false })), false)
  })
})

describe("phase", () => {
  it("is ok after a recent success on schedule", () => {
    assert.equal(Model.phase(healthy(), NOW), "ok")
  })

  it("waits for the first state", () => {
    assert.equal(Model.phase(null, NOW), "loading")
  })

  it("puts a missing restic first", () => {
    assert.equal(Model.phase(healthy({ installed: false, running: true }), NOW), "missing")
  })

  it("shows a running backup even while the setup is incomplete", () => {
    assert.equal(Model.phase(healthy({ running: true, initialized: false }), NOW), "running")
  })

  it("asks for the setup before reporting runs", () => {
    assert.equal(Model.phase(healthy({ password: false, result: "exit-code" }), NOW), "setup")
  })

  it("reports a failed last run", () => {
    assert.equal(Model.phase(healthy({ result: "exit-code" }), NOW), "failed")
  })

  it("knows a ready machine that never backed up", () => {
    assert.equal(Model.phase(healthy({ result: "", lastRun: 0, lastSuccess: 0 }), NOW), "never")
  })

  it("notices the schedule is off", () => {
    assert.equal(Model.phase(healthy({ timerEnabled: false }), NOW), "off")
  })

  it("calls a scheduled backup stale after three days without success", () => {
    assert.equal(Model.phase(healthy({ lastSuccess: NOW - 3 * DAY + 1 }), NOW), "ok")
    assert.equal(Model.phase(healthy({ lastSuccess: NOW - 3 * DAY - 1 }), NOW), "stale")
  })
})

describe("glyph, urgent and dimmed", () => {
  it("spins while running and alerts when something is wrong", () => {
    assert.equal(Model.glyph("running"), "\u{F04E6}")
    assert.equal(Model.glyph("failed"), "\u{F0028}")
    assert.equal(Model.glyph("stale"), "\u{F0028}")
    assert.equal(Model.glyph("ok"), "\u{F006F}")
  })

  it("is urgent only when backups stopped working", () => {
    assert.deepEqual(["ok", "failed", "stale", "setup"].map(Model.urgent), [false, true, true, false])
  })

  it("dims while there is nothing to trust yet", () => {
    assert.deepEqual(["loading", "missing", "setup", "off", "ok", "never"].map(Model.dimmed), [true, true, true, true, false, false])
  })
})

describe("format", () => {
  it("fills placeholders once and keeps unknown ones", () => {
    assert.equal(Model.format("%1 → %2 %3", ["$&", "%2"]), "$& → %2 %3")
  })
})

describe("ago", () => {
  it("rounds down to the largest unit that fits", () => {
    assert.equal(Model.ago(NOW - 30, NOW, strings), "just now")
    assert.equal(Model.ago(NOW - 60, NOW, strings), "1 minute ago")
    assert.equal(Model.ago(NOW - 59 * 60, NOW, strings), "59 minutes ago")
    assert.equal(Model.ago(NOW - HOUR, NOW, strings), "1 hour ago")
    assert.equal(Model.ago(NOW - 47 * HOUR, NOW, strings), "47 hours ago")
    assert.equal(Model.ago(NOW - 2 * DAY, NOW, strings), "2 days ago")
  })

  it("treats a clock running behind as just now", () => {
    assert.equal(Model.ago(NOW + 100, NOW, strings), "just now")
  })
})

describe("heroMeta", () => {
  it("says when the last backup succeeded", () => {
    assert.equal(Model.heroMeta(healthy(), NOW, strings), "Last backup 1 hour ago")
  })

  it("puts a failure before the last success", () => {
    assert.equal(Model.heroMeta(healthy({ result: "exit-code" }), NOW, strings), "Last backup failed · Last backup 1 hour ago")
  })

  it("names the phases that have no last backup to tell", () => {
    assert.equal(Model.heroMeta(null, NOW, strings), "Loading…")
    assert.equal(Model.heroMeta(healthy({ running: true }), NOW, strings), "Backing up…")
    assert.equal(Model.heroMeta(healthy({ initialized: false }), NOW, strings), "Not set up yet")
    assert.equal(Model.heroMeta(healthy({ lastSuccess: 0, result: "" }), NOW, strings), "No backup yet")
    assert.match(Model.heroMeta(healthy({ installed: false }), NOW, strings), /not installed/)
  })
})

describe("tooltip", () => {
  it("adds why the widget is dimmed or urgent", () => {
    assert.equal(Model.tooltip(healthy({ timerEnabled: false }), NOW, strings), "Last backup 1 hour ago\nHourly backups are off")
    assert.equal(Model.tooltip(healthy({ lastSuccess: NOW - 4 * DAY }), NOW, strings), "Last backup 4 days ago\nNo successful backup for days")
  })

  it("is the hero line otherwise", () => {
    assert.equal(Model.tooltip(healthy(), NOW, strings), "Last backup 1 hour ago")
  })
})

describe("terminalCommand", () => {
  it("runs the script in Omarchy's floating terminal with every word quoted", () => {
    assert.deepEqual(plain(Model.terminalCommand("/p/ctl.sh", ["init", "it's"])), [
      "omarchy-launch-floating-terminal-with-presentation",
      "'bash' '/p/ctl.sh' 'init' 'it'\\''s'",
    ])
  })
})

describe("replyError", () => {
  it("takes the first line with text and nothing from a quiet success", () => {
    assert.equal(Model.replyError("\n Unit not found\nmore"), "Unit not found")
    assert.equal(Model.replyError(""), "")
    assert.equal(Model.replyError(undefined), "")
  })
})
