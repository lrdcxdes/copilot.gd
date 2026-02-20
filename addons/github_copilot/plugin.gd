@tool
extends EditorPlugin

const CopilotManager  = preload("res://addons/github_copilot/copilot_manager.gd")
const CopilotPanel    = preload("res://addons/github_copilot/copilot_panel.gd")
const CopilotOverlay  = preload("res://addons/github_copilot/copilot_overlay.gd")
const CopilotSettings = preload("res://addons/github_copilot/copilot_settings.gd")

var manager:  CopilotManager
var panel:    CopilotPanel
var settings: CopilotSettings

# Overlay is a RefCounted (not a Node), managed per active editor
var overlay: CopilotOverlay = null

var script_editor:    ScriptEditor = null
var current_code_edit: CodeEdit    = null
var current_uri:      String       = ""

var debounce: Timer = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _enter_tree() -> void:
	settings = CopilotSettings.new()

	manager = CopilotManager.new()
	manager.name = "CopilotManager"
	add_child(manager)

	panel = CopilotPanel.new(manager, settings)
	add_control_to_bottom_panel(panel, "Copilot")

	debounce = Timer.new()
	debounce.name     = "CopilotDebounce"
	debounce.one_shot = true
	debounce.timeout.connect(_request_completion)
	add_child(debounce)
	# Apply saved delay
	debounce.wait_time = settings.debounce_delay
	settings.settings_changed.connect(func():
		debounce.wait_time = settings.debounce_delay
	)

	script_editor = get_editor_interface().get_script_editor()
	script_editor.editor_script_changed.connect(_on_script_changed)
	manager.suggestion_received.connect(_on_suggestion_received)

	_hook_editor()

	# Auto-start: if setting enabled, start LSP immediately
	if settings.auto_start:
		await get_tree().process_frame   # let panel finish _ready
		manager.start_sign_in()

func _exit_tree() -> void:
	# Unhook first so no callbacks fire during teardown
	_unhook_editor()

	if is_instance_valid(panel):
		remove_control_from_bottom_panel(panel)
		panel.queue_free()

	# manager._exit_tree / _shutdown called automatically when removed
	# but we trigger it explicitly to be safe
	if is_instance_valid(manager):
		manager._shutdown()

# ── Editor wiring ─────────────────────────────────────────────────────────────

func _on_script_changed(_script) -> void:
	_unhook_editor()
	await get_tree().process_frame
	_hook_editor()

func _hook_editor() -> void:
	var base := script_editor.get_current_editor() if script_editor else null
	if not base: return
	var ce := _find_by_class(base, "CodeEdit")
	if not ce: return

	current_code_edit = ce

	# ── Fix: only connect if NOT already connected ──
	if not current_code_edit.text_changed.is_connected(_on_text_changed):
		current_code_edit.text_changed.connect(_on_text_changed)

	# Create fresh overlay
	if overlay:
		overlay.hide_suggestion()
		overlay = null
	overlay = CopilotOverlay.new()

	var script := script_editor.get_current_script() if script_editor else null
	if script:
		current_uri = "file://" + ProjectSettings.globalize_path(script.resource_path)
		manager.notify_document_focus(current_uri)

func _unhook_editor() -> void:
	# Dismiss any active suggestion
	if overlay:
		overlay.hide_suggestion()
		overlay = null

	if is_instance_valid(current_code_edit):
		if current_code_edit.text_changed.is_connected(_on_text_changed):
			current_code_edit.text_changed.disconnect(_on_text_changed)

	current_code_edit = null
	current_uri       = ""

func _find_by_class(node: Node, cls: String) -> Node:
	for child in node.get_children():
		if child.get_class() == cls: return child
		var found := _find_by_class(child, cls)
		if found: return found
	return null

# ── Completion flow ───────────────────────────────────────────────────────────

func _on_text_changed() -> void:
	if overlay:
		overlay.hide_suggestion()
	if not is_instance_valid(debounce): return
	debounce.stop()
	if manager.is_authenticated() and settings.auto_show_completions:
		debounce.start()

func _request_completion() -> void:
	if not is_instance_valid(current_code_edit): return
	if not manager.is_authenticated(): return
	manager.request_completion(
		current_code_edit.text,
		current_code_edit.get_caret_line(),
		current_code_edit.get_caret_column(),
		current_uri
	)

func _on_suggestion_received(text: String) -> void:
	if not is_instance_valid(current_code_edit) or not overlay: return
	if text.strip_edges().is_empty(): return
	overlay.show_suggestion(text, current_code_edit)

# ── Input ─────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not overlay or not overlay.has_suggestion(): return
	if not (event is InputEventKey) or not event.pressed: return

	match event.keycode:
		KEY_TAB:
			if _native_popup_visible(): return
			overlay.accept_suggestion()
			get_viewport().set_input_as_handled()

		KEY_ESCAPE:
			overlay.hide_suggestion()
			get_viewport().set_input_as_handled()

		# Cursor movement: dismiss without consuming
		KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, \
		KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN:
			overlay.hide_suggestion()

		_:
			if event.unicode > 0:
				overlay.hide_suggestion()

func _native_popup_visible() -> bool:
	if not is_instance_valid(current_code_edit): return false
	for child in current_code_edit.get_children():
		if (child is PopupPanel or child is Window) and child.visible:
			return true
	return false