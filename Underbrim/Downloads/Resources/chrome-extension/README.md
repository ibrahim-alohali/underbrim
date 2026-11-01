# Underbrim: Chrome downloads extension

Minimal Manifest V3 extension that reports Chrome download progress to the
Underbrim app through Chrome native messaging.

- Permissions: `downloads`, `nativeMessaging` only.
- Sends per download: id, state, paused, danger, error, local file path,
  bytes received / total (as Chrome reports them; unknown totals stay unknown).
  Incognito downloads are never sent.
- Never accepts a dangerous download or changes anything in Chrome.
- The `key` in `manifest.json` pins the extension id to
  `fjfblodgeijoighojdggcokapljkjdof`, which the native host manifest allows.
  Only the public key is included; no private key exists for this project.

Install (Settings → Downloads → Chrome in the app does the native-host part):
1. In Chrome open `chrome://extensions` and turn on Developer mode.
2. Click "Load unpacked" and choose this folder (the app copies it to
   `~/Library/Application Support/Underbrim/chrome-extension`).
Since Chrome 134, unpacked extensions only stay enabled while Developer mode is on.
