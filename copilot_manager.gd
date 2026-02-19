@tool
extends Node

signal suggestion_received(text: String)
signal auth_status_changed(authenticated: bool)
signal auth_device_code_ready(user_code: String, verify_uri: String)
signal auth_error(message: String)
signal status_message(text: String)

var _DEBUG:         bool = false

var _alive:         bool = false
var _starting:      bool = false
var _initialized:   bool = false
var _authenticated: bool = false

var _relay_pid:  int = -1
var _tcp_server: TCPServer
var _tcp_peer:   StreamPeerTCP
var _tcp_port:   int = 0

var _rpc_id:    int = 1
var _callbacks: Dictionary = {}

var _read_buf:     String = ""
var _recv_buffer: PackedByteArray = PackedByteArray()
var _doc_versions: Dictionary = {}
var _pending_comp_id = null

var _relay_log_path: String = ""

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _process(_dt: float) -> void:
	_poll_tcp()

func _exit_tree() -> void:
	_shutdown()

# ── Public API ────────────────────────────────────────────────────────────────

func is_authenticated() -> bool:
	return _authenticated

func start_sign_in() -> void:
	if _starting:
		_log("Already starting, please wait…")
		return
	if _alive:
		if _initialized:
			_do_sign_in()
		else:
			_log("LSP alive but not initialized yet, waiting…")
		return
	var err := _start_lsp()
	if not err.is_empty():
		auth_error.emit(err)

func sign_out() -> void:
	if _initialized:
		_notify("signOut", {})
	_authenticated = false
	auth_status_changed.emit(false)
	status_message.emit("Signed out")

func request_completion(text: String, line: int, col: int, uri: String) -> void:
	if not _authenticated or not _initialized:
		return
	_sync_doc(uri, text)
	if _pending_comp_id != null:
		_notify("$/cancelRequest", {"id": _pending_comp_id})
		_callbacks.erase(_pending_comp_id)
		_pending_comp_id = null
	var id := _next_id()
	_pending_comp_id = id
	_request("textDocument/inlineCompletion", {
		"textDocument": {"uri": uri},
		"position":     {"line": line, "character": col},
		"context":      {"triggerKind": 2},
	}, id, func(result):
		_pending_comp_id = null
		var items: Array = result.get("items", [])
		if items.is_empty():
			return
		var t: String = str(items[0].get("insertText", "")).strip_edges()
		if not t.is_empty():
			suggestion_received.emit(t)
	)

func notify_document_focus(uri: String) -> void:
	if _initialized:
		_notify("textDocument/didFocus", {"textDocument": {"uri": uri}})

func get_relay_log() -> String:
	if _relay_log_path.is_empty() or not FileAccess.file_exists(_relay_log_path):
		return "(no relay log yet)"
	var f := FileAccess.open(_relay_log_path, FileAccess.READ)
	return f.get_as_text() if f else "(cannot read log)"

# ── LSP startup ───────────────────────────────────────────────────────────────

func _start_lsp() -> String:
	_starting = true

	var node := _which("node")
	_log("node → '" + node + "'")
	if node.is_empty():
		_starting = false
		return "Node.js not found in PATH.\nInstall Node.js >= 20.8 from https://nodejs.org"

	# Find npx or copilot-language-server
	var lsp_bin  := ""
	var lsp_args := []

	var npx := _which("npx")
	_log("npx → '" + npx + "'")
	if not npx.is_empty():
		lsp_bin  = npx
		lsp_args = ["--yes", "@github/copilot-language-server@latest", "--stdio"]
	else:
		var lsp := _which("copilot-language-server")
		_log("copilot-language-server → '" + lsp + "'")
		if not lsp.is_empty():
			lsp_bin  = lsp
			lsp_args = ["--stdio"]
		else:
			_starting = false
			return "copilot-language-server not found.\nRun: npm install -g @github/copilot-language-server"

	# Write relay script
	var relay_path := OS.get_temp_dir().path_join("copilot_relay.mjs")
	_relay_log_path = OS.get_temp_dir().path_join("copilot_relay.log")
	_log("relay script → " + relay_path)
	_log("relay log    → " + _relay_log_path)

	var f := FileAccess.open(relay_path, FileAccess.WRITE)
	if not f:
		_starting = false
		return "Cannot write relay script to: " + relay_path
	f.store_string(_relay_source(_relay_log_path))
	f = null

	# Find a free port
	_tcp_server = TCPServer.new()
	_tcp_port = 0
	for p in range(49200, 49300):
		if _tcp_server.listen(p) == OK:
			_tcp_port = p
			break
	if _tcp_port == 0:
		_starting = false
		return "No free TCP port found in range 49200-49299."
	_log("TCP listening on port " + str(_tcp_port))

	# Build relay args: relay.mjs <port> <lsp_bin> <arg1> <arg2> ...
	# We pass lsp_bin and args separately so Node can spawn with correct quoting
	var relay_args := [relay_path, str(_tcp_port), lsp_bin] + lsp_args
	_log("spawning: " + node + " " + " ".join(relay_args))

	_relay_pid = OS.create_process(node, relay_args)
	_log("relay pid = " + str(_relay_pid))

	if _relay_pid < 0:
		_starting = false
		return "OS.create_process failed for Node.js.\nnode path: " + node

	_alive = true
	status_message.emit("Relay starting (pid " + str(_relay_pid) + ")…")
	_wait_for_tcp_connection()
	return ""

func _wait_for_tcp_connection() -> void:
	_log("waiting for TCP (up to 20s)…")
	for i in range(80):   # 80 × 0.25s = 20s
		await get_tree().create_timer(0.25).timeout
		if not _alive:
			_log("_alive=false while waiting, abort")
			_starting = false
			return
		if _tcp_server and _tcp_server.is_connection_available():
			_tcp_peer = _tcp_server.take_connection()
			_tcp_peer.set_no_delay(true)
			_starting = false
			_log("TCP connected!")
			status_message.emit("LSP connected. Initializing…")
			_send_initialize()
			return
	# Timed out — dump relay log
	_starting = false
	_alive = false
	var relay_log := get_relay_log()
	var msg := "Timeout: relay did not connect within 20s.\n\nRelay log (" + _relay_log_path + "):\n" + relay_log
	_log(msg)
	auth_error.emit("Timeout: LSP relay did not connect.\n\nSee Godot Output for relay log.\nRelay log path: " + _relay_log_path)

# ── LSP initialize sequence ───────────────────────────────────────────────────

func _send_initialize() -> void:
	var ver: String = Engine.get_version_info().string
	_request("initialize", {
		"processId":  OS.get_process_id(),
		"clientInfo": {"name": "Godot", "version": ver},
		"initializationOptions": {
			"editorInfo":       {"name": "Godot", "version": ver},
			"editorPluginInfo": {"name": "godot-copilot", "version": "2.0.0"},
		},
		"capabilities": {
			"workspace": {"workspaceFolders": true},
			"window":    {"showDocument": {"support": true}},
		},
		"workspaceFolders": [],
	}, _next_id(), func(_r):
		_log("initialize OK")
		_notify("initialized", {})
		_notify("workspace/didChangeConfiguration", {"settings": {
			"http": {"proxy": null, "proxyStrictSSL": null},
		}})
		_initialized = true
		status_message.emit("Initialized. Checking auth…")
		_check_status(func(ok: bool):
			if not ok:
				_do_sign_in()
		)
	)

func _check_status(after: Callable = func(_b): pass) -> void:
	_log("checkStatus…")
	_request("checkStatus", {"options": {}}, _next_id(), func(result):
		var s := str(result.get("status", ""))
		var u := str(result.get("user", ""))
		_log("checkStatus → " + s + " user=" + u)
		if s in ["OK", "AlreadySignedIn"]:
			_set_auth(true, u)
			after.call(true)
		else:
			status_message.emit("Not signed in (status=" + s + ")")
			after.call(false)
	)

func _do_sign_in() -> void:
	if not _initialized:
		return
	_log("signIn…")
	status_message.emit("Signing in…")
	_request("signIn", {}, _next_id(), func(result):
		var s := str(result.get("status", ""))
		var u := str(result.get("user", ""))
		_log("signIn → " + s + " user=" + u)
		match s:
			"OK", "AlreadySignedIn":
				_set_auth(true, u)
			"PromptUserDeviceFlow":
				var code := str(result.get("userCode", ""))
				var uri  := str(result.get("verificationUri", "https://github.com/login/device"))
				_log("device flow code=" + code)
				auth_device_code_ready.emit(code, uri)
				status_message.emit("Waiting for device auth…")
				_poll_until_authed()
			_:
				var msg := "Unexpected signIn status: '" + s + "' full=" + JSON.stringify(result)
				_log(msg)
				auth_error.emit(msg)
	)

func _poll_until_authed() -> void:
	if _authenticated: return
	await get_tree().create_timer(3.0).timeout
	if not _alive or not _initialized: return
	_request("checkStatus", {"options": {}}, _next_id(), func(result):
		var s := str(result.get("status", ""))
		_log("poll → " + s)
		if s in ["OK", "AlreadySignedIn"]:
			_set_auth(true, str(result.get("user", "")))
		else:
			_poll_until_authed()
	)

func _set_auth(ok: bool, user: String = "") -> void:
	_authenticated = ok
	auth_status_changed.emit(ok)
	status_message.emit("✓ Signed in" + (" as " + user if user else "") if ok else "Signed out")

# ── Document sync ─────────────────────────────────────────────────────────────

func _sync_doc(uri: String, text: String) -> void:
	if not _doc_versions.has(uri):
		_doc_versions[uri] = 0
		_notify("textDocument/didOpen", {"textDocument": {
			"uri": uri, "languageId": _lang(uri), "version": 0, "text": text,
		}})
	else:
		_doc_versions[uri] += 1
		_notify("textDocument/didChange", {
			"textDocument":   {"uri": uri, "version": _doc_versions[uri]},
			"contentChanges": [{"text": text}],
		})

func _lang(uri: String) -> String:
	if uri.ends_with(".gd"):   return "gdscript"
	if uri.ends_with(".cs"):   return "csharp"
	if uri.ends_with(".glsl"): return "glsl"
	return "plaintext"

# ── JSON-RPC ──────────────────────────────────────────────────────────────────

func _next_id() -> int:
	var id := _rpc_id; _rpc_id += 1; return id

func _request(method: String, params: Variant, id: int, cb: Callable) -> void:
	_callbacks[id] = cb
	_send({"jsonrpc": "2.0", "id": id, "method": method, "params": params})

func _notify(method: String, params: Variant) -> void:
	_send({"jsonrpc": "2.0", "method": method, "params": params})

func _send(msg: Dictionary) -> void:
	if not _tcp_peer or _tcp_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var body     := JSON.stringify(msg)
	# Ensure the body is converted to bytes using UTF-8 encoding
	var body_bytes := body.to_utf8_buffer()
	# The header itself must also be bytes
	var header := "Content-Length: %d\r\n\r\n" % body_bytes.size()
	var header_bytes := header.to_utf8_buffer()
	# Concatenate header bytes and body bytes
	_tcp_peer.put_data(header_bytes + body_bytes)

# ── TCP polling ───────────────────────────────────────────────────────────────

func _poll_tcp() -> void:
	if not _tcp_peer or _tcp_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var n := _tcp_peer.get_available_bytes()
	if n > 0:
		var data := _tcp_peer.get_data(n)
		if data[0] == OK:
			_recv_buffer.append_array(data[1])
			_parse_buffer()

func _parse_buffer() -> void:
	while true:
		var p_len := _recv_buffer.size()
		if p_len == 0: break
		
		# Optimistically convert start of buffer to ASCII to find headers
		# (Headers are always ASCII)
		var check_size := min(p_len, 4096)
		var header_view := _recv_buffer.slice(0, check_size)
		var header_str := header_view.get_string_from_ascii()
		var sep_idx := header_str.find("\r\n\r\n")
		
		if sep_idx == -1:
			# Headers not fully received yet
			if p_len > 100000: _recv_buffer.clear() # Safety flush
			break
			
		# Parse Content-Length from header string
		var content_len := 0
		var headers := header_str.substr(0, sep_idx)
		for line in headers.split("\r\n"):
			var parts := line.split(":", true, 1)
			if parts.size() == 2 and parts[0].strip_edges().to_lower() == "content-length":
				content_len = parts[1].strip_edges().to_int()
				break
		
		var body_start := sep_idx + 4
		var msg_end := body_start + content_len
		
		# CRITICAL CHECK: Compare Bytes to Bytes
		if p_len < msg_end:
			return # Wait for more data
			
		# Extract the body exactly by byte count
		var body_bytes := _recv_buffer.slice(body_start, msg_end)
		var body_str := body_bytes.get_string_from_utf8()
		
		# Remove processed message from buffer
		if msg_end == p_len:
			_recv_buffer.clear()
		else:
			_recv_buffer = _recv_buffer.slice(msg_end)
			
		_dispatch(body_str)

func _parse_buf() -> void:
	while true:
		# Find the end of the headers (\r\n\r\n)
		var header_end_pos := _read_buf.find("\r\n\r\n")
		if header_end_pos == -1:
			# Not enough data for headers yet
			break

		var headers_str := _read_buf.substr(0, header_end_pos)
		var content_length := -1

		# Parse Content-Length from headers
		for line in headers_str.split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				content_length = int(line.split(":")[1].strip_edges())
				break

		if content_length == -1:
			_log("Error: Missing Content-Length header.")
			# Handle error: maybe disconnect or try to recover
			break

		# Calculate the start and end of the body
		var body_start_pos := header_end_pos + 4 # +4 for \r\n\r\n
		var body_end_pos := body_start_pos + content_length

		# Check if we have the complete body
		if _read_buf.length() < body_end_pos:
			# Not enough data for the body yet
			break

		# Extract the body bytes
		var body_bytes := _read_buf.substr(body_start_pos, content_length).to_utf8_buffer()
		var body_str := body_bytes.get_string_from_utf8()

		# Remove the processed message (headers + body) from the buffer
		_read_buf = _read_buf.substr(body_end_pos)

		# Process the body
		_dispatch(body_str)

func _dispatch(body: String) -> void:
	var msg = JSON.parse_string(body)
	if not msg: return

	# Handle Messages with ID (Responses)
	if msg.has("id"):
		var raw_id = msg["id"]
		var id_key = raw_id
		
		# FIX: JSON numbers are Floats (1.0), but keys are Ints (1).
		# We must cast to int to find the callback.
		if typeof(raw_id) == TYPE_FLOAT:
			id_key = int(raw_id)

		if msg.has("result"):
			if _callbacks.has(id_key):
				var cb: Callable = _callbacks[id_key]
				_callbacks.erase(id_key)
				cb.call(msg["result"])
			else:
				_log("Warning: Received response for unknown ID: " + str(id_key))
		
		elif msg.has("error"):
			_log("RPC error: " + JSON.stringify(msg["error"]))
			if _callbacks.has(id_key):
				_callbacks.erase(id_key)

	# Handle Notifications (No ID)
	elif msg.has("method"):
		_on_server_notification(msg["method"], msg.get("params", {}))

func _on_server_notification(method: String, params: Variant) -> void:
	match method:
		"didChangeStatus":
			var s := str(params.get("status", ""))
			var m := str(params.get("message", ""))
			_log("server status=" + s + " msg=" + m)
			status_message.emit(s + (": " + m if m else ""))
			if s in ["OK", "AlreadySignedIn"] and not _authenticated:
				_set_auth(true)
			elif s in ["NotSignedIn", "NotAuthorized"] and _authenticated:
				_set_auth(false)
		"window/logMessage":
			_log("LSP: " + str(params.get("message", "")))
		"window/showDocument":
			var uri := str(params.get("uri", ""))
			if not uri.is_empty(): OS.shell_open(uri)
		_:
			pass

# ── Shutdown ──────────────────────────────────────────────────────────────────

func _shutdown() -> void:
	if _initialized:
		_notify("shutdown", {})
		_notify("exit", {})
	_alive = false; _starting = false; _initialized = false; _authenticated = false
	if _tcp_peer:   _tcp_peer.disconnect_from_host();  _tcp_peer   = null
	if _tcp_server: _tcp_server.stop();                 _tcp_server = null
	if _relay_pid > 0: OS.kill(_relay_pid);             _relay_pid  = -1

# ── _which ────────────────────────────────────────────────────────────────────

func _which(base_name: String) -> String:
	var is_win := OS.get_name() == "Windows"
	# On Windows try .cmd and .exe variants too
	var candidates: Array = []
	if is_win:
		candidates = [
			base_name + ".cmd",
			base_name + ".exe",
			base_name
		]
	else:
		candidates = [base_name]

	for candidate in candidates:
		var out  := []
		var code := OS.execute("where" if is_win else "which", [candidate], out)
		var raw: String = out[0] if out.size() > 0 else ""
		_log("which '" + candidate + "' code=" + str(code) + " raw='" + raw.strip_edges() + "'")
		if code != 0 or raw.strip_edges().is_empty():
			continue
		# 'where' returns multiple lines — take the first valid one
		for raw_line in raw.split("\n"):
			var path: String = raw_line.strip_edges().trim_suffix("\r")
			if path.is_empty(): continue
			if path.begins_with("which:") or path.begins_with("INFO:"): continue
			if "not find" in path.to_lower(): continue
			_log("  → '" + path + "'")
			return path
	return ""

# ── Logging ───────────────────────────────────────────────────────────────────

func _log(msg: String) -> void:
	if !_DEBUG:
		return
	print("[Copilot] " + msg)

# ── Relay script (Node ESM) ───────────────────────────────────────────────────
# argv: node relay.mjs <port> <lsp_bin> [lsp_arg1] [lsp_arg2] ...
# lsp_bin is passed as a separate argument — no pipe encoding needed.
# stderr is written to a log file AND to process.stderr.

func _relay_source(log_path: String) -> String:
	var safe_log := log_path.replace("\\", "\\\\")
	return """import net from 'net';
import fs  from 'fs';
import { spawn } from 'child_process';

const port    = parseInt(process.argv[2]);
const lspBin  = process.argv[3];
const lspArgs = process.argv.slice(4);

const logStream = fs.createWriteStream('%s', { flags: 'w' });
function log(msg) {
  const line = '[relay] ' + msg + '\\n';
  // Also print to stderr so it shows in Godot Output
  process.stderr.write(line);
  logStream.write(line);
}

log('port='    + port);
log('lspBin='  + lspBin);

let lsp;
try {
  let bin = lspBin;
  let opts = {
    stdio: ['pipe', 'pipe', 'pipe'],
    shell: false
  };

  // Windows Fix: Quoting for paths with spaces when using shell:true
  if (process.platform === 'win32') {
    opts.shell = true;
    if (bin.includes(' ')) {
      bin = `"${bin}"`;
    }
  }

  log('Spawning LSP: ' + bin + ' ' + JSON.stringify(lspArgs));
  lsp = spawn(bin, lspArgs, opts);
} catch(e) {
  log('spawn error: ' + e.message);
  process.exit(1);
}

// --- LSP EVENT LOGGING ---

lsp.stderr.on('data', d => log('lsp stderr: ' + d.toString().trimEnd()));
lsp.on('error', err  => { log('lsp error: '   + err.message); process.exit(1); });
lsp.on('exit',  (c,s)=> { log('lsp exit code='+c+' sig='+s);  process.exit(c ?? 1); });

// --- CONNECT TO GODOT ---

log('Connecting to Godot on port ' + port + '...');
const socket = net.createConnection(port, '127.0.0.1');

socket.on('connect', () => {
  log('Connected to Godot (TCP established)');
});

socket.on('data', d => {
  // Log data FROM Godot -> TO LSP
  log(`GODOT -> LSP: ${d.length} bytes`);
  if (!lsp.stdin.destroyed) {
    const ok = lsp.stdin.write(d);
    if (!ok) log('Warning: LSP stdin buffer full');
  } else {
    log('Error: LSP stdin is destroyed, cannot write');
  }
});

socket.on('end', () => {
  log('Godot disconnected');
  lsp.kill();
  process.exit(0);
});

socket.on('error', e => {
  log('Socket error: ' + e.message);
  process.exit(1);
});

// --- LSP OUTPUT ---

lsp.stdout.on('data', d => {
  // Log data FROM LSP -> TO Godot
  log(`LSP -> GODOT: ${d.length} bytes`);
  if (!socket.destroyed) {
    socket.write(d);
  }
});

lsp.stdout.on('end', () => {
  log('lsp stdout ended');
  socket.end();
});

lsp.on('close', () => {
  log('lsp closed');
  socket.destroy();
  process.exit(0);
});
""" % safe_log
