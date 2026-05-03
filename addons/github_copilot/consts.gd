@tool
extends RefCounted

## Centralized constants for the GitHub Copilot plugin.
## Eliminates magic values and ensures consistency across all files.

const PLUGIN_NAME := "GitHub Copilot"
const PLUGIN_VERSION := "2.1.0"
const PLUGIN_AUTHOR := "Community"
const PLUGIN_DESCRIPTION := "GitHub Copilot AI code completion via official LSP server."

const ADDON_PATH := "res://addons/github_copilot/"

const RELAY_SCRIPT_NAME := "copilot_relay.mjs"
const RELAY_LOG_NAME := "copilot_relay.log"

const DEFAULT_DEBOUNCE_DELAY := 0.65
const MIN_DEBOUNCE_DELAY := 0.2
const MAX_DEBOUNCE_DELAY := 3.0
const DEFAULT_DEBOUNCE_TIMEOUT_SECS := 20.0

const TCP_PORT_MIN := 49200
const TCP_PORT_MAX := 49300

const AUTH_POLL_INTERVAL := 3.0
const AUTH_INIT_DELAY := 0.5
const FEATURE_CHECK_TIMEOUT := 80

const MIN_NODE_VERSION := "20.8"
const LSP_PACKAGE := "@github/copilot-language-server"

const SETTINGS_FILE := "user://copilot_settings.cfg"

const DEFAULT_GHOST_COLOR := Color(0.52, 0.52, 0.52, 0.65)

const AUTH_STATUS_OK := "OK"
const AUTH_STATUS_ALREADY_SIGNED_IN := "AlreadySignedIn"
const AUTH_STATUS_NOT_SIGNED_IN := "NotSignedIn"
const AUTH_STATUS_NOT_AUTHORIZED := "NotAuthorized"

const AUTOWRAP_WORD := TextServer.AUTOWRAP_WORD