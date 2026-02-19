@tool
## Bottom-panel UI: 4 states — signed_out / waiting / authed / error
extends PanelContainer

var _manager

enum State { SIGNED_OUT, WAITING, AUTHED, ERROR }
var _state := State.SIGNED_OUT
var _verify_uri := ""
var _user_code  := ""

# widgets
var _lbl_status:  Label
var _lbl_code:    Label
var _lbl_info:    Label
var _btn_signin:  Button
var _btn_copy:    Button
var _btn_browser: Button
var _btn_cancel:  Button
var _btn_signout: Button
var _lbl_error:   Label
var _btn_retry:   Button

# views (HBoxContainers swapped by state)
var _view_out:    Control
var _view_wait:   Control
var _view_authed: Control
var _view_error:  Control

# spinner
var _spin_chars := ["|", "/", "-", "\\"]
var _spin_idx   := 0
var _spin_timer: Timer

func _init(manager) -> void:
	_manager = manager

func _ready() -> void:
	custom_minimum_size = Vector2(0, 74)
	_build()

	_manager.auth_status_changed.connect(_on_auth_changed)
	_manager.auth_device_code_ready.connect(_on_code_ready)
	_manager.auth_error.connect(_on_error)
	_manager.status_message.connect(func(t): _lbl_status.text = t)

	_spin_timer = Timer.new()
	_spin_timer.wait_time = 0.15
	_spin_timer.timeout.connect(func():
		_spin_idx = (_spin_idx + 1) % 4
		_lbl_info.text = _spin_chars[_spin_idx] + "  Waiting for GitHub confirmation…"
	)
	add_child(_spin_timer)

	_set_state(State.SIGNED_OUT)

# ── Build ─────────────────────────────────────────────────────────────────────

func _build() -> void:
	var margin := MarginContainer.new()
	for s in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + s, 10)
	add_child(margin)

	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	margin.add_child(root)

	# ── Left column: icon + status ──
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 210
	left.add_theme_constant_override("separation", 2)
	root.add_child(left)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	left.add_child(title_row)
	var ico := Label.new(); ico.text = "⬡"
	ico.add_theme_font_size_override("font_size", 15)
	title_row.add_child(ico)
	var title := Label.new(); title.text = "GitHub Copilot"
	title.add_theme_font_size_override("font_size", 13)
	title_row.add_child(title)

	_lbl_status = Label.new()
	_lbl_status.text = "Not signed in"
	_lbl_status.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_lbl_status.add_theme_font_size_override("font_size", 11)
	left.add_child(_lbl_status)

	var sep := VSeparator.new(); root.add_child(sep)
	_spacer(root, 4)

	# ── SIGNED OUT view ──
	_view_out = HBoxContainer.new()
	_view_out.add_theme_constant_override("separation", 10)
	root.add_child(_view_out)

	_btn_signin = Button.new()
	_btn_signin.text = "  Sign in with GitHub  "
	_btn_signin.pressed.connect(_on_signin_pressed)
	_view_out.add_child(_btn_signin)

	var hint := Label.new()
	hint.text = "Requires Node.js ≥ 20.8 and a GitHub Copilot subscription."
	hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	hint.add_theme_font_size_override("font_size", 11)
	_view_out.add_child(hint)

	# ── WAITING view ──
	_view_wait = HBoxContainer.new()
	_view_wait.add_theme_constant_override("separation", 12)
	root.add_child(_view_wait)

	var code_panel := PanelContainer.new()
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.12, 0.12, 0.12)
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sbox.set_border_width(side, 1)
	sbox.border_color = Color(0.3, 0.3, 0.3)
	sbox.corner_radius_top_left     = 6
	sbox.corner_radius_top_right    = 6
	sbox.corner_radius_bottom_left  = 6
	sbox.corner_radius_bottom_right = 6
	sbox.content_margin_left   = 16
	sbox.content_margin_right  = 16
	sbox.content_margin_top    = 5
	sbox.content_margin_bottom = 5
	code_panel.add_theme_stylebox_override("panel", sbox)
	_view_wait.add_child(code_panel)

	_lbl_code = Label.new()
	_lbl_code.text = "XXXX-XXXX"
	_lbl_code.add_theme_font_size_override("font_size", 22)
	_lbl_code.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	code_panel.add_child(_lbl_code)

	var wait_btns := VBoxContainer.new()
	wait_btns.add_theme_constant_override("separation", 4)
	_view_wait.add_child(wait_btns)

	_btn_copy = Button.new(); _btn_copy.text = "⎘  Copy Code"
	_btn_copy.pressed.connect(_on_copy_pressed)
	wait_btns.add_child(_btn_copy)

	_btn_browser = Button.new(); _btn_browser.text = "↗  Open github.com/login/device"
	_btn_browser.pressed.connect(func(): OS.shell_open(_verify_uri))
	wait_btns.add_child(_btn_browser)

	_btn_cancel = Button.new(); _btn_cancel.text = "Cancel"; _btn_cancel.flat = true
	_btn_cancel.pressed.connect(_on_cancel_pressed)
	wait_btns.add_child(_btn_cancel)

	_lbl_info = Label.new()
	_lbl_info.text = ""
	_lbl_info.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_lbl_info.add_theme_font_size_override("font_size", 11)
	_view_wait.add_child(_lbl_info)

	# ── AUTHED view ──
	_view_authed = HBoxContainer.new()
	_view_authed.add_theme_constant_override("separation", 20)
	root.add_child(_view_authed)

	var keys_col := VBoxContainer.new()
	keys_col.add_theme_constant_override("separation", 2)
	_view_authed.add_child(keys_col)
	var kt := Label.new(); kt.text = "Keybindings"
	kt.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	kt.add_theme_font_size_override("font_size", 11)
	keys_col.add_child(kt)
	var kb := Label.new(); kb.text = "Tab  →  Accept suggestion\nEsc  →  Dismiss suggestion"
	kb.add_theme_font_size_override("font_size", 11)
	keys_col.add_child(kb)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_authed.add_child(spacer)

	_btn_signout = Button.new(); _btn_signout.text = "Sign Out"; _btn_signout.flat = true
	_btn_signout.pressed.connect(func(): _manager.sign_out())
	_view_authed.add_child(_btn_signout)

	# ── ERROR view ──
	_view_error = HBoxContainer.new()
	_view_error.add_theme_constant_override("separation", 10)
	root.add_child(_view_error)

	_lbl_error = Label.new(); _lbl_error.text = ""
	_lbl_error.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	_lbl_error.autowrap_mode = TextServer.AUTOWRAP_WORD
	_lbl_error.custom_minimum_size.x = 400
	_view_error.add_child(_lbl_error)

	_btn_retry = Button.new(); _btn_retry.text = "Try Again"
	_btn_retry.pressed.connect(_on_signin_pressed)
	_view_error.add_child(_btn_retry)

# ── State machine ─────────────────────────────────────────────────────────────

func _set_state(s: State) -> void:
	_state = s
	_view_out.visible    = (s == State.SIGNED_OUT)
	_view_wait.visible   = (s == State.WAITING)
	_view_authed.visible = (s == State.AUTHED)
	_view_error.visible  = (s == State.ERROR)

	match s:
		State.SIGNED_OUT:
			_lbl_status.text = "Not signed in"
			_lbl_status.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			_spin_timer.stop()
		State.WAITING:
			_lbl_status.text = "Waiting for authorization…"
			_lbl_status.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))
			_spin_timer.start()
		State.AUTHED:
			_lbl_status.add_theme_color_override("font_color", Color(0.4, 0.85, 0.5))
			_spin_timer.stop()
		State.ERROR:
			_lbl_status.text = "Error"
			_lbl_status.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
			_spin_timer.stop()

# ── Handlers ──────────────────────────────────────────────────────────────────

func _on_signin_pressed() -> void:
	_btn_signin.disabled = true
	_btn_retry.disabled  = true
	_manager.start_sign_in()

func _on_cancel_pressed() -> void:
	_manager.sign_out()

func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(_user_code)
	_btn_copy.text = "✓  Copied!"
	get_tree().create_timer(1.5).timeout.connect(func():
		if is_instance_valid(_btn_copy): _btn_copy.text = "⎘  Copy Code"
	)

func _on_auth_changed(ok: bool) -> void:
	_btn_signin.disabled = false
	_btn_retry.disabled  = false
	if ok:
		_set_state(State.AUTHED)
	else:
		_set_state(State.SIGNED_OUT)

func _on_code_ready(code: String, uri: String) -> void:
	_user_code  = code
	_verify_uri = uri
	_lbl_code.text = code
	_set_state(State.WAITING)
	OS.shell_open(uri)

func _on_error(msg: String) -> void:
	_btn_signin.disabled = false
	_btn_retry.disabled  = false
	_lbl_error.text = "⚠  " + msg
	_set_state(State.ERROR)

# ── Helper ────────────────────────────────────────────────────────────────────

func _spacer(parent: Control, w: int) -> void:
	var s := Control.new(); s.custom_minimum_size.x = w; parent.add_child(s)
