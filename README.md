# ed-srv-survey-linux-helper

A helper script and setup guide for running [SrvSurvey](https://github.com/njthomson/SrvSurvey) alongside [Elite Dangerous](https://www.elitedangerous.com/) on Linux via Proton.

---

## What is this?

[SrvSurvey](https://github.com/njthomson/SrvSurvey) is a C# WinForms companion app for Elite Dangerous that provides on-screen overlay assistance for organic scans, ground target tracking, Guardian sites, and more. It reads the game's journal files and renders transparent overlay windows on top of the game.

This repo provides:

- **`install.sh`** — an automated installer / updater that downloads SrvSurvey and ED Mini Launcher, wires them together, and tells you the one remaining manual step.
- **`srvsurvey.sh`** — a launcher script that [ED Mini Launcher](https://github.com/rfvgyhn/min-ed-launcher) will invoke as a companion app inside Elite's Proton session.
- This **README** with step-by-step setup instructions.

---

## Why does this approach work?

SrvSurvey **must** run inside the same Proton/Wine session as Elite Dangerous for its overlays to function. Here's why:

- Wine emulates a virtual Win32 desktop. All processes that share the same Wine server share the same window system.
- When SrvSurvey and Elite run in the same Wine session, SrvSurvey can discover Elite's process via `Process.GetProcessesByName("EliteDangerous64")`.
- Win32 window handles (HWNDs) are valid across processes within the same Wine server, so SrvSurvey can parent its transparent overlay windows directly to Elite's game window — exactly as it does on native Windows.

If SrvSurvey runs in a **separate** Wine instance (e.g., standalone via system Wine), it cannot attach overlays to Elite's window.

[ED Mini Launcher](https://github.com/rfvgyhn/min-ed-launcher) solves this: it replaces the official Frontier launcher and can launch companion apps (like `srvsurvey.sh`) **within the same Proton session** as Elite.

```
Steam launches Elite via Proton
  └─ Proton starts the Wine session
       └─ ED Mini Launcher runs (inside Wine/Proton)
            ├─ Launches Elite Dangerous  (same Wine session)
            └─ Launches srvsurvey.sh    (same Wine session)
                 └─ wine SrvSurvey.exe -linux
                      └─ Overlays parent to Elite's HWND ✅
```

---

## Prerequisites

- A Linux distro (tested on CachyOS/KDE Plasma; should work on Bazzite, other Arch-based, Fedora, Ubuntu, etc.)
- Steam with **Proton Experimental** (or another Proton version ≥ 8; Proton `10.0-3` is worth trying if Experimental is unreliable)
- Elite Dangerous installed via Steam and **run at least once** (to create the Proton prefix)
- `curl`, `unzip`, and `python3` available on the system
- `protontricks` recommended so the installer can provision `.NET Desktop Runtime 9` into Elite's Proton prefix automatically

---

## Quick start (automated installer)

`install.sh` handles everything except the one Steam UI step that cannot be automated:

```bash
# Clone the repo and run the installer
git clone https://github.com/mfairchild365/ed-srv-survey-linux-helper.git
cd ed-srv-survey-linux-helper
./install.sh
```

The script will:

1. Download the latest [SrvSurvey](https://github.com/njthomson/SrvSurvey/releases) release and extract it.
2. Download the latest [ED Mini Launcher](https://github.com/rfvgyhn/min-ed-launcher/releases) Linux binary.
3. Place `srvsurvey.sh` next to `SrvSurvey.exe`.
4. Create / update `~/.config/min-ed-launcher/settings.json` with a `processes` entry for `srvsurvey.sh`.
5. Best-effort install `.NET Desktop Runtime 9` into Elite's Proton prefix via `protontricks` when it is available.
6. Print the one remaining manual step: setting the Steam launch option with `min-ed-launcher`'s recommended Linux arguments.

Everything is installed under `~/.local/share/ed-srv-survey-helper/` by default. Pass `--install-dir /your/path` to choose a different location.

For automated runs (for example in CI or local tests), set `INSTALL_SH_NO_WAIT=1` to skip the final "Press Enter to close..." prompt.

### Updating

Run `./install.sh` again at any time. Versions that are already current are skipped; only newer releases are downloaded.

If `protontricks` is installed and Elite's prefix already exists, the installer also checks for `.NET Desktop Runtime 9` and requests `dotnetdesktop9` automatically when it is missing.

## Testing

Run the installer tests with:

```bash
bash tests/test_install.sh
bash tests/test_srvsurvey.sh
```

The test harnesses mock network downloads, extraction, Wine binaries, Proton paths, and sleep timing so they can run safely on Linux or macOS without touching your real Steam or config directories.

Continuous integration runs `shellcheck` plus both test suites on GitHub Actions for Ubuntu and macOS.

## Collecting Logs

To gather the most relevant troubleshooting details into one report, run:

```bash
bash collect-logs.sh --output /tmp/ed-srv-survey-report.txt
```

The helper collects:

- `~/.config/min-ed-launcher/settings.json` (and legacy `settings.toml` if present)
- `~/.local/state/min-ed-launcher/min-ed-launcher.log`
- `~/.local/state/ed-srv-survey-helper/srvsurvey.log`
- fallback helper logs under `${TMPDIR:-/tmp}`
- installed helper file paths and key environment variables (`LD_PRELOAD`, `LD_LIBRARY_PATH`, `STEAM_COMPAT_DATA_PATH`, `WINEPREFIX`, etc.)

Use `--install-dir /custom/path` if you installed outside the default location.

### One manual step

After running the installer, open Steam, right-click **Elite Dangerous → Properties → General**, and set the **Launch Options** to the command printed by the installer, for example:

```
gnome-terminal -- /home/youruser/.local/share/ed-srv-survey-helper/min-ed-launcher/min-ed-launcher %command% /autorun /autoquit
```

Replace `/home/youruser` with your actual home directory path (or copy the exact command the installer prints). Using `~` directly in Steam's launch options field may not expand correctly in all Steam client versions.

---

## Step-by-step installation (manual)

### 1. Install and run Elite Dangerous at least once

Open Steam, select Elite Dangerous → Properties → Compatibility, enable **Proton Experimental**, and launch the game once. You can exit immediately. This creates the Proton prefix that SrvSurvey will use.

### 2. Install ED Mini Launcher

Follow the [ED Mini Launcher installation instructions](https://github.com/rfvgyhn/min-ed-launcher#installation). The recommended approach is to download the latest release binary and place it where Steam will invoke it instead of the official launcher.

Verify it works by launching Elite through Steam — you should see ED Mini Launcher's output in the terminal/log.

### 3. Download and extract SrvSurvey

1. Go to [SrvSurvey releases](https://github.com/njthomson/SrvSurvey/releases) and download the latest `.zip` file (e.g., `SrvSurvey.zip`).
2. Extract it to a location you'll remember, for example:

   ```bash
   mkdir -p ~/Games/SrvSurvey
   unzip ~/Downloads/SrvSurvey.zip -d ~/Games/SrvSurvey
   ```

### 4. Download this repo and place `srvsurvey.sh`

Clone or download this repo:

```bash
git clone https://github.com/mfairchild365/ed-srv-survey-linux-helper.git ~/Games/ed-srv-survey-linux-helper
```

The script can live anywhere. Two convenient locations:

- **Next to SrvSurvey.exe** (uses default path detection):

  ```bash
  cp ~/Games/ed-srv-survey-linux-helper/srvsurvey.sh ~/Games/SrvSurvey/srvsurvey.sh
  ```

- **Anywhere else** (pass the SrvSurvey directory as an argument in the ED Mini Launcher config).

### 5. Make the script executable

```bash
chmod +x ~/Games/SrvSurvey/srvsurvey.sh
# or wherever you placed it:
chmod +x ~/Games/ed-srv-survey-linux-helper/srvsurvey.sh
```

### 6. Configure ED Mini Launcher

ED Mini Launcher is configured via a JSON file. Its default location is:

```
~/.config/min-ed-launcher/settings.json
```

Add a `processes` entry pointing to `srvsurvey.sh`. The installer writes this automatically; if you need to do it manually, add `srvsurvey.sh` as an extra process like this:

```json
{
  "processes": [
    {
      "fileName": "/home/youruser/Games/SrvSurvey/srvsurvey.sh"
    }
  ]
}
```

> **Note:** `min-ed-launcher`'s settings file is `settings.json`, not `settings.toml`. Refer to the [ED Mini Launcher documentation](https://github.com/rfvgyhn/min-ed-launcher#configuration) for the authoritative reference. The key point is to add `srvsurvey.sh` as a process that the launcher starts alongside Elite.

### 7. Launch Elite Dangerous through Steam

Start Elite normally through Steam using a launch option such as one of these:

```bash
gnome-terminal -- /path/to/min-ed-launcher %command% /autorun /autoquit
alacritty -e /path/to/min-ed-launcher %command% /autorun /autoquit
LD_LIBRARY_PATH="" konsole -e env MEL_LD_LIBRARY_PATH="$LD_LIBRARY_PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" /path/to/min-ed-launcher %command% /autorun /autoquit
LD_LIBRARY_PATH="" ptyxis -- env MEL_LD_LIBRARY_PATH="$LD_LIBRARY_PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" /path/to/min-ed-launcher %command% /autorun /autoquit
```

ED Mini Launcher will then:

1. Launch Elite Dangerous.
2. After the configured delay (`SRVSURVEY_DELAY`, default 15 seconds), launch SrvSurvey inside the same Proton session.

SrvSurvey will appear over Elite once it has finished loading.

The installer marks the SrvSurvey helper process with `keepOpen: true` so it is not terminated when `min-ed-launcher` exits via `/autoquit` after the game starts.

If SrvSurvey still fails to start, ensure `.NET Desktop Runtime 9` is installed in the `359320` prefix. The installer attempts this automatically via `protontricks`; manually, the equivalent command is:

```bash
protontricks 359320 dotnetdesktop9
```

---

## Configuration

| Variable / Parameter | Default | Description |
|---|---|---|
| `SRVSURVEY_DELAY` (env var) | `15` | Seconds to wait before launching SrvSurvey. Increase if Elite fails to start. Set to `0` to disable. |
| First argument to script | auto-detect | Path to the SrvSurvey installation directory. By default the script first checks for `SrvSurvey.exe` next to itself, then falls back to `<script dir>/SrvSurvey`. |

### Setting `SRVSURVEY_DELAY`

You can export the variable in your shell profile, or set it in ED Mini Launcher's environment configuration:

```bash
export SRVSURVEY_DELAY=20
```

Or modify the default directly in `srvsurvey.sh` (the line `DELAY="${SRVSURVEY_DELAY:-15}"`).

---

## How it works (technical)

### Proton session sharing

When Steam launches a game with Proton, it starts a Wine server (`wineserver`) for that game's Proton prefix. ED Mini Launcher runs inside that same Wine server, and so do any companion apps it spawns. This means SrvSurvey runs in the **same virtual Win32 environment** as Elite — they share:

- The virtual Win32 desktop (managed by Wine's `user32.dll`)
- The process table (SrvSurvey can enumerate Elite's process)
- The window handle (HWND) namespace (overlay windows can be parented to Elite's HWND)

### Why the sleep delay is necessary

Proton/Wine initialises resources as processes start. If SrvSurvey starts before Elite has completed its own initialisation, the competition for Wine resources (especially the D3D renderer) can cause Elite's launch to fail. The delay gives Elite time to get past its splash/intro sequence before SrvSurvey starts.

### SrvSurvey Linux detection

SrvSurvey automatically detects that it is running under Wine/Linux by checking whether the `WINELOADER` environment variable is set (which Proton always sets). The `-linux` flag passed by this script is an explicit fallback that forces the same code path, guarding against edge cases. When `isLinux` is `true`, SrvSurvey activates Linux-specific behaviours such as opening links with `xdg-open` and skipping auto-update.

---

## Known issues / caveats

| Issue | Notes |
|---|---|
| **SrvSurvey starts before Elite → Elite fails to launch** | Mitigated by the sleep delay. Increase `SRVSURVEY_DELAY` if needed. |
| **SrvSurvey pops up during Elite's intro videos** | This is expected — the delay is not long enough to wait for the main menu. Clicking on the Elite window skips the intro videos and restores focus. |
| **Exiting the game** | ED Mini Launcher may not detect that Elite has closed. Use **Ctrl+C** in the launcher's terminal and **Quit** inside SrvSurvey to exit cleanly. |
| **Emoji rendering is broken** | A known Wine/font limitation. Emoji in SrvSurvey's UI will appear as boxes or missing glyphs. |
| **Bazzite / Steam runtime `LD_PRELOAD` warnings** | `srvsurvey.sh` now clears `LD_PRELOAD` and restores host libraries from `MEL_LD_LIBRARY_PATH` before launching Wine, which avoids common `libextest.so` wrong-ELF-class warnings. |
| **Gamescope (Bazzite Game Mode / SteamOS)** | Gamescope does not composite external windows on top of the focused game. Overlays will only work in **Desktop Mode**, not Game Mode. Running Elite in a window outside Gamescope is the workaround. |
| **Other Proton versions** | The script tries to auto-detect the Proton Wine binary. If you use a version not covered by the auto-detection logic, set `WINELOADER` manually or edit the script. Alternatively, use [Proton-Shim](https://gitlab.com/Wisher/ProtonShim) to generate a compatible wrapper. |

---

## Troubleshooting

### SrvSurvey can't find journal files

- Ensure Elite Dangerous has been run **at least once** via Steam with Proton. This creates the Proton prefix and the `Saved Games` directory inside it.
- The journal path inside the Proton prefix is: `~/.local/share/Steam/steamapps/compatdata/359320/pfx/drive_c/users/steamuser/Saved Games/Frontier Developments/Elite Dangerous/`
- In SrvSurvey's settings, verify the journal folder points to the path above (or the equivalent inside your Steam library path).

### Overlays don't appear on top of Elite

- Confirm both Elite and SrvSurvey are running in the same Proton session (launched via ED Mini Launcher).
- In SrvSurvey settings, make sure **`disableWindowParentIsGame`** is **not** enabled (it should be `false` for same-session operation).
- If running in Gamescope (Bazzite Game Mode), switch to Desktop Mode.

### SrvSurvey doesn't open at all

- Check the helper log at `~/.local/state/ed-srv-survey-helper/srvsurvey.log`.
- If `HOME` or `XDG_STATE_HOME` is unavailable in the Steam-launched environment, the helper falls back to `${TMPDIR:-/tmp}/ed-srv-survey-helper/srvsurvey.log`.
- Check `min-ed-launcher`'s log at `~/.local/state/min-ed-launcher/min-ed-launcher.log`.
- On Bazzite/KDE/Ptyxis/Konsole, prefer the launch option variants above that reset Steam's runtime `LD_LIBRARY_PATH` and pass `MEL_LD_LIBRARY_PATH` into the terminal session.
- If you see `libextest.so` wrong-ELF-class warnings, rerun `./install.sh` so it prints the updated launch command and rewrites the helper process entry with `keepOpen: true`.
- `srvsurvey.sh` now exports `WINEPREFIX` from `STEAM_COMPAT_DATA_PATH/pfx` when available so SrvSurvey launches against Elite's Proton prefix instead of a default Wine prefix.

### Elite doesn't launch / crashes on startup

- Increase the sleep delay: set `SRVSURVEY_DELAY=30` (or higher) in your environment or ED Mini Launcher config.

### Script can't find the Wine/Proton binary

- Check that ED Mini Launcher is setting `WINELOADER`. You can add a debug line to the script: `echo "WINELOADER=${WINELOADER:-unset}" >&2`
- Alternatively, set `WINELOADER` manually to the full path of your Proton `wine64` binary before launching Steam/ED Mini Launcher.

### `Permission denied` when running the script

```bash
chmod +x /path/to/srvsurvey.sh
```

---

## Credits

- [**njthomson**](https://github.com/njthomson) — creator of [SrvSurvey](https://github.com/njthomson/SrvSurvey)
- [**Maldor**](https://github.com/njthomson/SrvSurvey/discussions/524) — original Linux setup documented in SrvSurvey discussion #524, which this is based on
- [**rfvgyhn**](https://github.com/rfvgyhn/min-ed-launcher) — creator of [ED Mini Launcher](https://github.com/rfvgyhn/min-ed-launcher)
- [**Wisher**](https://gitlab.com/Wisher/ProtonShim) — [Proton-Shim](https://gitlab.com/Wisher/ProtonShim), inspiration for the script generation approach

---

## License

GPL-3.0 — see [LICENSE](LICENSE).
