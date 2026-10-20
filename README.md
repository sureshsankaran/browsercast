# BrowserCast — window-only remote control of BrowserOS, from your phone

**Purpose:** keep the Muse chat as the single control window across the
cloud VM and this Mac mini. When web automation in BrowserOS reaches a login
the agent cannot fill, the agent stages the login page and drops a cast link
in chat. Suresh opens it on his phone and gets a **live view of only the
BrowserOS window** — he taps to click and types his password himself. No
credential ever passes through the agent, the chat, or any storage.

## How it works

- A menu-bar app on the Mac captures the BrowserOS window with
  ScreenCaptureKit (single-window capture — the rest of the desktop is never
  in the feed) and serves an MJPEG stream + input relay on the Mac's
  **Tailscale IP, port 9021**.
- The page shows the window image; tapping it sends a click at that point;
  text/password boxes on the page relay keystrokes into the window
  (CGEvent); Tab/Enter/Esc/⌫ buttons included.
- Access requires the random token in the link (`?t=…`). One stream client
  at a time; capture runs only while a client is connected.
- The agent checks state at `GET /status?t=…` (window found? streaming?)
  and never sees the typed content — it only verifies the *result* afterwards
  in BrowserOS itself.

## Security model

- Tailnet-only: the server binds to the Mac's 100.x Tailscale address.
  **Never** expose it via Tailscale Funnel or router port-forwarding.
- The token gates page, stream, input, and status. It authorizes *viewing
  and typing into one browser window* — rotate it by deleting
  `~/Library/Application Support/BrowserCast/token.txt` and restarting the app.
- Typed text travels phone → Mac inside the tailnet (WireGuard-encrypted)
  and is typed immediately; it is never logged or stored.
- macOS permissions, granted once by the owner: **Screen Recording** (to
  capture the window) and **Accessibility** (to type/click).

## Install (on the Mac, ~5 minutes)

1. Get this folder onto the Mac (clone the repo).
2. `bash install.sh` — builds with `swiftc` (Xcode Command Line Tools —
   the script offers to install them if missing), installs
   `~/Applications/BrowserCast.app`, adds a login LaunchAgent. Log:
   `~/Library/Logs/BrowserCast-install.log`.
3. Grant Screen Recording + Accessibility when prompted (System Settings →
   Privacy & Security).
4. Menu bar → **Cast → Copy Token (for Muse)** → paste the token to Muse
   in chat once. The agent stores it with the connector notes and can then
   build the cast link at any time.

## Use (VSP flow)

1. Agent navigates BrowserOS to the login page and focuses the username field.
2. Agent posts the cast link in chat: `http://<mac-tailnet-ip>:9021/?t=<token>`.
3. Suresh opens it, taps the username field in the image, types his username
   in the page's text box → "Type into Mac"; taps the password field, uses the
   masked password box → "Type password"; taps **Log In** in the image.
4. Agent verifies sign-in in BrowserOS, continues the task, reports in chat.

## Files on the Mac

- App: `~/Applications/BrowserCast.app`
- Data: `~/Library/Application Support/BrowserCast/token.txt` (mode 0600)
- Logs: `~/Library/Logs/BrowserCast.log`, `BrowserCast-install.log`

## Known limits (v1)

- Captures the largest on-screen BrowserOS window; restart the stream
  (close/reopen the page) after resizing it.
- No scroll relay yet — pages must fit the window (login pages do).
- ~8 fps JPEG stream: fine for forms, not for video.
- US keyboard layout for relayed typing.

## Removing

```
launchctl unload ~/Library/LaunchAgents/com.muse.browsercast.plist
rm ~/Library/LaunchAgents/com.muse.browsercast.plist
rm -rf ~/Applications/BrowserCast.app "~/Library/Application Support/BrowserCast"
```
