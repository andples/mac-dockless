# Dockless

A tiny menu-bar app that hides the macOS Dock, with a toggle to bring it back.

- **Hide Dock** (menu or **⌃⌥⌘D** from anywhere) sets the Dock to auto-hide with a ~17 minute reveal delay,
  so it never pops up. Toggle again to restore your original auto-hide and delay settings.
- While hidden, Dock icons don't bounce (launches or apps wanting attention), since a bounce would pop the Dock up.
- **Show Dock When Quitting** (on by default) brings the Dock back when you quit Dockless, so you can't get stuck.
  Logging out, restarting or shutting down leaves it hidden instead.
- The Dock only restarts when a setting actually changes (toggling it, or the first launch), never at an ordinary
  login. Restarting the Dock rebuilds every full-screen space, and doing that while apps are reopening full screen
  can leave the menu bar stuck showing in full-screen apps until the next reboot.
- The shortcut follows your keyboard layout (Colemak, Dvorak, ...).

Manual escape hatch: `defaults delete com.apple.dock autohide-delay; killall Dock`

```sh
./build.sh --install   # universal: Apple silicon + Intel, macOS 14+
```
