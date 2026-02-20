@tool
## Persistent settings for the GitHub Copilot plugin.
## Saved to user://copilot_settings.cfg
extends RefCounted

const SETTINGS_PATH := "user://copilot_settings.cfg"

# Completion
var auto_show_completions: bool = true
var debounce_delay:        float = 0.65   # seconds
var accept_key:            int   = KEY_TAB
var dismiss_key:           int   = KEY_ESCAPE
var ghost_color:           Color = Color(0.52, 0.52, 0.52, 0.65)

# Session
var auto_start:      bool   = true    # reconnect LSP on Godot restart
var saved_model_id:  String = ""      # last used model

# Auth token cache (stored separately, read-only here)
var remember_session: bool = true

signal settings_changed()

func _init() -> void:
	load_settings()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	auto_show_completions = cfg.get_value("completion", "auto_show",  true)
	debounce_delay        = cfg.get_value("completion", "debounce",   0.65)
	ghost_color           = cfg.get_value("completion", "ghost_color", Color(0.52, 0.52, 0.52, 0.65))
	auto_start            = cfg.get_value("session",    "auto_start", true)
	saved_model_id        = cfg.get_value("session",    "model_id",   "")
	remember_session      = cfg.get_value("session",    "remember",   true)

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("completion", "auto_show",   auto_show_completions)
	cfg.set_value("completion", "debounce",    debounce_delay)
	cfg.set_value("completion", "ghost_color", ghost_color)
	cfg.set_value("session",    "auto_start",  auto_start)
	cfg.set_value("session",    "model_id",    saved_model_id)
	cfg.set_value("session",    "remember",    remember_session)
	cfg.save(SETTINGS_PATH)
	settings_changed.emit()

func set_model(id: String) -> void:
	saved_model_id = id
	save_settings()
