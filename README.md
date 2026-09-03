# Verse

An Omarchy bar widget that drops down a small reader for the Tanakh: type a
reference and see it in **Hebrew** and the **JPS 1917** English translation
side by side.

![The dropdown showing Genesis 1:1](preview.png)

## Use

- **Left-click** the widget to open the dropdown.
- **Book** — the dropdown (type to filter).
- **Chapter / Verse** — the `‹ N ›` steppers. The arrows roll across chapter
  borders and grey out at the start of Genesis / end of Chronicles.
- The verses either side (and a bit into the neighbouring chapters) plus a
  pool of random passages are fetched in the background, so moving around is
  normally instant. Controls disable themselves while a verse is genuinely
  loading, so hammering them can't queue up a pile of requests.

### Keyboard (panel focused)

| key | |
|-----|-----|
| `h` / `l`  (or `←` / `→`) | previous / next **verse** |
| `j` / `k`  (or `↑` / `↓`) | **scroll** a long passage |
| `[` / `]`  (or `H` / `L`) | previous / next **chapter** |
| `r` | random passage |
| `−` / `+` | text smaller / bigger |
| `0` | reset text size to 100% |
| `Esc` | close |
- **Random** pulls a random passage from the Tanakh.
- **Middle-click** the widget for a random verse without opening it first.
- **Right-click** the widget to toggle whether the current reference shows
  next to the icon in the bar.
- **Esc** closes the dropdown.

### Display

A row of toggles:

- **Hebrew** / **English** — show each independently (or neither).
- **Trop** — cantillation marks (te'amim) on/off.
- **Niqqud** — vowel points on/off.
- **A− / A+** — text size, 75%–200%. Click the **percentage** to reset to 100%.

The chapter and verse steppers know each book's real shape (how many
chapters, how many verses in the current chapter) — pulled from Sefaria's
`/api/shape` — so they can't run past the end.

The last reference you viewed and all display settings are saved to this
widget's `shell.json` entry, so the next time you open it — or restart the
shell — you land back where you were.

## Developing

Bar-widget QML changes don't always hot-reload cleanly; after editing
`omarchy/Panel.qml` run `omarchy restart shell` to be sure it takes.

## Data

Text is fetched live from the [Sefaria](https://www.sefaria.org) API:

- **Hebrew** — *Miqra according to the Masorah* (a vocalised Masoretic text),
  licensed CC-BY-SA.
- **English** — *The Holy Scriptures: A New Translation* (JPS 1917), public
  domain.

Needs an internet connection and `curl`. Nothing else is stored or sent.

The Hebrew is set in **Cardo** (Reideler / David J. Perry), an OFL book face
with complete Biblical Hebrew — bundled in `omarchy/fonts/`, licence in
`omarchy/fonts/OFL.txt`.

## Install

```bash
omarchy plugin add <git-url> --enable
```

or, from a local checkout:

```bash
cp -r verse ~/.config/omarchy/plugins/erikmanhem.verse
omarchy-shell shell rescanPlugins
omarchy plugin enable erikmanhem.verse --section center
```

Move it afterwards with `omarchy bar move erikmanhem.verse --section right`.

## License

MIT (see `LICENSE`) for the plugin code. The bundled Cardo font is OFL
(`omarchy/fonts/OFL.txt`); the scripture texts are under their own licences
as noted above.
