# Connect IQ Store Listing — Sattiv

Draft copy to paste into the developer portal. Adjust freely.

## App name
Sattiv

## Short description (~80 char card summary)
Real-time CGM glucose, trend & history from your own Nightscout, on your watch.

## Full description

Sattiv brings your continuous glucose monitor readings to your wrist, pulled directly from your own self-hosted Nightscout instance — no phone app required once configured.

**Features:**
- Real-time glucose value in mmol/L, color-coded — green (in range), amber (high), red (low)
- Trend arrow showing rate of change (flat, rising, falling, rapid rise/fall)
- Delta vs. 15 minutes ago
- Choice of two layouts: a 60-minute glucose history plot, or a single large glucose readout — switch anytime in Settings
- Time, date, heart rate, step count, and battery — all in one glanceable face
- Stale readings (over 20 minutes old) are flagged in red so a dropped connection doesn't go unnoticed
- Language setting: English, Kazakh (Cyrillic), or Kazakh (Latin)
- Configurable Nightscout URL and API secret via Garmin Connect app Settings — your credentials never leave your device except to reach your own server
- Runs on the fr970 plus a wide range of other Garmin watches of the same screen sizes — fenix 6/7/8 family, Venu, vívoactive, Forerunner, MARQ, Descent, D2, and more (see the full device list in the Connect IQ Store listing)

**Setup:** After installing, open this watch face's Settings in Garmin Connect Mobile and enter your Nightscout URL and API secret. Data refreshes automatically in the background every 5 minutes.

---

**Disclaimer:** Sattiv is an independent, community-built project and is not affiliated with, endorsed by, or sponsored by Garmin, Dexcom, Abbott, or the Nightscout Foundation. It is not a medical device and is not a substitute for your primary CGM receiver or app — always confirm readings on your CGM's official display before making any treatment decision. Displayed data may be delayed or unavailable due to network, server, or sensor issues. Use at your own risk. Full disclaimer and privacy policy: https://bolattleubayev.github.io/garmin-nightscout-integration/privacy-policy.html

## Category
Watch Face

## Privacy Policy URL
https://bolattleubayev.github.io/garmin-nightscout-integration/privacy-policy.html

## Screenshots
Source files in `images/`, `_resized.png` variants sized for the Store's thumbnail requirements. All captured in the Connect IQ simulator with representative (non-real) data.

- `publishing_normal.png` / `publishing_high.png` / `publishing_low.png` — fr970, chart mode, in-range/high/low glucose color states
- `publishing_fr970_chart.png` — fr970, chart mode (60-min history plot)
- `publishing_fr970_valueonly.png` — fr970, value-only mode (large single readout)
- `publishing_venu3.png` — Venu 3, chart mode (same 454×454 screen as fr970)
- `publishing_fenix6.png` — fenix 6, chart mode (260×260 screen, demonstrates the layout scaling down to smaller devices)
