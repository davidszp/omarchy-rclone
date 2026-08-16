import QtQuick

// One run through rclone's interactive config state machine, driven a step at a
// time by the `rclone-config` helper.
//
// Split out of Service.qml because it is the only stateful CONVERSATION in the
// plugin — everything else there is a fire-and-forget command plus a poll. It
// owns a half-built remote in the user's config for as long as it runs, which
// is why every failure path here ends in cleanup.
//
// Raises signals instead of calling back into the service, so the rules about
// what a half-finished flow leaves behind live in one file.
Item {
  id: flow

  property string pluginDir: ""

  // The step rclone is currently asking about, normalised by rclone-config.
  // An empty object means nothing is in progress.
  property var step: ({})
  property string name: ""
  property string type: ""

  readonly property bool active: name !== ""
  readonly property bool busy: stepRunner.running

  signal reported(string message, bool isError)
  // A remote was created and is ready to use.
  signal finished(string remoteName)
  // State changed on disk; the service should re-poll.
  signal refreshNeeded()

  // `seeds` is an optional array of "key=value" strings applied before the flow
  // begins, for backends that refuse to start without one — zoho exits
  // "Error: no region set" before its state machine runs (see
  // Model.quickProviders).
  function start(remoteName, backendType, seeds) {
    // `stepRunner.running` is false while a flow sits WAITING for an answer, so
    // guarding on it alone let a second flow overwrite the first — orphaning a
    // half-made remote in the config with nothing pointing at it.
    if (active || stepRunner.running) {
      reported("Finish or cancel the current setup first", true)
      return
    }
    name = String(remoteName)
    type = String(backendType)
    step = ({})
    var argv = [pluginDir + "rclone-config", "start", name, type]
    var extra = seeds || []
    for (var i = 0; i < extra.length; i++) argv.push(String(extra[i]))
    if (!stepRunner.start(argv)) return
    reported("Setting up " + type + "…", false)
  }

  function answer(value) {
    if (stepRunner.running || name === "") return
    var state = String(step.state || "")
    if (state === "") return
    // Answering the oauth step is what opens the browser, so this call can sit
    // for as long as the user takes to approve. No timeout on purpose.
    stepRunner.start([pluginDir + "rclone-config", "next", name, state, String(value)])
  }

  function abort() {
    var partial = name
    _clear()
    if (partial === "") return
    // Half-finished flows leave a partial remote behind; drop it rather than
    // leaving something broken in the config.
    //
    // Its OWN runner on purpose: sharing a general-purpose one meant a
    // concurrent daemon restart could make start() return false and the cleanup
    // silently not happen, leaving the orphan this function exists to remove.
    if (!cleanupRunner.start([pluginDir + "rclone-config", "abort", partial])) {
      reported("Could not clean up " + partial
               + " — remove it with: rclone config delete " + partial, true)
      return
    }
    reported("Setup cancelled", false)
  }

  function _clear() {
    name = ""
    type = ""
    step = ({})
  }

  function _applyStep(output) {
    var parsed
    try {
      parsed = JSON.parse(String(output || "").trim())
    } catch (e) {
      reported("Could not read the setup step", true)
      name = ""
      return
    }
    // Done ONLY when there is no state left. rclone returns intermediate steps
    // with a State but no Option, and treating those as finished is what
    // silently truncated OneDrive setup after the browser sign-in.
    if (parsed.done === true) {
      var completed = name
      _clear()
      reported("Connected " + completed, false)
      refreshNeeded()
      if (completed !== "") finished(completed)
      return
    }
    step = parsed
  }

  CommandRunner {
    id: stepRunner
    failMessage: "Setup step failed"
    onSucceeded: function(output) { flow._applyStep(output) }
    onFailed: function(message) {
      // A step that errors mid-flow leaves the same orphan a cancel would, so
      // clean up on this path too rather than only on the deliberate one.
      var partial = flow.name
      flow._clear()
      flow.reported(message, true)
      if (partial !== "") {
        cleanupRunner.start([flow.pluginDir + "rclone-config", "abort", partial])
      }
    }
  }

  CommandRunner {
    id: cleanupRunner
    failMessage: "Could not clean up the partial remote"
    onSucceeded: function() { flow.refreshNeeded() }
    onFailed: function(message) { flow.reported(message, true) }
  }
}
