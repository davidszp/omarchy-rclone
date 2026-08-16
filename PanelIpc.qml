import QtQuick
import Quickshell.Io
import "Model.js" as Model

// The plugin's scripting surface: `omarchy-shell davidszp.rclone <function>`.
//
// Split out of Panel.qml because it is a stable API rather than part of the
// view — it changes for different reasons and at a different rate than the
// layout above it, and burying 70 lines of it in the middle of the panel made
// both harder to read.
//
// Two jobs, deliberately combined: it is how a keybind or script drives the
// panel, and it is how test/panel-test.sh drives it. Anything that can only be
// reached with a mouse cannot be tested at all here, so actions the UI performs
// on click are mirrored as functions — see openFolder and clearRecents.
//
// EVERY function returns a string saying what happened rather than a bare "ok".
// A caller that cannot distinguish "did it" from "refused" will assume success:
// clearRecents() once returned "ok" unconditionally and hid a no-op for a
// whole debugging session.
IpcHandler {
  id: ipc

  // The panel this drives, and the service behind it. Passed in rather than
  // reached for, so this file has no opinion about where it is instantiated.
  property QtObject panel: null
  property QtObject service: null

  // ---- Panel visibility ------------------------------------------------------
  function open(): void { ipc.panel.open() }
  function close(): void { ipc.panel.close() }
  function toggle(): void { ipc.panel.toggle() }

  // ---- Reading state ---------------------------------------------------------
  function status(): string { return ipc.service.statusText }
  function refresh(): string { ipc.service.refresh(); return "ok" }
  function probe(): string { ipc.service.probe(); return "ok" }

  // The config generation the widget has seen. Exposed because the daemon cache
  // clear it drives is invisible by design — without this the only way to tell
  // "never fired" from "fired and rebuilt" is to guess.
  function configGen(): string { return String(ipc.service._configMtime) }

  // ---- Actions that also exist as buttons ------------------------------------
  // The same action a double click on a row performs. Exposed so it can be
  // tested without synthesising mouse events, and so a Hyprland keybind can
  // jump straight to a mount without opening the panel at all.
  function openFolder(name: string): string {
    var mount = ipc.service.mountForRemote(String(name))
    if (!mount || !mount.mountPoint) return "not mounted: " + name
    ipc.service.openMount(mount)
    ipc.panel.close()
    return String(mount.mountPoint)
  }

  // What the RECENT header's broom does.
  function clearRecents(): string { return String(ipc.service.clearRecents()) }

  // ---- Provider setup --------------------------------------------------------
  // Opens the panel straight into the guided Google Drive setup.
  function setup(): string { ipc.panel.open(); ipc.panel.setupOpen = true; return "ok" }
  function setupOpened(): bool { return ipc.panel.setupOpen }

  // Which backend's extra question is showing, or "" for none. Some providers
  // need a value before rclone will start (zoho's region), and that step is
  // otherwise invisible to a script: no flow exists yet, so flowAsks() still
  // answers "(no flow)" and a broken seed picker looks exactly like a working one.
  function seedAsks(): string { return ipc.panel.seedFor === "" ? "(none)" : ipc.panel.seedFor }

  // Start a provider setup flow by backend type, e.g. `connect box`.
  function connect(type: string): string {
    if (!ipc.service.rcRunning) return "rcd not running"
    // Report the refusal rather than always answering "ok" — a caller that
    // cannot tell the difference will assume its flow started.
    if (ipc.service.flowActive) return "busy: " + ipc.service.flowName + " is mid-setup"
    ipc.panel.open()
    ipc.service.startProviderFlow(
      Model.suggestRemoteName(type, ipc.service.remotes), type)
    return "ok"
  }

  function cancel(): string { ipc.service.abortFlow(); return "ok" }

  // Answer the current flow step. Pairs with flowAsks() so a whole setup can be
  // driven from a script — which is how the multi-step path is tested without a
  // live account to authenticate against.
  function answer(value: string): string {
    if (!ipc.service.flowActive) return "(no flow)"
    ipc.service.answerFlow(value)
    return "ok"
  }

  // What the flow is currently asking.
  function flowAsks(): string {
    return ipc.service.flowActive
      ? String(ipc.service.flowStep.name || "(starting)") : "(no flow)"
  }

  // ---- Keyboard navigation ---------------------------------------------------
  function cursor(): string { return ipc.panel.cursorText() }

  // Move the cursor without a keypress. Pairs with cursor() so navigation can be
  // driven and asserted from a script — and useful for binding panel navigation
  // to something other than the panel's own key handler.
  function nav(dx: int, dy: int): string {
    ipc.panel.cursorActive = true
    ipc.panel.moveCursor(dx, dy)
    return ipc.panel.cursorText()
  }

  function activate(): string {
    ipc.panel.activateCursor()
    return ipc.panel.cursorText()
  }

  // What the cursor would act on, and whether the service can act at all. Added
  // because an activate() that silently did nothing gave no way to tell a wrong
  // target from a blocked runner.
  function target(): string {
    return ipc.panel.focusedActionName() + (ipc.service.busy ? " (busy)" : "")
      + " rc=" + (ipc.service.rcRunning ? "up" : "down")
      + " suppressed=" + JSON.stringify(ipc.service.suppressedPaths())
  }
}
