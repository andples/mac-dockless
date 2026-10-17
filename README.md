# Dockless

A tiny menu-bar app that hides the macOS Dock, with a toggle to bring it back.

- **Hide Dock** (menu or **⌃⌥⌘D** from anywhere) sets the Dock to auto-hide with a ~17 minute reveal delay,
  so it never pops up. Toggle again to restore your original auto-hide and delay settings.
- **Show Dock When Quitting** (on by default) brings the Dock back when Dockless quits, so you can't get stuck.
- The shortcut follows your keyboard layout (Colemak, Dvorak, ...).

Manual escape hatch: `defaults delete com.apple.dock autohide-delay; killall Dock`

```sh
./build.sh --install   # universal: Apple silicon + Intel, macOS 14+
```
