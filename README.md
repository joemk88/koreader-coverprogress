# coverprogress.koplugin

A KOReader plugin that writes the cover of the book you're reading — with a live reading-progress overlay — to a fixed image file, so your device's screensaver can display it.

Open a book, lock the device, and the lock screen shows that book's cover and how far through it you are. As you read, the image updates.

Works on **Android e-readers** (Bigme, Onyx, Tolino and similar), **Kobo**, and the KOReader desktop emulator.


---

## How it works

KOReader ships a built-in plugin, `coverimage`, that writes the current book's cover to a file on book open. Most e-ink devices can point their screensaver at a fixed image path. This plugin extends that idea:

- composites a **reading-progress overlay** onto the cover before writing
- **refreshes as you read**, not only when a book is opened
- offers **four layouts** suited to different screen shapes
- picks a **light or dark background per book** by analysing the cover
- writes **atomically** and verifies the file before publishing it

Derived from KOReader's `coverimage` plugin.

---

## Installation

Download this repository (**Code → Download ZIP**), extract it, and confirm the folder is named exactly `coverprogress.koplugin`. Copy it into KOReader's `plugins/` directory:

| Platform | Path |
| --- | --- |
| Android | `/storage/emulated/0/koreader/plugins/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
| Kindle | `/mnt/us/koreader/plugins/` |
| Desktop emulator | `koreader/plugins/` in your build |

Restart KOReader.

> **Disable the built-in `coverimage` plugin first.** Go to **Tools → More tools → Plugin management** and untick `coverimage`. Both plugins write to the same default path, and leaving both enabled causes them to race — which can produce a truncated image file that renders with a grey band across the bottom.

Then **open a book** — the settings menu is document-only and does not appear in the file browser — and go to:

**Menu (gear icon) → Screen → Cover screensaver (progress) → Enabled**

The image is written immediately. By default it goes to:

- Android: `/storage/emulated/0/cover.jpg`
- Everything else: `<KOReader settings dir>/cover.jpg` (on Kobo, `/mnt/onboard/.adds/koreader/cover.jpg`)

---

## Device setup

### Bigme (HiBreak, HiBreak Pro, B-series tablets)

Tested on a HiBreak Pro BW; the process is the same across Bigme's Android devices.

1. In KOReader, enable the plugin as above and confirm `/storage/emulated/0/cover.jpg` now exists
2. Open the **ScreenSaver** app
3. Select **Picture mode**
4. **Select image → Single Image mode**
5. **Add image → tap Camera Roll** at the top
6. Choose the album named **"unknown"** — that's `cover.jpg` sitting in the root of internal storage, which appears unnamed because it isn't inside a named folder like Pictures or Downloads
7. Select it

Lock the device to check. Open a different book and lock again — the cover should follow.

If you'd rather the file lived somewhere tidier, set `coverprogress_path` (see [Settings keys](#settings-keys)) to something like `/storage/emulated/0/Pictures/Wallpaper/cover.jpg`. The folder must already exist, and it will then show up as a properly named album in the ScreenSaver app.

**On Bigme tablets** (B6, B7 and similar) choose the **Bar below cover** mode rather than the default. Tablet screens are wide enough that a portrait cover reaches the bottom edge, so the default layout would put the bar on top of the artwork. See [Modes](#modes).

### Kobo

1. Copy the plugin to `/mnt/onboard/.adds/koreader/plugins/` and restart KOReader
2. Open a book and enable the plugin — the image is written to `/mnt/onboard/.adds/koreader/cover.jpg`
3. Go to **Menu → Sleep Screen → Wallpaper → Show custom image** and point it at that file
4. In the same **Sleep Screen** settings, turn off the **sleep screen message** — otherwise KOReader prints its own text over the image

Kobo screens are around 0.75 aspect ratio, so **Bar below cover** is usually the better choice here too.

### Other Android e-readers

Onyx, Tolino and others expose a file-based screensaver setting somewhere in their system settings. Point it at the output path. Tolino devices conventionally read `/sdcard/suspend_others.jpg`, so setting `coverprogress_path` to that may work without touching any system setting.

---

## Modes

Choose under **Screen → Cover screensaver (progress)**. Which one suits you depends on your screen's aspect ratio relative to a typical 2:3 book cover.

### Bar in the margin *(default)*

The cover stays centred at full size and the bar sits in the empty band below it.

Best on **tall screens** — e-ink phones like the HiBreak Pro (0.50 aspect) — where a portrait cover is limited by width and physically cannot reach the bottom edge. Nothing is ever drawn over artwork, and the cover isn't shifted or shrunk.

This mode also supports two extras that use the space a tall screen leaves free — **header text** above the cover and a **page number** above the bar. See [Header text and page number](#header-text-and-page-number). They are only available in this mode, because the other layouts are full-bleed or already carry text and have nowhere to put them.

### Bar below cover

The cover is shrunk slightly and raised to make room for the bar underneath.

Use on **wider screens** — tablets and most Kobos, around 0.75 aspect — where a cover is limited by height and runs to the bottom edge. Space for the band is reserved *before* the cover is scaled, so the bar can never land on artwork regardless of screen shape. The trade-off is that the cover sits a few percent higher than dead centre.

### Bar over cover

Full-bleed cover with a compact bar and percentage drawn on top, anchored bottom-right.

Two things make this readable. It searches upward for a strip free of lettering, comparing the standard deviation of luminance across candidate positions — deviation detects type and detail regardless of whether the area is light or dark. And it samples that final position once to choose a single colour for both the bar and the percentage, so you never get a white bar beside a black number.

### Kobo style box

Full-bleed cover with a small bordered card showing percentage read and estimated time remaining, modelled on Kobo's own sleep screen. No progress bar.

The time estimate requires KOReader's **statistics** plugin to be enabled, and needs some reading history for the book before it means anything — see [Time remaining](#time-remaining).

---

## Header text and page number

Two optional additions available in **Bar in the margin** mode only. In the other modes their menu entries are greyed out — the cover is full-bleed (overlay), raised to the top edge (below), or already shows a text card (Kobo), so there is no free space for them and forcing text in would put it over the artwork.

### Header text

Two lines of your own text, centred in the letterbox above the cover, set in KOReader's built-in monospace font. Edit them under **Screen → Cover screensaver → Header text → Line 1 / Line 2**. Line 1 is the larger of the two, intended as a heading with Line 2 as a subheading beneath it; leaving a line empty hides it. Common uses are a name, a "if found, contact…" line, or a favourite quote.

Because the screensaver image is only regenerated while you are actively reading, header text is a good fit — it is static, so it never goes stale between sessions. (For the same reason the plugin deliberately avoids anything that must be current, such as the date or clock time, which would freeze at whenever you last turned a page.)

### Page number

Toggle **Show page number** to print "page X of Y" above the progress bar. The count is KOReader's page count for the open document, so on a reflowable EPUB it reflects your current font size rather than the print edition.

**This changes how often the image is written.** Normally the plugin only rewrites the file when the whole displayed percentage changes — turning several pages within the same percent produces no write. But a page number changes far more often than the percentage: on a device that shows many small "pages" per real page, the percentage might only tick over every fifteen or twenty page turns. So when the page number is shown, the plugin must rewrite on **every page turn** to keep it accurate, which is what the menu warns about.

The trade-off, in short:

| Show page number | Image rewrites | Displayed detail |
| --- | --- | --- |
| Off *(default)* | Only when the whole percentage changes — much less often | Percentage and bar |
| On | On every page turn | Percentage, bar, and live page number |

If you would rather minimise writes — for battery, or just to keep things quiet — leave it off. If a live page count matters more to you than write frequency, turn it on. You cannot have both a live page number and percentage-only writes, since the page number is the thing changing between percentage steps.

## Background

Sets the letterbox fill behind the cover and the progress band. Bar, border and text always take the opposite colour.

- **White background, black text**
- **Black background, white text**
- **Auto** *(default)* — decided per book from the cover itself

### How Auto decides

It counts what fraction of the cover's pixels fall below a luminance threshold, and goes dark if that fraction exceeds a percentage you can set.

Counting dark pixels works better than averaging them, because covers are frequently bimodal — pale stock with heavy black artwork averages out to a misleading mid-grey. Measured across five real covers, mean luminance called them all light; the dark-fraction test separated them correctly.

The menu shows the measurement for the open book, e.g. *"Auto background (now: white, cover 25% dark)"*, so you can read the actual figure before deciding where to put the threshold. **Auto: go black above N% dark** adjusts it between 10 and 90.

If a cover is being classified wrongly, read its percentage from the menu and set the threshold either side of it.

---

## Menu reference

| Entry | Purpose |
| --- | --- |
| Enabled | Turns image writing on or off |
| Bar in the margin | Layout for tall screens *(default)* |
| Bar below cover | Layout for wider screens |
| Bar over cover | Compact overlay on a full-bleed cover |
| Kobo style box | Information card, no bar |
| Header text (Line 1 / Line 2) | Two custom lines above the cover; margin mode only |
| Show page number | "page X of Y" above the bar; margin mode only. Forces a write per page turn |
| White / Black / Auto background | Colour scheme; Auto shows its measurement |
| Auto: go black above N% dark | Auto sensitivity, 10–90% |
| Output: *path* | Shows the current output path |
| Update delay: N s | Quiet period after the last page turn before rewriting, 0–60s |
| Update now | Forces an immediate rebuild and write |

---

## Settings keys

Stored in `settings.reader.lua` in your KOReader settings directory. Fully exit KOReader before editing by hand, or your changes will be overwritten on the next autosave.

| Key | Default | Notes |
| --- | --- | --- |
| `coverprogress_enabled` | *(unset)* | Set by the menu toggle |
| `coverprogress_path` | platform-dependent | Output file; folder must already exist |
| `coverprogress_mode` | `"margin"` | `margin`, `below`, `overlay`, `kobo` |
| `coverprogress_background` | `"auto"` | `white`, `black`, `auto` |
| `coverprogress_auto_ratio` | `50` | Auto threshold, percent |
| `coverprogress_debounce` | `5` | Seconds |
| `coverprogress_header1` | `""` | Header line 1 (margin mode) |
| `coverprogress_header2` | `""` | Header line 2 (margin mode) |
| `coverprogress_show_page` | *(unset)* | Show page number; forces per-page writes |

The output format is taken from the file extension — `.jpg`, `.png` or `.bmp`. PNG is worth trying if your covers are hard-edged graphic art, which JPEG handles poorly. Some devices insist on a particular format; PocketBook's screensaver, for instance, wants BMP.

---

## Tunables

Constants at the top of `main.lua`, for anything not exposed in the menu.

| Constant | Default | Purpose |
| --- | --- | --- |
| `TARGET_W` / `TARGET_H` | `0` | Output size; `0` uses the screen. Set explicitly if output looks upscaled, or to preview another device's geometry (Bigme B7 is 1264×1680) |
| `DEBOUNCE_SECONDS` | `5` | Default update delay |
| `JPEG_QUALITY` | `95` | JPEG only |
| `GRAYSCALE` | `true` | Requests greyscale output |
| `FIT_TO_COVER` | `true` | Aligns overlays to the cover rather than the screen when the cover is pillarboxed |
| `BAND_HEIGHT_PCT` | `8` | Band height, % of output height |
| `BAND_RULE` | `false` | Hairline above the band |
| `BAR_THICKNESS` | `10` | Bar height |
| `PCT_FONT_SIZE` | `20` | Percentage text size |
| `OVERLAY_BAR_W_PCT` | `42` | Overlay block width, % of cover width |
| `OVERLAY_FIND_QUIET` | `true` | Search for a strip free of lettering |
| `OVERLAY_SEARCH_PCT` | `22` | How far up to search, % of cover height |
| `OVERLAY_LOW_BIAS` | `0.03` | Preference for staying near the bottom |
| `AUTO_BG_LUMA` | `110` | Darkness threshold for the Auto decision |
| `AUTO_BG_DARK_RATIO` | `50` | Default Auto percentage |
| `KOBO_HEADER` | `"Sleeping"` | Card heading |
| `KOBO_BOX_Y_PCT` | `58` | Card position, % of height |
| `KOBO_SERIF` | Noto Serif path | Falls back to the default sans if absent |

**Don't raise `AUTO_BG_LUMA` much past 130.** Pale cover stock commonly sits around luminance 140, so a threshold there flips plainly light covers to dark. Measured on two such covers, the dark fraction jumped from around 2% and 14% at a threshold of 110 to roughly 65% at 140. The 110–130 range is the safe band.

---

## Time remaining

The Kobo style box shows an estimate drawn from KOReader's statistics plugin.

It is a running mean of seconds per page for the current book — `book_read_time / book_read_pages` — so it improves the more you read. Before any data exists it is seeded at half your configured `max_sec`, meaning a freshly opened book reports a plausible-looking figure that is pure convention. Individual page durations are capped at `max_sec` when recorded, so leaving a book open on your desk doesn't poison the average.

Because it's an unweighted mean, it's slow to react if your pace changes mid-book. And on reflowable formats, changing the font size changes what a page is, so expect the estimate to be off for a while afterwards.

If the line doesn't appear at all, check that the statistics plugin is enabled in **Plugin management**.

---

## Troubleshooting

**No menu entry.** The settings are document-only. Open a book first; the entry does not exist in the file browser. Also confirm the plugin is ticked in **Tools → More tools → Plugin management** — that checkbox controls whether the plugin *loads*, which is separate from the Enabled toggle in the Screen menu.

**The entry is under Settings, not Screen (or shows a "NEW:" prefix in the first menu).** Your menu is missing the reader **Screen** section. That happens on some stripped or older builds, and with menu-customising plugins such as **Simple UI** or **Menu Customizer**, which write a persistent menu-order override — so disabling those plugins afterwards does not restore the section. The plugin detects this and places its entry under **Settings** instead, falling back to the first menu if that is gone too. Everything works the same; only the location differs.

**KOReader crashes the instant you open the reader top menu.** This was a KOReader core bug: `MenuSorter` did not guard a `sorting_hint` whose target section was missing, so on a menu lacking the **Screen** section it dereferenced a nil during menu assembly and took the whole app down. Because the crash was in core — after this plugin had already handed its menu over — it produced no `crash.log`. Fixed from **v1.05**: the plugin validates its placement against your actual menu order and never hands core an unresolvable hint. If you are on an older build of this plugin and see this, update.

**Plugin ticked in Plugin management but no Screen menu entry.** That combination means the plugin was found but failed to load, since the Plugin management list is built from `_meta.lua` alone. On Android, get the reason from logcat:

```
adb logcat -c
```

Restart KOReader, open a book, then:

```
adb shell "logcat -d | grep -i -e coverprogress -e plugin -e lua"
```

A load failure appears as a `.lua:NN:` line naming the file and line number. Note that Android builds do not write `crash.log` — that's a Kobo and desktop thing, so its absence means nothing. Separately, if this plugin ever catches an internal error while building or driving its menu, it writes a traceback to `coverprogress_crash.log` in the KOReader data directory (e.g. `/sdcard/koreader/`) and keeps the reader running rather than crashing it — so that file, if present, is the first place to look.

**Windows note:** put quotes around the remote command so `grep` and `tail` run on the device rather than on Windows. In PowerShell, call `adb.exe` explicitly — a bare `adb` can resolve to an extensionless file in `system32` and fail with *"Cannot run a document in the middle of a pipeline"*.

**Nothing written after a re-push.** `adb push coverprogress.koplugin /path/plugins/` copies *into* the destination if it already exists, giving you `plugins/coverprogress.koplugin/coverprogress.koplugin/`. Check with `ls`, and push as `adb push coverprogress.koplugin/. /path/plugins/coverprogress.koplugin/` instead.

**Grey band across the bottom of the image.** That's a truncated JPEG missing its end-of-image marker — decoders fill the undecodable rows with grey. Usually caused by two plugins writing the same path, so make sure the built-in `coverimage` is disabled. The plugin verifies the marker before publishing and discards bad writes, so the previous good image survives.

**Bar sits on the cover artwork.** You're using a margin or overlay layout on a screen too wide for it. Switch to **Bar below cover**.

**Wrong background colour.** Read the cover's dark percentage from the Auto background menu entry and move the threshold either side of it.

**Cover looks soft or upscaled.** Your screensaver app is rescaling because `Screen:getHeight()` returned the app window rather than the panel. Set `TARGET_W` and `TARGET_H` to the panel's true resolution.

---

## Notes

- The image is rewritten after a quiet period following the last page turn (5s by default), and immediately on book open, settings flush, suspend and close. A full-page encode on every page turn would be wasteful.
- Rendering *and menu* errors are contained and logged rather than propagating — a screensaver plugin should never be able to break the reader. Caught errors are written to `coverprogress_crash.log` in the KOReader data directory with a full traceback.
- Menu placement adapts to your actual menu order: it prefers the **Screen** section, falls back to **Settings**, then to a safe orphan, so a menu missing sections (stripped builds, or menu-customising plugins) can never trigger a sorting crash.
- There is no disk cache. The built-in `coverimage` caches by filename and settings, which would serve a stale percentage.
- Writes go to a temporary file and are renamed into place, so a screensaver app can never read a half-written image.

## Licence

MIT. Derived from KOReader's `coverimage` plugin.
