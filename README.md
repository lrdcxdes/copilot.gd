# GitHub Copilot plugin for Godot 4.6

A lightweight open-source Godot editor plugin that connects to `@github/copilot-language-server` and shows inline ghost-text suggestions inside `CodeEdit`.

## What is implemented

- GitHub Copilot authentication (device flow).
- Inline completion requests from current caret position.
- Ghost-text overlay in script editor.
- `Tab` to accept, `Esc` to dismiss.
- Better mid-line behavior:
  - removes already typed prefix from suggestions;
  - trims overlapping suffix (for cases like `print(|)` where Copilot returns `"Hello")`);
  - visually shifts the original right-side text while ghost suggestion is shown.

## Install

1. Copy plugin files into your project addon folder:
   - `res://addons/github_copilot/plugin.cfg`
   - `res://addons/github_copilot/plugin.gd`
   - `res://addons/github_copilot/copilot_manager.gd`
   - `res://addons/github_copilot/copilot_panel.gd`
   - `res://addons/github_copilot/copilot_overlay.gd`
2. In Godot: **Project Settings → Plugins**.
3. Enable **GitHub Copilot** plugin.
4. Open Copilot panel, sign in, and start typing in a script.

## Runtime requirements

- Godot `4.6`.
- `node` in `PATH`.
- Either:
  - `npx` in `PATH` (recommended), or
  - global `copilot-language-server` (`npm i -g @github/copilot-language-server`).

## Notes

- The plugin asks Copilot with exact caret `line` and `character`, so Copilot *does* know cursor position.
- Some completions may still include closing tokens from the right side; this plugin now trims overlap before rendering and before insertion.

## Inspiration

Inline UX behavior is aligned with the `copilot.vim` approach for mid-line completions.
