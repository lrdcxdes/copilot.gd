@tool
extends Node

signal suggestion_received(text: String)
signal auth_status_changed(authenticated: bool)
signal auth_device_code_ready(user_code: String, verify_uri: String)
signal auth_error(message: String)
signal status_message(text: String)
signal models_received(models: Array)

var _DEBUG: bool = false

var _alive:         bool = false
var _starting:      bool = false
var _initialized:   bool = false
var _authenticated: bool = false

var _relay_pid:  int = -1
var _tcp_server: TCPServer = null
var _tcp_peer:   StreamPeerTCP = null
var _tcp_port:   int = 0

var _rpc_id:    int = 1
var _callbacks: Dictionary = {}

var _recv_buffer:  PackedByteArray = PackedByteArray()
var _doc_versions: Dictionary = {}
var _pending_comp_id = null

var _relay_log_path: String = ""
var _current_model:  String = ""

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _process(_dt: float) -> void:
	_poll_tcp()

func _exit_tree() -> void:
	_shutdown()

# ── Public API ────────────────────────────────────────────────────────────────

func is_authenticated() -> bool:
	return _authenticated

func is_alive() -> bool:
	return _alive

func start_sign_in() -> void:
	if _starting:
		_log("Already starting…"); return
	if _alive:
		if _initialized: _do_sign_in()
		else: _log("LSP alive but not initialized yet")
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
	if not _authenticated or not _initialized: return
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
		if items.is_empty(): return
		var t: String = str(items[0].get("insertText", ""))
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

# ── Model API ─────────────────────────────────────────────────────────────────

func fetch_models() -> void:
	if not _initialized or not _authenticated:
		status_message.emit("Not ready to fetch models")
		return
	_log("Fetching models…")
	status_message.emit("Fetching models…")
	_request("copilot/models", {}, _next_id(), func(result):
		var raw: Array = []
		if result is Dictionary:
			raw = result.get("models", result.get("items", []))
		elif result is Array:
			raw = result
		var out: Array = []
		for m in raw:
			if m is Dictionary:
				var scopes = m.get("scopes", [])
				if "completion" in scopes or scopes.is_empty():
					out.append(m)
		_log("Models: " + str(out.size()))
		models_received.emit(out)
		status_message.emit("Fetched " + str(out.size()) + " models")
	)

func set_model(model_id: String) -> void:
	_current_model = model_id
	_push_config()
	status_message.emit("Model: " + (model_id if not model_id.is_empty() else "default"))

func get_current_model() -> String:
	return _current_model

func _push_config() -> void:
	if not _initialized: return
	var settings: Dictionary = {"http": {"proxy": null, "proxyStrictSSL": null}}
	if not _current_model.is_empty():
		settings["github"] = {"copilot": {"selectedCompletionModel": _current_model}}
	_notify("workspace/didChangeConfiguration", {"settings": settings})

# ── LSP startup ───────────────────────────────────────────────────────────────

func _start_lsp() -> String:
	_starting = true

	var node := _which("node")
	if node.is_empty():
		_starting = false
		return "Node.js not found in PATH.\nInstall Node.js >= 20.8 from https://nodejs.org"

	var lsp_bin := ""; var lsp_args := []
	var npx := _which("npx")
	if not npx.is_empty():
		lsp_bin  = npx
		lsp_args = ["--yes", "@github/copilot-language-server@latest", "--stdio"]
	else:
		var lsp := _which("copilot-language-server")
		if not lsp.is_empty():
			lsp_bin = lsp; lsp_args = ["--stdio"]
		else:
			_starting = false
			return "copilot-language-server not found.\nRun: npm install -g @github/copilot-language-server"

	var relay_path  := OS.get_temp_dir().path_join("copilot_relay.mjs")
	_relay_log_path  = OS.get_temp_dir().path_join("copilot_relay.log")

	var f := FileAccess.open(relay_path, FileAccess.WRITE)
	if not f:
		_starting = false
		return "Cannot write relay script to: " + relay_path
	f.store_string(_relay_source(_relay_log_path)); f = null

	_tcp_server = TCPServer.new()
	_tcp_port   = 0
	for p in range(49200, 49300):
		if _tcp_server.listen(p) == OK:
			_tcp_port = p; break
	if _tcp_port == 0:
		_starting = false
		return "No free TCP port in 49200-49299"

	var relay_args := [relay_path, str(_tcp_port), lsp_bin] + lsp_args
	_relay_pid = OS.create_process(node, relay_args)
	if _relay_pid < 0:
		_starting = false
		return "OS.create_process failed"

	_alive = true
	status_message.emit("Relay starting…")
	_wait_for_tcp_connection()
	return ""

func _wait_for_tcp_connection() -> void:
	for _i in range(80):   # 20 s
		await get_tree().create_timer(0.25).timeout
		if not _alive: _starting = false; return
		if _tcp_server and _tcp_server.is_connection_available():
			_tcp_peer = _tcp_server.take_connection()
			_tcp_peer.set_no_delay(true)
			_starting = false
			status_message.emit("Connected. Initializing…")
			_send_initialize()
			return
	_starting = false; _alive = false
	auth_error.emit("Timeout: LSP relay did not connect.\nLog: " + _relay_log_path)

# ── LSP initialize ────────────────────────────────────────────────────────────

func _send_initialize() -> void:
	var ver: String = Engine.get_version_info().string
	_request("initialize", {
		"processId":  OS.get_process_id(),
		"clientInfo": {"name": "Godot", "version": ver},
		"initializationOptions": {
			"editorInfo":       {"name": "Godot", "version": ver},
			"editorPluginInfo": {"name": "godot-copilot", "version": "2.1.0"},
		},
		"capabilities": {
			"workspace": {"workspaceFolders": true},
			"window":    {"showDocument": {"support": true}},
		},
		"workspaceFolders": [],
	}, _next_id(), func(_r):
		_log("initialize OK")
		_notify("initialized", {})
		_push_config()
		_initialized = true
		status_message.emit("Initialized. Checking auth…")
		_check_status(func(ok: bool):
			if not ok: _do_sign_in()
		)
	)

func _check_status(after: Callable = func(_b): pass) -> void:
	_request("checkStatus", {"options": {}}, _next_id(), func(result):
		var s := str(result.get("status", ""))
		var u := str(result.get("user", ""))
		if s in ["OK", "AlreadySignedIn"]:
			_set_auth(true, u); after.call(true)
		else:
			status_message.emit("Not signed in (status=" + s + ")")
			after.call(false)
	)

func _do_sign_in() -> void:
	if not _initialized: return
	status_message.emit("Signing in…")
	_request("signIn", {}, _next_id(), func(result):
		var s := str(result.get("status", ""))
		var u := str(result.get("user", ""))
		match s:
			"OK", "AlreadySignedIn":
				_set_auth(true, u)
			"PromptUserDeviceFlow":
				auth_device_code_ready.emit(
					str(result.get("userCode", "")),
					str(result.get("verificationUri", "https://github.com/login/device"))
				)
				status_message.emit("Waiting for device auth…")
				_poll_until_authed()
			_:
				auth_error.emit("Unexpected signIn status: '" + s + "'")
	)

func _poll_until_authed() -> void:
	if _authenticated: return
	await get_tree().create_timer(3.0).timeout
	if not _alive or not _initialized: return
	_request("checkStatus", {"options": {}}, _next_id(), func(result):
		var s := str(result.get("status", ""))
		if s in ["OK", "AlreadySignedIn"]:
			_set_auth(true, str(result.get("user", "")))
		else:
			_poll_until_authed()
	)

func _set_auth(ok: bool, user: String = "") -> void:
	_authenticated = ok
	auth_status_changed.emit(ok)
	if ok:
		status_message.emit("✓ Signed in" + (" as " + user if user else ""))
		await get_tree().create_timer(0.5).timeout
		fetch_models()
	else:
		status_message.emit("Signed out")

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
	var body_bytes := JSON.stringify(msg).to_utf8_buffer()
	var header     := ("Content-Length: %d\r\n\r\n" % body_bytes.size()).to_utf8_buffer()
	_tcp_peer.put_data(header + body_bytes)

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
		var p := _recv_buffer.size()
		if p == 0: break
		var hdr := _recv_buffer.slice(0, min(p, 4096)).get_string_from_ascii()
		var sep := hdr.find("\r\n\r\n")
		if sep == -1:
			if p > 100000: _recv_buffer.clear()
			break
		var cl := 0
		for line in hdr.substr(0, sep).split("\r\n"):
			var pts := line.split(":", true, 1)
			if pts.size() == 2 and pts[0].strip_edges().to_lower() == "content-length":
				cl = pts[1].strip_edges().to_int(); break
		var bs := sep + 4; var me := bs + cl
		if p < me: return
		var body := _recv_buffer.slice(bs, me).get_string_from_utf8()
		_recv_buffer = PackedByteArray() if me == p else _recv_buffer.slice(me)
		_dispatch(body)

func _dispatch(body: String) -> void:
	var msg = JSON.parse_string(body)
	if not msg: return
	if msg.has("id"):
		var raw = msg["id"]
		var key = int(raw) if typeof(raw) == TYPE_FLOAT else raw
		if msg.has("result"):
			if _callbacks.has(key):
				var cb: Callable = _callbacks[key]
				_callbacks.erase(key)
				cb.call(msg["result"])
		elif msg.has("error"):
			_log("RPC error id=" + str(key) + ": " + JSON.stringify(msg["error"]))
			_callbacks.erase(key)
	elif msg.has("method"):
		_on_notification(msg["method"], msg.get("params", {}))

func _on_notification(method: String, params: Variant) -> void:
	match method:
		"didChangeStatus":
			var s := str(params.get("status", ""))
			var m := str(params.get("message", ""))
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

# ── Shutdown (COMPLETE process cleanup) ──────────────────────────────────────

func _shutdown() -> void:
	_log("Shutdown requested")
	# 1. Graceful LSP shutdown
	if _initialized:
		_notify("shutdown", {})
		_notify("exit", {})
	# 2. Reset state
	_alive = false; _starting = false; _initialized = false; _authenticated = false
	# 3. Disconnect TCP
	if _tcp_peer:
		_tcp_peer.disconnect_from_host()
		_tcp_peer = null
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	# 4. Kill relay + any orphan node processes
	_kill_relay()
	# 5. Clean up callbacks to prevent dangling references
	_callbacks.clear()
	_doc_versions.clear()
	_pending_comp_id = null
	_log("Shutdown complete")

func _kill_relay() -> void:
	if _relay_pid > 0:
		_log("Killing relay pid=" + str(_relay_pid))
		OS.kill(_relay_pid)
		_relay_pid = -1
	# Also try to kill any lingering npx/node processes that own our port
	# by looking for the relay script in process list (best-effort)
	_kill_orphan_relay()

func _kill_orphan_relay() -> void:
	# On Unix: fuser -k <port>/tcp  (silent fail if not available)
	if OS.get_name() in ["Linux", "macOS", "FreeBSD"]:
		OS.execute("fuser", ["-k", str(_tcp_port) + "/tcp"], [], true)

# ── _which ────────────────────────────────────────────────────────────────────

func _which(base: String) -> String:
	var is_win := OS.get_name() == "Windows"
	var cands  := ([base + ".cmd", base + ".exe", base] if is_win else [base]) as Array
	for c in cands:
		var out := []; var code := OS.execute("where" if is_win else "which", [c], out)
		if code != 0 or out.is_empty(): continue
		for raw_line in (out[0] as String).split("\n"):
			var path: String = raw_line.strip_edges().trim_suffix("\r")
			if path.is_empty() or "not find" in path.to_lower(): continue
			if path.begins_with("which:") or path.begins_with("INFO:"): continue
			return path
	return ""

# ── Logging ───────────────────────────────────────────────────────────────────

func _log(msg: String) -> void:
	if _DEBUG: print("[Copilot] " + msg)

# ── Relay source ──────────────────────────────────────────────────────────────

func _relay_source(log_path: String) -> String:
	return """import net from 'net';
import fs  from 'fs';
import { spawn } from 'child_process';

const port    = parseInt(process.argv[2]);
const lspBin  = process.argv[3];
const lspArgs = process.argv.slice(4);

const logStream = fs.createWriteStream('%s', { flags: 'w' });
function log(msg) {
  const line = '[relay] ' + msg + '\\n';
  process.stderr.write(line);
  logStream.write(line);
}
log('port='  + port);
log('lspBin='+ lspBin);

let lsp;
try {
  let bin = lspBin;
  let opts = { stdio: ['pipe','pipe','pipe'], shell: false };
  if (process.platform === 'win32') { opts.shell = true; if (bin.includes(' ')) bin=`"${bin}"`; }
  log('Spawning: ' + bin + ' ' + JSON.stringify(lspArgs));
  lsp = spawn(bin, lspArgs, opts);
} catch(e) { log('spawn error: '+e.message); process.exit(1); }

lsp.stderr.on('data', d => log('lsp: '+d.toString().trimEnd()));
lsp.on('error', e => { log('lsp error: '+e.message); process.exit(1); });
lsp.on('exit', (c,s) => { log('lsp exit code='+c+' sig='+s); process.exit(c??1); });

// Kill LSP when this relay process exits for any reason
process.on('exit', () => { try { lsp.kill('SIGKILL'); } catch(e){} });
process.on('SIGINT',  () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));

const socket = net.createConnection(port, '127.0.0.1');
socket.on('connect', () => log('Connected to Godot'));
socket.on('data', d => { if (!lsp.stdin.destroyed) lsp.stdin.write(d); });
socket.on('end',  () => { log('Godot disconnected'); lsp.kill(); process.exit(0); });
socket.on('error',e => { log('socket: '+e.message); process.exit(1); });
lsp.stdout.on('data', d => { if (!socket.destroyed) socket.write(d); });
lsp.stdout.on('end',  () => { log('lsp stdout ended'); socket.end(); });
lsp.on('close', () => { log('lsp closed'); socket.destroy(); process.exit(0); });
""" % log_path.replace("\\", "\\\\")
