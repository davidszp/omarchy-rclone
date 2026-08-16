import QtQuick
import Quickshell.Io

// One external command, with the handling every call in this plugin needs:
// collect output, keep the last meaningful line of an error, and report
// success/failure as signals instead of duplicating an onExited block per call.
//
// Output is accumulated from a SplitParser rather than a StdioCollector so the
// same component serves both users: callers that want the whole payload at the
// end (`succeeded`) and callers that must react mid-run (`line`) — which the
// OAuth flow needs, because rclone may print an auth URL and then keep running.
Process {
  id: root

  // Handed over stdin and cleared the moment it is written. argv is readable by
  // any process via `ps`; stdin is not. Same handling as the enterprise Wi-Fi
  // passphrase in Omarchy's own network panel.
  property string secret: ""
  property string failMessage: "Command failed"

  readonly property string output: _buffer

  signal succeeded(string output)
  signal failed(string message)
  signal line(string text)

  // A plain string, NOT a var array. Pushing onto a `property var` array mutates
  // it in place, which emits no change signal, so anything bound to it keeps the
  // old value — that silently produced empty output for every command here.
  // String assignment notifies, so this cannot regress the same way.
  property string _buffer: ""

  // Returns false when a run is already in flight, so callers can decide
  // whether that is worth reporting rather than silently dropping the request.
  function start(argv) {
    if (running) return false
    _buffer = ""
    command = argv
    running = true
    return true
  }

  // Errors are far more useful from the end than the start: rclone and
  // systemctl both print context first and the actual failure last.
  function _lastMeaningfulLine() {
    var lines = _buffer.split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim() !== "") return lines[i].trim()
    }
    return ""
  }

  function _note(data) {
    var text = String(data === undefined || data === null ? "" : data)
    _buffer = _buffer === "" ? text : _buffer + "\n" + text
    line(text)
  }

  running: false
  command: []
  // Only open stdin when there is something to write. Leaving it open would
  // hang any child that reads to EOF.
  stdinEnabled: secret !== ""

  onStarted: {
    if (secret === "") return
    write(secret + "\n")
    secret = ""
  }

  stdout: SplitParser { onRead: function(data) { root._note(data) } }
  stderr: SplitParser { onRead: function(data) { root._note(data) } }

  onExited: function(exitCode) {
    if (exitCode === 0) succeeded(root.output)
    else failed(root._lastMeaningfulLine() || root.failMessage)
  }
}
