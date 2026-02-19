@tool
## Ghost-text inline suggestion for CodeEdit (Godot 4.6).
##
## Rendering fix: A Control child added LAST to CodeEdit draws on top
## of CodeEdit's own text. For each ghost line we:
##   1. Paint an opaque bg rect over the region to erase existing text
##   2. Draw ghost text (grey)
##   3. Re-draw the original suffix AFTER the ghost text
## This prevents any layering / occlusion issues.
##
## The overlay object is a RefCounted (not a node itself); it manages
## a _GhostCanvas inner-class node that is added/removed from CodeEdit.
extends RefCounted

const GHOST_COLOR := Color(0.52, 0.52, 0.52, 0.65)

var _code_edit:   CodeEdit = null
var _suggestion:  String   = ""
var _insert_line: int      = -1
var _insert_col:  int      = -1
var _canvas:      Control  = null

# ── Public API ────────────────────────────────────────────────────────────────

func has_suggestion() -> bool:
	return _canvas != null and is_instance_valid(_canvas)

func show_suggestion(text: String, code_edit: CodeEdit) -> void:
	_destroy_canvas()
	_code_edit   = code_edit
	_insert_line = code_edit.get_caret_line()
	_insert_col  = code_edit.get_caret_column()
	_suggestion  = _sanitize(text, code_edit, _insert_line, _insert_col)
	if _suggestion.strip_edges().is_empty():
		return
	_spawn_canvas()

func hide_suggestion() -> void:
	_destroy_canvas()
	_suggestion  = ""
	_insert_line = -1
	_insert_col  = -1

func accept_suggestion() -> void:
	if not has_suggestion() or not is_instance_valid(_code_edit): return
	var text := _suggestion
	_destroy_canvas()

	# Remove overlap with existing suffix
	var cur_line := _code_edit.get_line(_insert_line)
	var suffix   := cur_line.substr(_insert_col)
	var overlap  := _find_overlap(text, suffix)
	if overlap > 0:
		_code_edit.select(_insert_line, _insert_col,
						  _insert_line, _insert_col + overlap)
		_code_edit.delete_selection()

	_code_edit.set_caret_line(_insert_line)
	_code_edit.set_caret_column(_insert_col)
	_code_edit.begin_complex_operation()
	var parts := text.split("\n")
	for i in range(parts.size()):
		_code_edit.insert_text_at_caret(("\n" if i > 0 else "") + parts[i])
	_code_edit.end_complex_operation()

	_suggestion  = ""
	_insert_line = -1
	_insert_col  = -1

# ── Canvas management ─────────────────────────────────────────────────────────

func _spawn_canvas() -> void:
	if not is_instance_valid(_code_edit): return
	var cv          := _GhostCanvas.new()
	cv.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	cv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cv.code_edit    = _code_edit
	cv.suggestion   = _suggestion
	cv.insert_line  = _insert_line
	cv.insert_col   = _insert_col
	cv.ghost_color  = GHOST_COLOR
	_code_edit.add_child(cv)
	_canvas = cv

func _destroy_canvas() -> void:
	if is_instance_valid(_canvas):
		_canvas.queue_free()
	_canvas = null

# ── Helpers ───────────────────────────────────────────────────────────────────

static func _find_overlap(a: String, b: String) -> int:
	var max_len := min(a.length(), b.length())
	for i in range(max_len, 0, -1):
		if a.ends_with(b.substr(0, i)):
			return i
	return 0

static func _sanitize(text: String, editor: CodeEdit,
		line: int, col: int) -> String:
	var line_text := editor.get_line(line)
	var prefix    := line_text.substr(0, col)
	if text.begins_with(prefix):
		return text.substr(prefix.length())
	var stripped := prefix.rstrip(" \t")
	if not stripped.is_empty() and text.begins_with(stripped):
		return text.substr(stripped.length())
	# fuzzy tab/space walk
	var pi := 0; var ti := 0
	var pl := prefix.length(); var tl := text.length()
	while pi < pl and ti < tl:
		var pc := prefix[pi]; var tc := text[ti]
		if pc == tc:
			pi += 1; ti += 1
		elif pc == "\t" and tc == " ":
			pi += 1
			while ti < tl and text[ti] == " ": ti += 1
		elif pc == " " and tc == "\t":
			ti += 1
			while pi < pl and prefix[pi] == " ": pi += 1
		else: break
	if pi == pl: return text.substr(ti)
	return text


# ════════════════════════════════════════════════════════════════════════════
# _GhostCanvas — added as LAST child of CodeEdit so it paints on top
# ════════════════════════════════════════════════════════════════════════════
class _GhostCanvas extends Control:
	var code_edit:   CodeEdit
	var suggestion:  String
	var insert_line: int
	var insert_col:  int
	var ghost_color: Color

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	func _process(_dt: float) -> void:
		# Dismiss if caret moved
		if is_instance_valid(code_edit):
			if code_edit.get_caret_line() != insert_line or \
			   code_edit.get_caret_column() != insert_col:
				# Signal parent to dismiss — find the RefCounted owner
				queue_free()
				return
		queue_redraw()

	func _draw() -> void:
		if not is_instance_valid(code_edit) or suggestion.is_empty(): return

		var font      := code_edit.get_theme_font("font", "CodeEdit")
		var font_size := code_edit.get_theme_font_size("font_size", "CodeEdit")
		if not font: return

		var line_h  := code_edit.get_line_height()
		var ascent  := font.get_ascent(font_size)
		var v_off   := ascent + (line_h - font.get_height(font_size)) * 0.5 + 1.0

		var tab_str := "".lpad(code_edit.indent_size, " ")

		var caret_r := code_edit.get_rect_at_line_column(insert_line, insert_col)
		var line0_r := code_edit.get_rect_at_line_column(insert_line, 0)
		if caret_r.position.x < 0: return

		# Prefix width for first-line x position
		var prefix_disp := code_edit.get_line(insert_line).substr(0, insert_col) \
							.replace("\t", tab_str)
		var prefix_w    := font.get_string_size(prefix_disp,
							HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

		# Suffix (text to the right of cursor on the caret line)
		var suffix_raw  := code_edit.get_line(insert_line).substr(insert_col)
		var suffix_disp := suffix_raw.replace("\t", tab_str)
		var suffix_w    := font.get_string_size(suffix_disp,
							HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

		# Editor background colour
		var bg := code_edit.get_theme_color("background_color", "CodeEdit")
		if bg.a < 0.05:
			bg = Color(0.13, 0.13, 0.13, 1.0)
		bg.a = 1.0

		var normal_col := code_edit.get_theme_color("font_color", "CodeEdit")

		var ghost_lines := suggestion.split("\n")

		for i in range(ghost_lines.size()):
			var gdisp  := ghost_lines[i].replace("\t", tab_str)
			var gw     := font.get_string_size(gdisp,
							HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var gx     := line0_r.position.x + prefix_w if i == 0 \
						  else line0_r.position.x
			var gy_top := caret_r.position.y + i * line_h
			var gy     := gy_top + v_off

			if i == 0:
				# ── Erase original suffix ──────────────────────────────
				# Covers the area where suffix currently renders
				if suffix_w > 0:
					draw_rect(Rect2(gx, gy_top, suffix_w + 4.0, line_h), bg)

				# ── Draw ghost ────────────────────────────────────────
				draw_string(font, Vector2(gx, gy), gdisp,
							HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ghost_color)

				# ── Redraw suffix after ghost ─────────────────────────
				if suffix_w > 0:
					var sx: int = gx + gw
					draw_rect(Rect2(sx, gy_top, suffix_w + 4.0, line_h), bg)
					draw_string(font, Vector2(sx, gy), suffix_disp,
								HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, normal_col)
			else:
				# ── Extra ghost lines ─────────────────────────────────
				# May overlap real document lines below — erase first
				draw_rect(Rect2(line0_r.position.x, gy_top, gw + 8.0, line_h), bg)
				draw_string(font, Vector2(gx, gy), gdisp,
							HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ghost_color)

		# Annotation
		if ghost_lines.size() > 1:
			var li := ghost_lines.size() - 1
			var lw := font.get_string_size(ghost_lines[li].replace("\t", tab_str),
						HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			draw_string(font,
				Vector2(line0_r.position.x + lw + 8.0,
						caret_r.position.y + li * line_h + v_off),
				"(%d lines)" % ghost_lines.size(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size - 1,
				Color(0.4, 0.65, 0.4, 0.65))
