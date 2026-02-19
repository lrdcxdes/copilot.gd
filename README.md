# copilot.gd

GitHub Copilot plugin for Godot 4.6.

## Requirements

- Godot 4.6
- Node.js ≥ 20.8 + NPM
- GitHub account with an active Copilot subscription

Install Node.js from https://nodejs.org/en/download/  
On Debian/Ubuntu: `apt install nodejs npm`

Sign up for Copilot Free or check your access at https://github.com/settings/copilot

---

## Installation

1. Download this repository as `.zip` and unpack it.
2. In your Godot project, create the folder `res://addons/github_copilot/`.
3. Copy all six files into that folder:

```
plugin.cfg
plugin.gd
copilot_manager.gd
copilot_overlay.gd
copilot_panel.gd
copilot_settings.gd
```

4. Open the Godot project.
5. Go to **Project → Project Settings → Plugins** and enable **GitHub Copilot**.

A **Copilot** tab will appear in the bottom panel.

---

## Signing In

1. Open the **Copilot** tab at the bottom of the editor.
2. Click **Sign in with GitHub**.
3. A device code (e.g. `AB12-CD34`) is shown and your browser opens `github.com/login/device` automatically.
4. Enter the code on that page and authorize the app.
5. The plugin polls GitHub every 3 seconds and signs in automatically once confirmed.

The session is remembered across Godot restarts — you will not need to sign in again unless you explicitly sign out or the token expires.

---

## Usage

| Action | Key |
|---|---|
| Accept suggestion | `Tab` |
| Dismiss suggestion | `Esc` |
| Dismiss (cursor move) | Arrow keys / Home / End |

1. Open any `.gd`, `.cs`, or `.glsl` script in the editor.
2. Start typing — a ghost text suggestion appears after a short delay (default 0.65 s).
3. Press `Tab` to accept, `Esc` or any cursor key to dismiss.
4. Typing any character also dismisses the current suggestion and starts a new request.

> **Note:** The autocomplete popup (`Ctrl+Space`) takes priority. If the native completion popup is visible, `Tab` will interact with it instead of accepting the Copilot suggestion.

---

## Model Selection

Once signed in, the Copilot tab shows a **Model** dropdown. Click it to see all available completion models on your account. Select any model and it will be used immediately and saved for future sessions. Click **↺** to refresh the list.

---

## Settings

Click the **Settings** tab in the bottom panel to configure:

| Setting | Default | Description |
|---|---|---|
| Automatically show completions | ✅ | Trigger suggestions as you type |
| Trigger delay | 0.65 s | How long to wait after the last keystroke before requesting |
| Ghost text color | Grey 52% | Color and opacity of the inline suggestion text |
| Auto-connect LSP on startup | ✅ | Reconnects and signs in automatically every time Godot opens |
| Remember sign-in session | ✅ | Skips the device flow if a valid session already exists |

Click **Save Settings** to persist. Settings are stored in `user://copilot_settings.cfg`.

---

## Troubleshooting

**"Node.js not found in PATH"**  
Install Node.js ≥ 20.8. On Windows, restart Godot after installing so the updated PATH is picked up.

**"Timeout: LSP relay did not connect"**  
Click **📋 View Relay Log** in the Settings tab to see the full output from the Node.js relay process. Common causes: `npx` is blocked by a firewall or proxy, or `npm` is not installed alongside Node.js.

**Suggestion text overlaps existing code**  
The overlay draws on top of CodeEdit using a canvas child node. If your editor theme uses a non-standard background colour the erase rect may not match. Open the Settings tab, adjust the Ghost text color, and the background erase will use the theme's `background_color` automatically.

**Suggestions stop appearing after switching scripts**  
This is usually a sign that the LSP lost track of the document. Switch away and back to the script to re-trigger `textDocument/didFocus`, or restart the plugin via **Project Settings → Plugins** (toggle off/on).

**How to see the relay log file**  
Click **📋 View Relay Log** in the Settings tab, or open the file directly:
- Linux/macOS: `/tmp/copilot_relay.log`
- Windows: `%TEMP%\copilot_relay.log`

---

## File Overview

| File | Purpose |
|---|---|
| `plugin.gd` | EditorPlugin entry point — wires everything together, handles keyboard input |
| `copilot_manager.gd` | LSP lifecycle, JSON-RPC over TCP, auth flow, model API, process cleanup |
| `copilot_overlay.gd` | Ghost text rendering via a canvas child node added to CodeEdit |
| `copilot_panel.gd` | Bottom panel UI — Auth tab (sign in/out, model selector) + Settings tab |
| `copilot_settings.gd` | Persistent settings saved to `user://copilot_settings.cfg` |
| `plugin.cfg` | Godot plugin metadata |

---

## Architecture Notes

The plugin uses a **Node.js relay script** to bridge Godot's TCP socket to the `copilot-language-server` stdio process. On first use, `npx` downloads the latest `@github/copilot-language-server` automatically. The relay script is written to the OS temp directory at runtime.

Ghost text is rendered by adding a `Control` node as the **last child** of `CodeEdit` so it paints on top of the editor's own text layer. For mid-line completions, the existing suffix text is erased and redrawn after the ghost text to prevent visual overlap.

All Node.js/LSP child processes are cleaned up on plugin unload via graceful LSP `shutdown`/`exit` messages followed by an OS-level `kill` on the relay PID, with a `fuser -k` fallback on Linux/macOS.