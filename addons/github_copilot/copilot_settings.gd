@tool
## Persistent settings for the GitHub Copilot plugin.
## Saved to user://copilot_settings.cfg
extends RefCounted

const CopilotConsts := preload("res://addons/github_copilot/consts.gd")

var auto_show_completions: bool = true
var debounce_delay: float = CopilotConsts.DEFAULT_DEBOUNCE_DELAY
var accept_key: int = KEY_TAB
var dismiss_key: int = KEY_ESCAPE
var ghost_color: Color = CopilotConsts.DEFAULT_GHOST_COLOR

var auto_start: bool = true
var saved_model_id: String = ""

var remember_session: bool = true

signal settings_changed()

func _init() -> void:
	load_settings()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CopilotConsts.SETTINGS_FILE) != OK:
		return
	auto_show_completions = cfg.get_value("completion", "auto_show", true)
	debounce_delay = cfg.get_value("completion", "debounce", CopilotConsts.DEFAULT_DEBOUNCE_DELAY)
	ghost_color = cfg.get_value("completion", "ghost_color", CopilotConsts.DEFAULT_GHOST_COLOR)
	auto_start = cfg.get_value("session", "auto_start", true)
	saved_model_id = cfg.get_value("session", "model_id", "")
	remember_session = cfg.get_value("session", "remember", true)

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("completion", "auto_show", auto_show_completions)
	cfg.set_value("completion", "debounce", debounce_delay)
	cfg.set_value("completion", "ghost_color", ghost_color)
	cfg.set_value("session", "auto_start", auto_start)
	cfg.set_value("session", "model_id", saved_model_id)
	cfg.set_value("session", "remember", remember_session)
	cfg.save(CopilotConsts.SETTINGS_FILE)
	settings_changed.emit()

func set_model(id: String) -> void:
	saved_model_id = id
	save_settings()