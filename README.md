# DiscordBuddy + DiscordBuddy Companion

Post your World of Warcraft milestones, with a screenshot, to a Discord channel, plus a weekly recap after each weekly reset.

```
Buddy  [APP]
**Aldric Stonefield** just hit **level 14**! 🎉
[screenshot]
```

Works with WoW: Forever, Classic Era / Season of Discovery / Hardcore, TBC Anniversary and MoP Classic. Windows only.

## What it posts

| Event | Default | Example |
|---|---|---|
| Level up / max level | on | **Aldric Stonefield** just hit **level 14**! |
| Profession milestone (75/150/225/300...) | on | **Aldric Stonefield** reached **Herbalism 150**! |
| Legacy challenge / achievement | on | **Aldric Stonefield** earned **Explorer of Tirisfal**! |
| PvP rank / honor level | on | **Aldric Stonefield** reached **honor level 5**! |
| Reputation tier (Honored+) | off | **Aldric Stonefield** is now **Exalted with Darnassus**! |
| Epic+ loot | off | **Aldric Stonefield** looted **Blade of Ruin**! |
| Rare kill | off | **Aldric Stonefield** slew the rare **Snarlmane**! |
| First boss kill | off | **Aldric Stonefield** defeated **Mutanus** for the first time! |
| Gold milestone | off | **Aldric Stonefield** now has **100 gold**! |
| Death | off | **Aldric Stonefield** died at level 22 in Duskwood. |
| New title | off | **Aldric Stonefield** earned the title **Private**! |

**Weekly recap** (on by default) is posted after your region's weekly reset (Tuesday in the Americas). It shows each character you played: levels gained, kills (and rares), deaths, time played, nodes and herbs gathered, gold gained, most valuable and rarest loot, profession progress, reputation tiers, Legacy challenges, biggest fight (from the built-in damage meter), and a PvP line with honorable kills, Honor and rank progress.

Every message can be edited in `/buddy`.

## How it works

WoW addons can't connect to the internet, so this comes in two parts:

| Part | Where it runs | What it does |
|---|---|---|
| **DiscordBuddy** (addon) | Inside WoW | Settings window (`/buddy`). When something happens it takes a tagged screenshot that encodes the finished message, then a clean one. It also keeps weekly stats. |
| **DiscordBuddy Companion** (this repo) | On your PC, in the background | Watches your Screenshots folder, reads the tag, deletes the tagged shot and posts the clean one to your Discord webhook. |

Screenshots you take yourself are never posted. Only the ones the addon tags. The weekly recap is read from the addon's saved settings file, which WoW writes when you log out or `/reload`.

## Setup

1. **Install the addon** from CurseForge (or copy the `DiscordBuddy` folder into `World of Warcraft\<version>\Interface\AddOns`).
2. **Install DiscordBuddy Companion:** download the latest release zip from the Releases page, unzip it, and double-click **`Install.cmd`**. No admin rights or extra software needed: it uses the PowerShell that comes with Windows. It starts now and every time you sign in to Windows.
3. **Create a Discord webhook:** in Discord, open Server Settings → Integrations → Webhooks → New Webhook. Pick a channel, then click **Copy Webhook URL**.
4. **Connect it in game:** type `/buddy`, paste the URL (Ctrl+V), click **Set**, then **Save & Reload**.
5. Click **Send test post**. A `[test]` post should show up in your channel within a few seconds.

## Settings (`/buddy`)

- **Post to Discord:** master on/off switch. **Weekly recap:** on/off.
- **Post when...:** choose events.
- **Message for:** click to choose an event, then edit its message. `{name}`, `{level}`, `{detail}` and `{zone}` are filled in. Discord formatting such as `**bold**` works. **Default** restores the original.
- **Screenshot:** *chat hidden* (default, keeps whispers and party chat out of the post), *everything*, or *text only*.

Other commands: `/buddy test`, `/buddy recap` (preview this week's recap in chat), `/buddy on`, `/buddy off`, `/buddy name` (shows the name that will be posted).

## Troubleshooting

The log is at `%LOCALAPPDATA%\DiscordBuddy\companion.log`. Paste that path into File Explorer's address bar to open the folder.

| Log says | Fix |
|---|---|
| *No WoW game folder with DiscordBuddy installed found* | WoW is somewhere unusual. Create `%LOCALAPPDATA%\DiscordBuddy\settings.json` containing `{ "wowPaths": ["D:\\Games\\World of Warcraft"] }`, then sign out and back in, or run `Install.cmd` again. |
| *No valid webhook saved* | In game: `/buddy`, paste the webhook, click **Set**, then **Save & Reload**. |
| *HTTP 401* or *HTTP 404* | The webhook was deleted in Discord. Make a new one and set it again. |
| *screenshots are TGA* | In WoW, type `/console screenshotFormat jpg`. |
| Recap didn't post | Recaps post after the weekly reset once WoW has saved (log out or `/reload` after the reset), or a day after the reset at the latest. Only weeks with activity are posted. |
| Nothing at all | Make sure `Install.cmd` ran. Check that Task Manager shows a Windows PowerShell process. |

## Uninstall

Run **`Uninstall.cmd`** from the release zip. It stops DiscordBuddy Companion and removes its Startup shortcut and folder. Then remove the addon as normal.

## Security and privacy

See [SECURITY.md](SECURITY.md). In short:

- **Your webhook is a password.** Anyone who has it can post to your channel. It's stored in WoW's settings file (`WTF\...\SavedVariables\DiscordBuddy.lua`), so don't share that folder. If it leaks, delete the webhook in Discord and make a new one.
- **Where data goes:** DiscordBuddy Companion only ever connects to `https://discord.com/api/webhooks/...`, and only the screenshots the addon tagged are uploaded.
- **What it runs:** it is a single readable PowerShell script. It doesn't download or run any other code, doesn't read game memory and doesn't need admin rights.

## Support

DiscordBuddy is free, and every feature stays free. If it brings you joy, you can support development on [GitHub Sponsors](https://github.com/sponsors/ItsMrBozo). Thank you!

## License

MIT. See [LICENSE](LICENSE).
