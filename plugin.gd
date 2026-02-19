@tool
extends EditorPlugin

const CopilotManager = preload("res://addons/github_copilot/copilot_manager.gd")
const CopilotPanel   = preload("res://addons/github_copilot/copilot_panel.gd")
const CopilotOverlay = preload("res://addons/github_copilot/copilot_overlay.gd")

var manager: CopilotManager
var panel: CopilotPanel
var overlay: CopilotOverlay

var script_editor: ScriptEditor
var current_code_edit: CodeEdit
var current_uri: String = ""

var debounce: Timer

func _enter_tree() -> void:
	manager = CopilotManager.new()
	add_child(manager)

	panel = CopilotPanel.new(manager)
	add_control_to_bottom_panel(panel, "Copilot")

	debounce = Timer.new()
	debounce.wait_time = 0.75
	debounce.one_shot  = true
	debounce.timeout.connect(_request_completion)
	add_child(debounce)

	script_editor = get_editor_interface().get_script_editor()
	script_editor.editor_script_changed.connect(_on_script_changed)

	manager.suggestion_received.connect(_on_suggestion_received)

	_hook_editor()

func _exit_tree() -> void:
	if panel:
		remove_control_from_bottom_panel(panel)
		panel.queue_free()
	if overlay:
		overlay.queue_free()
	_unhook_editor()

# ── Editor wiring ─────────────────────────────────────────────────────────────

func _on_script_changed(_script) -> void:
	_unhook_editor()
	await get_tree().process_frame
	_hook_editor()

func _hook_editor() -> void:
	var base := script_editor.get_current_editor()
	if not base:
		return
	var ce := _find_by_class(base, "CodeEdit")
	if not ce:
		return
	current_code_edit = ce
	current_code_edit.text_changed.connect(_on_text_changed)

	if overlay:
		overlay.queue_free()
	overlay = CopilotOverlay.new()
	current_code_edit.add_child(overlay)

	var script := script_editor.get_current_script()
	if script:
		current_uri = "file://" + ProjectSettings.globalize_path(script.resource_path)

func _unhook_editor() -> void:
	if current_code_edit and current_code_edit.text_changed.is_connected(_on_text_changed):
		current_code_edit.text_changed.disconnect(_on_text_changed)
	current_code_edit = null
	if overlay:
		overlay.queue_free()
		overlay = null

func _find_by_class(node: Node, cls: String) -> Node:
	for child in node.get_children():
		if child.get_class() == cls:
			return child
		var found := _find_by_class(child, cls)
		if found:
			return found
	return null

# ── Completion flow ───────────────────────────────────────────────────────────

func _on_text_changed() -> void:
	if overlay:
		overlay.hide_suggestion()
	debounce.stop()
	if manager.is_authenticated():
		debounce.start()

func _request_completion() -> void:
	if not current_code_edit or not manager.is_authenticated():
		return
	manager.request_completion(
		current_code_edit.text,
		current_code_edit.get_caret_line(),
		current_code_edit.get_caret_column(),
		current_uri
	)

func _on_suggestion_received(text: String) -> void:
	if not current_code_edit or not overlay:
		return
	if not text.strip_edges().is_empty():
		overlay.show_suggestion(text, current_code_edit)

# ── Input: Tab / Esc ──────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not overlay or not overlay.has_suggestion():
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	match event.keycode:
		KEY_TAB:
			if _native_popup_visible():
				return
			overlay.accept_suggestion()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			overlay.hide_suggestion()
			get_viewport().set_input_as_handled()
		_:
			if event.unicode > 0:
				overlay.hide_suggestion()

func _native_popup_visible() -> bool:
	if not current_code_edit:
		return false
	for child in current_code_edit.get_children():
		if (child is PopupPanel or child is Window) and child.visible:
			return true
	return false
