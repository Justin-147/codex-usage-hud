# Changelog

## v0.1.2

Project metadata update.

Highlights:

- Adds the MIT License.
- Adds a license badge and License section to README.

## v0.1.1

Compatibility update for current Codex quota data.

Highlights:

- Handles Codex app-server returning a single 7-day quota window instead of separate 5-hour and 7-day windows.
- Expands the quota meter when only one quota window is returned.
- Keeps compatibility with two quota windows if Codex returns both again later.
- Updates README and dashboard preview to match the current weekly quota behavior.

Validation:

- Verified against local app-server data: `windowDurationMins = 10080`, with no secondary quota window.

## v0.1.0

Initial public release of Codex Usage HUD.

Highlights:

- Windows always-on-top Codex usage HUD.
- Reads Codex quota and usage data from local Codex app-server/session sources.
- Shows 5-hour and 7-day usage windows.
- Shows active thread token/context information where available.
- Saves window position locally.
- Supports Codex autostart watcher.
- Chinese-first user interface and README.

Known limitations:

- Windows-only.
- Not an official OpenAI tool.
- Depends on local Codex internals that may change over time.
