@tool
## Bottom panel: Auth tab + Settings tab
extends PanelContainer

const CopilotSettings = preload("res://addons/github_copilot/copilot_settings.gd")

var _manager
var _settings: CopilotSettings

enum AuthState { SIGNED_OUT, WAITING, AUTHED, ERROR }
var _auth_state := AuthState.SIGNED_OUT
var _verify_uri := ""
var _user_code  := ""
var _user_name  := ""
var _models_list: Array = []

# ── Widgets ───────────────────────────────────────────────────────────────────
# Auth tab
var _dot:         Label
var _lbl_status:  Label
var _view_out:    Control
var _view_wait:   Control
var _view_authed: Control
var _view_error:  Control
var _btn_signin:  Button
var _lbl_code:    Label
var _btn_copy:    Button
var _btn_browser: Button
var _lbl_info:    Label
var _lbl_user:    Label
var _btn_model:   MenuButton
var _btn_refresh: Button
var _btn_signout: Button
var _lbl_error:   Label
var _btn_retry:   Button

# Settings tab
var _chk_auto_show:   CheckBox
var _chk_auto_start:  CheckBox
var _chk_remember:    CheckBox
var _spin_debounce:   SpinBox
var _color_ghost:     ColorPickerButton
var _btn_save:        Button
var _lbl_keybinds:    RichTextLabel
var _btn_log:         Button

# Tabs
var _tab_container: TabContainer

# Spinner
var _spin_chars := ["|", "/", "-", "\\"]
var _spin_idx   := 0
var _spin_timer: Timer

func _init(manager, settings: CopilotSettings) -> void:
	_manager  = manager
	_settings = settings

func _ready() -> void:
	custom_minimum_size = Vector2(0, 86)
	_build()

	_manager.auth_status_changed.connect(_on_auth_changed)
	_manager.auth_device_code_ready.connect(_on_code_ready)
	_manager.auth_error.connect(_on_error)
	_manager.status_message.connect(_on_status)
	_manager.models_received.connect(_on_models)

	_spin_timer = Timer.new()
	_spin_timer.wait_time = 0.15
	_spin_timer.timeout.connect(func():
		_spin_idx = (_spin_idx + 1) % 4
		_lbl_info.text = _spin_chars[_spin_idx] + "  Waiting for GitHub…"
	)
	add_child(_spin_timer)

	_set_auth_state(AuthState.SIGNED_OUT)
	_load_settings_to_ui()

# ══════════════════════════════════════════════════════════════════════════════
# BUILD
# ══════════════════════════════════════════════════════════════════════════════

func _build() -> void:
	var margin := MarginContainer.new()
	for s in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + s, 4)
	add_child(margin)

	_tab_container = TabContainer.new()
	margin.add_child(_tab_container)

	_build_auth_tab()
	_build_settings_tab()

# ── Auth Tab ──────────────────────────────────────────────────────────────────

func _build_auth_tab() -> void:
	var root := HBoxContainer.new()
	root.name = "Copilot"
	root.add_theme_constant_override("separation", 12)
	_tab_container.add_child(root)

	# Brand
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 185
	left.add_theme_constant_override("separation", 2)
	root.add_child(left)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 5)
	left.add_child(title_row)

	_dot = Label.new(); _dot.text = "⬡"
	_dot.add_theme_font_size_override("font_size", 14)
	title_row.add_child(_dot)

	var title := Label.new(); title.text = "GitHub Copilot"
	title.add_theme_font_size_override("font_size", 12)
	title_row.add_child(title)

	_lbl_status = Label.new(); _lbl_status.text = "Not signed in"
	_lbl_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_lbl_status.add_theme_font_size_override("font_size", 10)
	_lbl_status.clip_text = true; _lbl_status.custom_minimum_size.x = 180
	left.add_child(_lbl_status)

	root.add_child(_vsep())

	# ── SIGNED OUT ──
	_view_out = HBoxContainer.new()
	_view_out.add_theme_constant_override("separation", 10)
	root.add_child(_view_out)

	_btn_signin = Button.new(); _btn_signin.text = "  Sign in with GitHub  "
	_btn_signin.pressed.connect(_on_signin_pressed)
	_view_out.add_child(_btn_signin)

	var hint := Label.new()
	hint.text = "Requires Node.js ≥ 20.8 + GitHub Copilot subscription."
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	hint.add_theme_font_size_override("font_size", 10)
	_view_out.add_child(hint)

	# ── WAITING ──
	_view_wait = HBoxContainer.new()
	_view_wait.add_theme_constant_override("separation", 10)
	root.add_child(_view_wait)

	var cp := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.10)
	for side in [SIDE_LEFT,SIDE_RIGHT,SIDE_TOP,SIDE_BOTTOM]: sb.set_border_width(side, 1)
	sb.border_color = Color(0.28, 0.28, 0.28)
	for c in ["top_left","top_right","bottom_left","bottom_right"]: sb.set("corner_radius_"+c, 5)
	sb.content_margin_left=12; sb.content_margin_right=12
	sb.content_margin_top=3; sb.content_margin_bottom=3
	cp.add_theme_stylebox_override("panel", sb)
	_view_wait.add_child(cp)

	_lbl_code = Label.new(); _lbl_code.text = "XXXX-XXXX"
	_lbl_code.add_theme_font_size_override("font_size", 20)
	cp.add_child(_lbl_code)

	var wb := VBoxContainer.new(); wb.add_theme_constant_override("separation", 3)
	_view_wait.add_child(wb)

	_btn_copy = Button.new(); _btn_copy.text = "⎘  Copy Code"
	_btn_copy.pressed.connect(_on_copy_pressed); wb.add_child(_btn_copy)

	_btn_browser = Button.new(); _btn_browser.text = "↗  Open github.com/login/device"
	_btn_browser.pressed.connect(func(): OS.shell_open(_verify_uri)); wb.add_child(_btn_browser)

	var btn_cancel := Button.new(); btn_cancel.text = "✕  Cancel"; btn_cancel.flat = true
	btn_cancel.pressed.connect(_on_cancel_pressed); wb.add_child(btn_cancel)

	_lbl_info = Label.new(); _lbl_info.text = ""
	_lbl_info.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_lbl_info.add_theme_font_size_override("font_size", 10)
	_view_wait.add_child(_lbl_info)

	# ── AUTHED ──
	_view_authed = HBoxContainer.new()
	_view_authed.add_theme_constant_override("separation", 14)
	root.add_child(_view_authed)

	# Keybindings summary
	var kc := VBoxContainer.new(); kc.add_theme_constant_override("separation", 1)
	_view_authed.add_child(kc)
	var kt := Label.new(); kt.text = "Keybindings"
	kt.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	kt.add_theme_font_size_override("font_size", 10); kc.add_child(kt)
	var kb := Label.new(); kb.text = "Tab  →  Accept    Esc  →  Dismiss"
	kb.add_theme_font_size_override("font_size", 10); kc.add_child(kb)

	_view_authed.add_child(_vsep())

	# Model selector
	var mc := VBoxContainer.new(); mc.add_theme_constant_override("separation", 2)
	_view_authed.add_child(mc)
	var ml := Label.new(); ml.text = "Model"
	ml.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	ml.add_theme_font_size_override("font_size", 10); mc.add_child(ml)
	var mr := HBoxContainer.new(); mr.add_theme_constant_override("separation", 3); mc.add_child(mr)

	_btn_model = MenuButton.new(); _btn_model.text = "Default"
	_btn_model.custom_minimum_size.x = 145
	_btn_model.get_popup().index_pressed.connect(_on_model_selected)
	mr.add_child(_btn_model)

	_btn_refresh = Button.new(); _btn_refresh.text = "↺"; _btn_refresh.flat = true
	_btn_refresh.tooltip_text = "Refresh model list"
	_btn_refresh.pressed.connect(func(): _btn_refresh.disabled=true; _manager.fetch_models())
	mr.add_child(_btn_refresh)

	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_authed.add_child(sp)

	# User + sign out
	var uc := VBoxContainer.new(); uc.add_theme_constant_override("separation", 2)
	_view_authed.add_child(uc)
	_lbl_user = Label.new(); _lbl_user.text = ""
	_lbl_user.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_lbl_user.add_theme_font_size_override("font_size", 10); uc.add_child(_lbl_user)
	_btn_signout = Button.new(); _btn_signout.text = "Sign Out"; _btn_signout.flat = true
	_btn_signout.pressed.connect(_on_signout_pressed); uc.add_child(_btn_signout)

	# ── ERROR ──
	_view_error = HBoxContainer.new()
	_view_error.add_theme_constant_override("separation", 10)
	root.add_child(_view_error)

	_lbl_error = Label.new(); _lbl_error.text = ""
	_lbl_error.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	_lbl_error.autowrap_mode = TextServer.AUTOWRAP_WORD
	_lbl_error.custom_minimum_size.x = 360; _view_error.add_child(_lbl_error)

	_btn_retry = Button.new(); _btn_retry.text = "Try Again"
	_btn_retry.pressed.connect(_on_signin_pressed); _view_error.add_child(_btn_retry)

# ── Settings Tab ──────────────────────────────────────────────────────────────

func _build_settings_tab() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Settings"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tab_container.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	var margin := MarginContainer.new()
	for s in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + s, 8)
	vbox.add_child(margin)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 8)
	margin.add_child(inner)

	# ── Completion ───────────────────────────────────────────────────────────
	inner.add_child(_section_label("Completion"))

	_chk_auto_show = CheckBox.new()
	_chk_auto_show.text = "Automatically show completions while typing"
	inner.add_child(_chk_auto_show)

	var deb_row := HBoxContainer.new(); deb_row.add_theme_constant_override("separation", 8)
	inner.add_child(deb_row)
	var deb_lbl := Label.new(); deb_lbl.text = "Trigger delay (seconds):"
	deb_lbl.add_theme_font_size_override("font_size", 11); deb_row.add_child(deb_lbl)
	_spin_debounce = SpinBox.new()
	_spin_debounce.min_value = 0.2; _spin_debounce.max_value = 3.0
	_spin_debounce.step = 0.05; _spin_debounce.custom_minimum_size.x = 80
	deb_row.add_child(_spin_debounce)

	var gc_row := HBoxContainer.new(); gc_row.add_theme_constant_override("separation", 8)
	inner.add_child(gc_row)
	var gc_lbl := Label.new(); gc_lbl.text = "Ghost text color:"
	gc_lbl.add_theme_font_size_override("font_size", 11); gc_row.add_child(gc_lbl)
	_color_ghost = ColorPickerButton.new()
	_color_ghost.custom_minimum_size = Vector2(60, 22); gc_row.add_child(_color_ghost)

	inner.add_child(_hsep())

	# ── Session ──────────────────────────────────────────────────────────────
	inner.add_child(_section_label("Session"))

	_chk_auto_start = CheckBox.new()
	_chk_auto_start.text = "Auto-connect LSP on Godot startup"
	inner.add_child(_chk_auto_start)

	_chk_remember = CheckBox.new()
	_chk_remember.text = "Remember sign-in session (auto sign-in on reconnect)"
	inner.add_child(_chk_remember)

	inner.add_child(_hsep())

	# ── Keybindings info ─────────────────────────────────────────────────────
	inner.add_child(_section_label("Keybindings"))

	_lbl_keybinds = RichTextLabel.new()
	_lbl_keybinds.bbcode_enabled = true
	_lbl_keybinds.fit_content = true
	_lbl_keybinds.text = \
		"[b]Tab[/b]  →  Accept suggestion\n" + \
		"[b]Esc[/b]  →  Dismiss suggestion\n" + \
		"[b]Arrow keys[/b]  →  Dismiss suggestion\n\n" + \
		"[color=#888888][i]Tip: Start typing to trigger. Wait for ghost text, press Tab to accept.[/i][/color]"
	_lbl_keybinds.add_theme_font_size_override("normal_font_size", 11)
	inner.add_child(_lbl_keybinds)

	inner.add_child(_hsep())

	# ── Debug ────────────────────────────────────────────────────────────────
	inner.add_child(_section_label("Debug"))

	_btn_log = Button.new(); _btn_log.text = "📋  View Relay Log"
	_btn_log.pressed.connect(_on_view_log)
	inner.add_child(_btn_log)

	inner.add_child(_hsep())

	# ── Save button ──────────────────────────────────────────────────────────
	_btn_save = Button.new(); _btn_save.text = "  Save Settings  "
	_btn_save.pressed.connect(_on_save_settings)
	var save_row := HBoxContainer.new()
	save_row.add_child(_btn_save)
	inner.add_child(save_row)

# ── UI helpers ────────────────────────────────────────────────────────────────

func _vsep() -> VSeparator:
	return VSeparator.new()

func _hsep() -> HSeparator:
	return HSeparator.new()

func _section_label(text: String) -> Label:
	var lbl := Label.new(); lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.55, 0.75, 0.55))
	return lbl

# ── Auth state machine ────────────────────────────────────────────────────────

func _set_auth_state(s: AuthState) -> void:
	_auth_state = s
	if not is_instance_valid(_view_out): return
	_view_out.visible    = (s == AuthState.SIGNED_OUT)
	_view_wait.visible   = (s == AuthState.WAITING)
	_view_authed.visible = (s == AuthState.AUTHED)
	_view_error.visible  = (s == AuthState.ERROR)
	match s:
		AuthState.SIGNED_OUT:
			_lbl_status.text = "Not signed in"
			_dot.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
			_lbl_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			_spin_timer.stop()
		AuthState.WAITING:
			_lbl_status.text = "Waiting for authorization…"
			_dot.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))
			_lbl_status.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))
			_spin_timer.start()
		AuthState.AUTHED:
			_dot.add_theme_color_override("font_color", Color(0.4, 0.85, 0.5))
			_lbl_status.add_theme_color_override("font_color", Color(0.4, 0.85, 0.5))
			_spin_timer.stop()
		AuthState.ERROR:
			_lbl_status.text = "Error"
			_dot.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
			_lbl_status.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
			_spin_timer.stop()

# ── Model helpers ─────────────────────────────────────────────────────────────

func _populate_models() -> void:
	var popup := _btn_model.get_popup()
	popup.clear()
	popup.add_item("Default (auto)", 0)
	popup.set_item_checked(0, _manager.get_current_model().is_empty())
	for i in range(_models_list.size()):
		var m: Dictionary = _models_list[i]
		var label: String = m.get("modelName", m.get("name", m.get("id", "?")))
		var id:    String = m.get("id", "")
		popup.add_item(label, i + 1)
		popup.set_item_checked(i + 1, _manager.get_current_model() == id)

func _model_display(id: String) -> String:
	if id.is_empty(): return "Default"
	for m in _models_list:
		if m.get("id", "") == id:
			return m.get("modelName", m.get("name", id))
	return id

# ── Settings load/save ────────────────────────────────────────────────────────

func _load_settings_to_ui() -> void:
	if not is_instance_valid(_chk_auto_show): return
	_chk_auto_show.button_pressed  = _settings.auto_show_completions
	_chk_auto_start.button_pressed = _settings.auto_start
	_chk_remember.button_pressed   = _settings.remember_session
	_spin_debounce.value           = _settings.debounce_delay
	_color_ghost.color             = _settings.ghost_color

func _on_save_settings() -> void:
	_settings.auto_show_completions = _chk_auto_show.button_pressed
	_settings.auto_start            = _chk_auto_start.button_pressed
	_settings.remember_session      = _chk_remember.button_pressed
	_settings.debounce_delay        = _spin_debounce.value
	_settings.ghost_color           = _color_ghost.color
	_settings.save_settings()
	_btn_save.text = "✓  Saved!"
	get_tree().create_timer(1.5).timeout.connect(func():
		if is_instance_valid(_btn_save): _btn_save.text = "  Save Settings  "
	)

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_signin_pressed() -> void:
	_btn_signin.disabled = true; _btn_retry.disabled = true
	_manager.start_sign_in()

func _on_cancel_pressed() -> void:
	_manager.sign_out()

func _on_signout_pressed() -> void:
	_lbl_user.text = ""; _manager.sign_out()

func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(_user_code)
	_btn_copy.text = "✓  Copied!"
	get_tree().create_timer(1.5).timeout.connect(func():
		if is_instance_valid(_btn_copy): _btn_copy.text = "⎘  Copy Code"
	)

func _on_auth_changed(ok: bool) -> void:
	if not is_instance_valid(_btn_signin): return
	_btn_signin.disabled = false; _btn_retry.disabled = false
	if ok:
		_set_auth_state(AuthState.AUTHED)
	else:
		_lbl_user.text = ""
		_set_auth_state(AuthState.SIGNED_OUT)

func _on_code_ready(code: String, uri: String) -> void:
	_user_code = code; _verify_uri = uri
	_lbl_code.text = code
	_set_auth_state(AuthState.WAITING)
	OS.shell_open(uri)

func _on_error(msg: String) -> void:
	if not is_instance_valid(_btn_signin): return
	_btn_signin.disabled = false; _btn_retry.disabled = false
	_lbl_error.text = "⚠  " + msg
	_set_auth_state(AuthState.ERROR)

func _on_status(text: String) -> void:
	if not is_instance_valid(_lbl_status): return
	_lbl_status.text = text
	if not is_instance_valid(_lbl_user): return
	if "as " in text:
		var parts := text.split("as ", true, 1)
		if parts.size() == 2:
			_lbl_user.text = "@" + parts[1].strip_edges()

func _on_models(models: Array) -> void:
	_models_list = models
	_btn_refresh.disabled = false
	_populate_models()
	# Restore saved model
	if not _settings.saved_model_id.is_empty():
		_manager.set_model(_settings.saved_model_id)
		_btn_model.text = _model_display(_settings.saved_model_id)

func _on_model_selected(idx: int) -> void:
	var model_id := ""
	if idx > 0:
		var m: Dictionary = _models_list[idx - 1]
		model_id = m.get("id", "")
	_manager.set_model(model_id)
	_btn_model.text = _model_display(model_id)
	_settings.set_model(model_id)   # persist
	_populate_models()

func _on_view_log() -> void:
	var log_text: String = _manager.get_relay_log()
	# Show in a popup
	var dlg := AcceptDialog.new()
	dlg.title = "Copilot Relay Log"
	dlg.size  = Vector2(700, 400)
	var rt := RichTextLabel.new()
	rt.text              = log_text
	rt.fit_content       = false
	rt.scroll_following  = true
	rt.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dlg.add_child(rt)
	add_child(dlg)
	dlg.popup_centered()
