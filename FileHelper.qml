import QtQuick
import Quickshell.Io

// argv-array wrapper around bin/safe-file.py. One request at a time.
Item {
  id: root

  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("bin/safe-file.py"))
    if (url.indexOf("file://") === 0)
      return url.slice(7)
    return url
  }

  property bool busy: false
  property string lastError: ""

  property var _queue: []
  property var _callback: null
  property string _payload: ""
  property string _stdout: ""
  property int _maxBytes: 1048576 + 16

  function run(op, payload, callback) {
    var allowed = {
      "read-hyprland": true,
      "write-hyprland": true,
      "read-config": true,
      "write-config": true,
      "read-state": true,
      "write-state": true
    }
    if (!allowed[op]) {
      if (typeof callback === "function")
        callback(false, "REFUSED", "")
      return
    }
    var idle = !root.busy && !proc.running
    root._queue.push({ op: op, payload: payload || "", callback: callback })
    if (idle)
      root._startNext()
  }

  function _startNext() {
    if (root._queue.length === 0) {
      root.busy = false
      return
    }
    var job = root._queue.shift()
    root.busy = true
    root.lastError = ""
    root._callback = job.callback
    root._payload = job.payload
    root._stdout = ""
    proc.stdinEnabled = true
    proc.command = ["/usr/bin/python3", "-I", "-S", "--", root.helperPath, job.op]
    deadline.restart()
    proc.running = true
  }

  function _finish(ok, status, body) {
    deadline.stop()
    killTimer.stop()
    var cb = root._callback
    root._callback = null
    root._payload = ""
    root._stdout = ""
    if (!ok)
      root.lastError = root._plain(status || "file helper failed", 200)
    if (typeof cb === "function")
      cb(ok, status, body)
    Qt.callLater(root._startNext)
  }

  function _plain(value, maxLen) {
    var text = String(value || "")
    var out = ""
    for (var i = 0; i < text.length && out.length < maxLen; i++) {
      var code = text.charCodeAt(i)
      if (code === 60 || code === 62 || code === 38) continue
      if (code < 32 || code === 127) continue
      out += text.charAt(i)
    }
    return out
  }

  function _parse(buf) {
    var nl = buf.indexOf("\n")
    var header = nl === -1 ? buf : buf.substring(0, nl)
    var body = nl === -1 ? "" : buf.substring(nl + 1)
    return { header: header, body: body }
  }

  Process {
    id: proc
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (chunk) {
        if (root._stdout.length + String(chunk).length > root._maxBytes) {
          proc.signal(15)
          killTimer.start()
          return
        }
        root._stdout += chunk
      }
    }
    onStarted: {
      if (root._payload.length > 0)
        write(root._payload)
      proc.stdinEnabled = false
    }
    onExited: function (code, status) {
      var parsed = root._parse(root._stdout)
      if (parsed.header === "OK")
        root._finish(true, "OK", parsed.body)
      else if (parsed.header === "MISSING")
        root._finish(true, "MISSING", "")
      else
        root._finish(false, parsed.header || ("exit " + code), parsed.body)
    }
  }

  Timer {
    id: deadline
    interval: 15000
    repeat: false
    onTriggered: {
      proc.signal(15)
      killTimer.start()
    }
  }

  Timer {
    id: killTimer
    interval: 2000
    repeat: false
    onTriggered: proc.signal(9)
  }

  Component.onDestruction: {
    if (proc.running)
      proc.signal(15)
  }
}
