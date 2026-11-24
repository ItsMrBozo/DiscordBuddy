# Security

## What DiscordBuddy Companion does and doesn't do

**It does:**
- Read files in your World of Warcraft folder: the `Screenshots` folders, and `WTF\Account\*\SavedVariables\DiscordBuddy.lua` to get your webhook and message.
- Delete the tagged "marker" screenshots that the addon creates.
- Upload one screenshot per event, and post the weekly recap text, to a `https://discord.com/api/webhooks/...` URL.
- Remember which weekly recaps it already posted, in `%LOCALAPPDATA%\DiscordBuddy\state.json`.
- Write its own log to `%LOCALAPPDATA%\DiscordBuddy`.

**It does not:**
- Connect anywhere except Discord webhook URLs. It checks the URL against a strict pattern before every post.
- Run code from the game folder. Settings are read with plain text matching, not executed.
- Download updates or any other code.
- Read game memory or send input to the game.
- Need administrator rights.
- Write your webhook token to its log.

## Built-in protections

- **Webhook check:** only `discord.com`, `discordapp.com`, `ptb.discord.com` and `canary.discord.com` webhook URLs are accepted, both in game and in the companion.
- **No pings:** every post sets `allowed_mentions` to nothing, and `@everyone` and `@here` are defused. Nobody can be mass-pinged through a character name or message.
- **No formatting tricks in names:** Discord formatting characters in character names are escaped.
- **Rate limits:** one capture per 10 seconds in game, one post per 5 seconds in the companion, and Discord's own rate limits are respected.
- **Privacy:** the default screenshot mode hides chat so whispers and party chat aren't posted. The settings window is hidden during capture so the webhook is never in a screenshot. Marker screenshots are deleted after reading and are never uploaded.
- **One copy at a time:** a second copy of the companion exits straight away, so nothing posts twice.

## Your responsibilities

- Treat the webhook URL like a password. If it leaks, delete the webhook in Discord (Server Settings → Integrations → Webhooks) and create a new one.
- Only download releases from this repository's Releases page or the official CurseForge page.

## Reporting a vulnerability

Please open a private security advisory on this repository (Security → Report a vulnerability) instead of a public issue.
