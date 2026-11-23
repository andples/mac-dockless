# Dockless

A tiny menu-bar app that hides the macOS Dock, with a toggle to bring it back.

- **Hide Dock** (menu or **⌃⌥⌘D** from anywhere) sets the Dock to auto-hide with a ~17 minute reveal delay,
  so it never pops up. Toggle again to restore your original auto-hide and delay settings.
- While hidden, Dock icons don't bounce (launches or apps wanting attention), since a bounce would pop the Dock up.
- **Show Dock When Quitting** (on by default) brings the Dock back when you quit Dockless, so you can't get stuck.
  Logging out, restarting or shutting down leaves it hidden instead.
- The Dock only restarts when a setting actually changes (toggling it, or the first launch), never at an ordinary
  login, so there's no needless flicker.
- The shortcut follows your keyboard layout (Colemak, Dvorak, ...).

Manual escape hatch: `defaults delete com.apple.dock autohide-delay; killall Dock`

## Menu bar stuck in full-screen apps? Not Dockless

Full-screen apps sometimes keep the menu bar (and the window's title bar) showing at the top, until a
reboot or a click on another display. This was blamed on Dockless twice; it isn't. Tested on 23 Nov 2026
(macOS 27) while it was happening, using the full-screen window's size to tell (`0,33 1512x949` stuck,
`0,0 1512x982` fine):

| Tried | Stuck? |
|---|---|
| Normal Dock settings (no delay, bouncing and launch animation back) and a Dock restart | still stuck |
| Quit Dockless completely | still stuck |
| Quit Hidden Bar; restart Control Center and SystemUIServer | still stuck |
| `killall MenuBarAgent`, then leave and re-enter full screen | **fixed** |

The cause is macOS's own **MenuBarAgent**. Plugging a display in or out makes WindowServer wait for every
app to acknowledge the change, and MenuBarAgent repeatedly fails to answer in time. Every display change
in the logs shows it:

```
Display reconfiguration sync timeout (wait_id=29) - 1 of 1 client(s) failed to respond within 250ms
  - Connection 373139 (PID 630, com.apple.menubaragent) did not respond
```

After that it keeps the menu bar marked as visible in full-screen spaces. Clicking another display
works because it makes the menu bar move display; a reboot works because it starts a new MenuBarAgent.
Why it sometimes seemed to clear when Dockless quit: switching spaces mid-animation briefly shows the
right size (the stuck state comes back once the switch settles).

**Fix without a reboot:** `killall MenuBarAgent` (macOS relaunches it at once), then take the app out of
full screen and back in. To check after a display change:
`log show --last 1h --predicate 'eventMessage CONTAINS "did not respond"'`

## Install

```sh
./build.sh --install   # universal: Apple silicon + Intel, macOS 14+
```
