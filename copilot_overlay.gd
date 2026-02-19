@tool
## Draws ghost-text inline suggestion on top of CodeEdit.
## Tab to accept (handled in plugin.gd), Esc to dismiss.
extends Control

const GHOST_COLOR := Color(0.6, 0.6, 0.6, 0.5)

var _code_edit:   CodeEdit = null
var _suggestion:  String   = ""
var _insert_line: int      = -1
var _insert_col:  int      = -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func has_suggestion() -> bool:
	return _suggestion != ""

func show_suggestion(text: String, code_edit: CodeEdit) -> void:
	_code_edit   = code_edit
	_insert_line = code_edit.get_caret_line()
	_insert_col  = code_edit.get_caret_column()
	
	# Sanitize: Remove the part of the line we've already typed
	_suggestion = _sanitize_suggestion(text, code_edit, _insert_line, _insert_col)
	
	if _suggestion.strip_edges().is_empty():
		hide_suggestion()
		return
		
	visible = true
	queue_redraw()

func hide_suggestion() -> void:
	_suggestion  = ""
	_insert_line = -1
	_insert_col  = -1
	visible = false
	queue_redraw()
	

func _find_overlap(a: String, b: String) -> int:
	var max_len := min(a.length(), b.length())
	for i in range(max_len, 0, -1):
		if a.ends_with(b.substr(0, i)):
			return i
	return 0

func accept_suggestion() -> void:
	if not has_suggestion() or not is_instance_valid(_code_edit):
		return
	
	var text := _suggestion
	
	var current_line := _code_edit.get_line(_insert_line)
	var suffix := current_line.substr(_insert_col)
	
	var overlap := _find_overlap(_suggestion, suffix)

	if overlap > 0:
		_code_edit.select(
			_insert_line,
			_insert_col,
			_insert_line,
			_insert_col + overlap
		)
		_code_edit.delete_selection()

	_code_edit.begin_complex_operation()
	for i in range(text.split("\n").size()):
		var part := text.split("\n")[i]
		if i == 0:
			_code_edit.insert_text_at_caret(part)
		else:
			_code_edit.insert_text_at_caret("\n" + part)
	_code_edit.end_complex_operation()
	
	hide_suggestion()

# Intelligent cleaner that handles Tabs vs Spaces mismatches
func _sanitize_suggestion(text: String, editor: CodeEdit, line: int, col: int) -> String:
	var line_text := editor.get_line(line)
	var prefix := line_text.substr(0, col)
	
	# Try exact match, then try matching without trailing/leading whitespace
	if text.begins_with(prefix):
		return text.substr(prefix.length())
	
	var stripped_prefix := prefix.strip_edges(false, true) # Strip right only
	if text.begins_with(stripped_prefix):
		return text.substr(stripped_prefix.length())

	# 2. Fuzzy Match (Handles Tabs vs Spaces)
	# We walk both strings. If characters match, advance.
	# If one has a Tab and the other has Spaces, we treat them as matching indent.
	var p_idx := 0
	var t_idx := 0
	var p_len := prefix.length()
	var t_len := text.length()
	
	while p_idx < p_len and t_idx < t_len:
		var pc := prefix[p_idx]
		var tc := text[t_idx]
		
		if pc == tc:
			p_idx += 1
			t_idx += 1
		# Handle Tab in Prefix, Spaces in Text
		elif pc == "\t" and tc == " ":
			# Assume standard 4-space tab (or just skip spaces in text until non-space)
			p_idx += 1
			while t_idx < t_len and text[t_idx] == " ":
				t_idx += 1
		# Handle Spaces in Prefix, Tab in Text
		elif pc == " " and tc == "\t":
			t_idx += 1
			while p_idx < p_len and prefix[p_idx] == " ":
				p_idx += 1
		else:
			# Mismatch found before prefix ended
			# This usually means the suggestion is NOT a full line completion,
			# or the user typed something completely different from what Copilot assumed.
			# In this case, we can't safely trim.
			# However, for the specific "Duplicate Line" bug, the prefix usually matches closely.
			break
	
	# If we successfully consumed the whole prefix (or most of it)
	if p_idx == p_len:
		return text.substr(t_idx)

	# 3. Fallback: If strict matching failed, try checking stripped content
	# This helps if there are trailing spaces in the editor not in the suggestion
	if text.strip_edges().begins_with(prefix.strip_edges()):
		# Dangerous: could cut wrong, but better than showing double text
		# We find where the prefix ends in the raw text
		var raw_prefix_end = text.find(prefix.strip_edges()) + prefix.strip_edges().length()
		if raw_prefix_end > 0:
			return text.substr(raw_prefix_end)
			
	return text

func _draw() -> void:
	if not has_suggestion() or not is_instance_valid(_code_edit):
		return
		
	var font := _code_edit.get_theme_font("font", "CodeEdit")
	var font_size := _code_edit.get_theme_font_size("font_size", "CodeEdit")
	if not font: return

	var line_height := _code_edit.get_line_height()
	var ascent      := font.get_ascent(font_size)
	
	# Fix: Better vertical centering (Godot 4 line height logic)
	var v_offset := ascent + (line_height - font.get_height(font_size)) * 0.5
	v_offset += 1.0
	
	var caret_rect := _code_edit.get_rect_at_line_column(_insert_line, _insert_col)
	var line_start_rect := _code_edit.get_rect_at_line_column(_insert_line, 0)
	
	# Prepare tab expansion for correct horizontal display
	var tab_spaces := ""
	for s in range(_code_edit.indent_size): tab_spaces += " "
	
	var prefix := _code_edit.get_line(_insert_line).substr(0, _insert_col)
	prefix = prefix.replace("\t", tab_spaces)
	var prefix_width := font.get_string_size(prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	
	var lines := _suggestion.split("\n")
	
	for i in range(lines.size()):
		# Fix: Replace tabs with spaces for the ghost display only
		var line_display := lines[i].replace("\t", tab_spaces)
		
		var draw_pos := Vector2(
			line_start_rect.position.x + prefix_width if i == 0 else line_start_rect.position.x,
			caret_rect.position.y + (i * line_height) + v_offset
		)
		
		draw_string(font, draw_pos, line_display, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, GHOST_COLOR)

func _process(_dt: float) -> void:
	if visible and is_instance_valid(_code_edit):
		# Fix: Hide suggestion if user moves the cursor or types elsewhere
		if _code_edit.get_caret_line() != _insert_line or _code_edit.get_caret_column() != _insert_col:
			hide_suggestion()
		else:
			queue_redraw()
