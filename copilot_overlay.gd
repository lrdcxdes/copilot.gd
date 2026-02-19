@tool
## Draws ghost-text inline suggestion on top of CodeEdit.
## Tab to accept (handled in plugin.gd), Esc to dismiss.
extends Control

const GHOST_COLOR := Color(0.6, 0.6, 0.6, 0.5)

var _code_edit: CodeEdit = null
var _suggestion: String = ""
var _insert_line: int = -1
var _insert_col: int = -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func has_suggestion() -> bool:
	return _suggestion != ""

func show_suggestion(text: String, code_edit: CodeEdit) -> void:
	_code_edit = code_edit
	_insert_line = code_edit.get_caret_line()
	_insert_col = code_edit.get_caret_column()

	_suggestion = _sanitize_suggestion(text, code_edit, _insert_line, _insert_col)
	_suggestion = _trim_suffix_overlap(_suggestion)

	if _suggestion.strip_edges().is_empty():
		hide_suggestion()
		return

	visible = true
	queue_redraw()

func hide_suggestion() -> void:
	_suggestion = ""
	_insert_line = -1
	_insert_col = -1
	visible = false
	queue_redraw()

func _find_overlap(a: String, b: String) -> int:
	var max_len := min(a.length(), b.length())
	for i in range(max_len, 0, -1):
		if a.ends_with(b.substr(0, i)):
			return i
	return 0

func _trim_suffix_overlap(text: String) -> String:
	if not is_instance_valid(_code_edit) or _insert_line < 0 or _insert_col < 0:
		return text

	var suffix := _code_edit.get_line(_insert_line).substr(_insert_col)
	if suffix.is_empty():
		return text

	var lines := text.split("\n")
	if lines.is_empty():
		return text

	var last := lines[lines.size() - 1]
	var overlap := _find_overlap(last, suffix)
	if overlap <= 0:
		return text

	lines[lines.size() - 1] = last.substr(0, last.length() - overlap)
	return "\n".join(lines)

func accept_suggestion() -> void:
	if not has_suggestion() or not is_instance_valid(_code_edit):
		return

	var lines := _suggestion.split("\n")
	_code_edit.begin_complex_operation()
	for i in range(lines.size()):
		var part := lines[i]
		if i == 0:
			_code_edit.insert_text_at_caret(part)
		else:
			_code_edit.insert_text_at_caret("\n" + part)
	_code_edit.end_complex_operation()

	hide_suggestion()

func _sanitize_suggestion(text: String, editor: CodeEdit, line: int, col: int) -> String:
	var line_text := editor.get_line(line)
	var prefix := line_text.substr(0, col)

	if text.begins_with(prefix):
		return text.substr(prefix.length())

	var stripped_prefix := prefix.strip_edges(false, true)
	if text.begins_with(stripped_prefix):
		return text.substr(stripped_prefix.length())

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
		elif pc == "\t" and tc == " ":
			p_idx += 1
			while t_idx < t_len and text[t_idx] == " ":
				t_idx += 1
		elif pc == " " and tc == "\t":
			t_idx += 1
			while p_idx < p_len and prefix[p_idx] == " ":
				p_idx += 1
		else:
			break

	if p_idx == p_len:
		return text.substr(t_idx)

	if text.strip_edges().begins_with(prefix.strip_edges()):
		var raw_prefix_end := text.find(prefix.strip_edges()) + prefix.strip_edges().length()
		if raw_prefix_end > 0:
			return text.substr(raw_prefix_end)

	return text

func _draw() -> void:
	if not has_suggestion() or not is_instance_valid(_code_edit):
		return

	var font := _code_edit.get_theme_font("font", "CodeEdit")
	var font_size := _code_edit.get_theme_font_size("font_size", "CodeEdit")
	if not font:
		return

	var line_height := _code_edit.get_line_height()
	var ascent := font.get_ascent(font_size)
	var v_offset := ascent + (line_height - font.get_height(font_size)) * 0.5 + 1.0

	var caret_rect := _code_edit.get_rect_at_line_column(_insert_line, _insert_col)
	var line_start_rect := _code_edit.get_rect_at_line_column(_insert_line, 0)

	var tab_spaces := ""
	for _s in range(_code_edit.indent_size):
		tab_spaces += " "

	var prefix := _code_edit.get_line(_insert_line).substr(0, _insert_col).replace("\t", tab_spaces)
	var prefix_width := font.get_string_size(prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

	var suggestion_lines := _suggestion.split("\n")
	var suggestion_display := []
	for line in suggestion_lines:
		suggestion_display.append(line.replace("\t", tab_spaces))

	var suffix := _code_edit.get_line(_insert_line).substr(_insert_col).replace("\t", tab_spaces)
	var has_suffix := not suffix.is_empty()
	var suffix_width := 0.0
	if has_suffix:
		suffix_width = font.get_string_size(suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

	# Hide native suffix under the caret so we can redraw it shifted.
	if has_suffix:
		var bg := _code_edit.get_theme_color("background_color", "CodeEdit")
		draw_rect(
			Rect2(
				Vector2(line_start_rect.position.x + prefix_width, caret_rect.position.y),
				Vector2(suffix_width + 4.0, line_height)
			),
			bg,
			true
		)

	for i in range(suggestion_display.size()):
		var draw_pos := Vector2(
			line_start_rect.position.x + prefix_width if i == 0 else line_start_rect.position.x,
			caret_rect.position.y + (i * line_height) + v_offset
		)
		draw_string(font, draw_pos, suggestion_display[i], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, GHOST_COLOR)

	if has_suffix:
		# Draw suffix where it would end up after accepting completion.
		# For multi-line suggestions we cannot query non-existent target line rect,
		# so we compute virtual position from caret line + line_height.
		var target_y := caret_rect.position.y + ((suggestion_display.size() - 1) * line_height) + v_offset
		var x_shift := 0.0
		if suggestion_display.size() == 1:
			x_shift = prefix_width + font.get_string_size(suggestion_display[0], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		else:
			x_shift = font.get_string_size(suggestion_display[suggestion_display.size() - 1], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

		var target_x := line_start_rect.position.x + x_shift
		var bg := _code_edit.get_theme_color("background_color", "CodeEdit")
		var redraw_width := font.get_string_size(suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_rect(
			Rect2(Vector2(target_x, target_y - v_offset), Vector2(redraw_width + 4.0, line_height)),
			bg,
			true
		)
		draw_string(
			font,
			Vector2(target_x, target_y),
			suffix,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size,
			_code_edit.get_theme_color("font_color", "CodeEdit")
		)

func _process(_dt: float) -> void:
	if visible and is_instance_valid(_code_edit):
		if _code_edit.get_caret_line() != _insert_line or _code_edit.get_caret_column() != _insert_col:
			hide_suggestion()
		else:
			queue_redraw()
