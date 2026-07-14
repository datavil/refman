# Refman Chrome extension

## Development

```sh
npm install
npm test
npm run build
npm run package
```

Then open `chrome://extensions`, enable Developer mode, choose **Load unpacked**,
and select `extension/refman-chrome-extension`. The packaging command always
deletes and recreates this folder from the new ZIP, so Chrome has one stable
folder to reload.

Chrome Web Store submission can use `refman-chrome-extension.zip` directly.

To pair, open Refman → Settings → Chrome Extension, generate a code, and enter
it in the extension popup. Refman must be running when saving a reference.

The extension talks only to Refman at `127.0.0.1:51283`. Website access is
requested only when a direct PDF must be downloaded.
