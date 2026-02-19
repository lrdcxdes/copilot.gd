# copilot.gd

GitHub Copilot plugin for Godot 4.6.

## Requirements

- Godot 4.6
- Node.js + NPM
- GitHub account with Copilot access

Install Node.js from https://nodejs.org/en/download/.
If you use a package manager, make sure to install NPM as well (for example: `apt install nodejs npm` on Debian/Ubuntu).

To access GitHub Copilot, an active GitHub Copilot subscription is required.
You can sign up for GitHub Copilot Free, or request access from your enterprise admin:
https://github.com/settings/copilot

## Installation

1. Download this repository as `.zip`.
2. Unpack the `copilot.gd` folder.
3. Copy plugin files into your Godot project:
   - create folder `res://addons/github_copilot/`
   - copy `plugin.cfg`, `plugin.gd`, `copilot_manager.gd`, `copilot_panel.gd`, `copilot_overlay.gd` into it.
4. Open Godot project.
5. Go to **Project Settings → Plugins** and enable **GitHub Copilot**.

After enabling, a **Copilot** tab appears in the editor. There you can sign in using GitHub OAuth.

## Usage

- Open a script in Godot editor.
- Start typing.
- Wait for inline suggestion (ghost text).
- Press `Tab` to accept.
- Press `Esc` to dismiss.

## Notes

- Plugin sends completion request with exact caret line/column, so Copilot knows cursor position.
- Mid-line completion now trims overlap with the text on the right side and renders suffix shifted, similar to `copilot.vim` behavior.
