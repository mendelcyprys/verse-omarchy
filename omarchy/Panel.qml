import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: pick a Tanakh reference and read it in Hebrew alongside the
// public-domain JPS 1917 translation.
//
// The text belongs to Sefaria's API, not to this widget. What's kept is the
// last reference you looked at and your display preferences, in this widget's
// shell.json entry, so the next open lands where you left off.
//
// Neighbouring verses and a pool of random passages are fetched in the
// background and cached, so Prev / Next / Random are usually instant.
Panel {
  id: root
  moduleName: "erikmanhem.verse"
  ipcTarget: "erikmanhem.verse"

  // ---- reference + result state -------------------------------------
  property string ref: "Genesis 1:1"
  property string loadedRef: ""
  property string loadedHeRef: ""
  property var verses: []                    // [{ num, heRaw, en }]
  property bool loading: false
  property string errorText: ""
  property string pendingRef: ""
  property bool rememberPending: false
  property bool syncingMenu: false

  // Book/chapter/verse the menu is pointing at (kept in step with loadedRef).
  property int selChap: 1
  property int selVerse: 1

  // ---- display preferences (persisted) -----------------------------
  property bool showRefInBar: false
  property bool showHebrew: true
  property bool showEnglish: true
  property bool heTaamim: true               // cantillation marks (trop)
  property bool heNiqqud: true               // vowel points
  property bool hebrewFirst: true            // Hebrew above English, or below
  property real textScale: 1.0

  // ---- background caches ------------------------------------------
  property var _cache: ({})                  // normKey -> entry
  property var _cacheOrder: []
  property var _shapes: ({})                  // book -> [verses per chapter]
  property var _shapePending: ({})
  property var _shapeQueue: []
  property string _shapeActive: ""
  property int shapeRev: 0                    // bump to re-evaluate bound maxima
  property var _prefetchQueue: []
  property string _prefetchActive: ""
  property var _randomPool: []                // ref strings, pre-cached
  property int _randomTries: 0                // capped per prefetch cycle
  property double _lastSwapAt: 0              // for the passage-change animation

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // Cardo: an OFL book face with complete Biblical Hebrew — full cantillation
  // and vocalisation. Bundled with the plugin; Qt falls back on its own if
  // the file is ever missing.
  FontLoader { id: cardo; source: Qt.resolvedUrl("fonts/Cardo-Regular.ttf") }
  readonly property string hebrewFont: cardo.status === FontLoader.Ready ? cardo.font.family : "Noto Serif Hebrew"

  readonly property string barIcon: "\uf02d"   // nf-fa-book (Nerd Font)

  readonly property string englishVersion: "english|The Holy Scriptures: A New Translation (JPS 1917)"

  readonly property var books: [
    "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy",
    "Joshua", "Judges", "I Samuel", "II Samuel", "I Kings", "II Kings",
    "Isaiah", "Jeremiah", "Ezekiel",
    "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah", "Nahum",
    "Habakkuk", "Zephaniah", "Haggai", "Zechariah", "Malachi",
    "Psalms", "Proverbs", "Job", "Song of Songs", "Ruth", "Lamentations",
    "Ecclesiastes", "Esther", "Daniel", "Ezra", "Nehemiah",
    "I Chronicles", "II Chronicles"
  ]
  // Fallback chapter counts, used only until the real per-chapter verse
  // shape arrives from Sefaria's /api/shape.
  readonly property var chapterCounts: ({
    "Genesis": 50, "Exodus": 40, "Leviticus": 27, "Numbers": 36, "Deuteronomy": 34,
    "Joshua": 24, "Judges": 21, "I Samuel": 31, "II Samuel": 24, "I Kings": 22, "II Kings": 25,
    "Isaiah": 66, "Jeremiah": 52, "Ezekiel": 48,
    "Hosea": 14, "Joel": 4, "Amos": 9, "Obadiah": 1, "Jonah": 4, "Micah": 7, "Nahum": 3,
    "Habakkuk": 3, "Zephaniah": 3, "Haggai": 2, "Zechariah": 14, "Malachi": 3,
    "Psalms": 150, "Proverbs": 31, "Job": 42, "Song of Songs": 8, "Ruth": 4, "Lamentations": 5,
    "Ecclesiastes": 12, "Esther": 10, "Daniel": 12, "Ezra": 10, "Nehemiah": 13,
    "I Chronicles": 29, "II Chronicles": 36
  })

  function chapCount(book) {
    var sh = root._shapes[book]
    if (sh && sh.length) return sh.length
    return root.chapterCounts[book] || 150
  }
  function verseCount(book, chap) {
    var sh = root._shapes[book]
    return (sh && chap >= 1 && chap <= sh.length) ? sh[chap - 1] : 0
  }

  // Bound maxima for the steppers. `shapeRev` is threaded through so the
  // binding re-runs when a shape lands.
  readonly property int chapMax: root.shapeRev >= 0 ? root.chapCount(bookDrop.value) : 150
  readonly property int verseMax: {
    var n = root.shapeRev >= 0 ? root.verseCount(bookDrop.value, root.selChap) : 0
    return n > 0 ? n : 176
  }

  // What Prev / Next / the chapter arrows can do right now — drives both the
  // guards and whether the buttons look enabled.
  readonly property string _navBase: root.loadedRef !== "" ? root.loadedRef : root.ref
  readonly property var _navParts: root.refToParts(root._navBase)
  readonly property bool canPrevVerse: root.shapeRev >= 0 && !root.loading && root.stepRef(root._navBase, -1) !== null
  readonly property bool canNextVerse: root.shapeRev >= 0 && !root.loading && root.stepRef(root._navBase, 1) !== null
  readonly property bool canPrevChap: !root.loading && !!root._navParts && root._navParts.chap > 1
  readonly property bool canNextChap: root.shapeRev >= 0 && !root.loading && !!root._navParts
    && root._navParts.chap < root.chapCount(root._navParts.book)

  // ---- settings -------------------------------------------------
  function loadSettings() {
    var s = root.settings || ({})
    if (s.ref) root.ref = String(s.ref)
    // A stale non-Tanakh ref (e.g. a bad older random) shouldn't strand us.
    if (root.plainTanakhRef(root.ref) === "") root.ref = "Genesis 1:1"
    if (s.showRefInBar !== undefined) root.showRefInBar = s.showRefInBar !== false
    if (s.showHebrew !== undefined) root.showHebrew = s.showHebrew !== false
    if (s.showEnglish !== undefined) root.showEnglish = s.showEnglish !== false
    if (s.taamim !== undefined) root.heTaamim = s.taamim !== false
    if (s.niqqud !== undefined) root.heNiqqud = s.niqqud !== false
    if (s.hebrewFirst !== undefined) root.hebrewFirst = s.hebrewFirst !== false
    if (s.scale !== undefined) {
      var sc = parseFloat(s.scale)
      if (!isNaN(sc)) root.textScale = Math.max(0.75, Math.min(2.0, sc))
    }
  }

  function persistSettings() {
    var next = {
      ref: root.ref,
      showRefInBar: root.showRefInBar,
      showHebrew: root.showHebrew,
      showEnglish: root.showEnglish,
      taamim: root.heTaamim,
      niqqud: root.heNiqqud,
      hebrewFirst: root.hebrewFirst,
      scale: root.textScale
    }
    root.settings = next
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // Coalesce a burst of display-toggle / size clicks into one shell.json write.
  Timer { id: persistTimer; interval: 250; onTriggered: root.persistSettings() }
  function persistSoon() { persistTimer.restart() }
  function flushPersist() {
    if (persistTimer.running) { persistTimer.stop(); root.persistSettings() }
  }

  function setScale(v) {
    var clamped = Math.max(0.75, Math.min(2.0, Math.round(v * 1000) / 1000))
    if (clamped === root.textScale) return
    root.textScale = clamped
    root.persistSoon()
  }

  onSettingsChanged: {
    root.loadSettings()
    if (root.ref !== root.loadedRef && root.ref !== root.pendingRef) {
      root.syncMenuFrom(root.ref)
      root.load(root.ref, false)
    }
  }

  Component.onCompleted: Qt.callLater(function() {
    root.loadSettings()
    root.syncMenuFrom(root.ref)
    if (root.loadedRef === "" && root.pendingRef === "") root.load(root.ref, false)
  })

  onOpenedChanged: {
    if (!opened) { root.flushPersist(); return }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (root.verses.length === 0 && !root.loading && root.errorText === "")
      root.load(root.ref, false)
    else
      prefetchTimer.restart()
    randomFillTimer.restart()
  }

  // ---- reference parsing --------------------------------------
  function normKey(s) {
    return String(s || "").toLowerCase().replace(/\s+/g, " ").trim()
  }

  // "Song of Songs 3:2-4" -> { book, chap, vStart, vEnd }.  vEnd 0 == whole chapter.
  function refToParts(s) {
    var m = String(s || "").match(/^\s*(.+?)\s+(\d+):(\d+)(?:-(\d+))?\s*$/)
    if (m) return { "book": m[1].trim(), "chap": parseInt(m[2], 10),
                    "vStart": parseInt(m[3], 10), "vEnd": m[4] ? parseInt(m[4], 10) : parseInt(m[3], 10) }
    var m2 = String(s || "").match(/^\s*(.+?)\s+(\d+)\s*$/)
    if (m2) return { "book": m2[1].trim(), "chap": parseInt(m2[2], 10), "vStart": 1, "vEnd": 0 }
    return null
  }

  function bookOf(ref) {
    var p = root.refToParts(ref)
    return p ? p.book : ""
  }

  // The reference one step (±1) from `ref`, rolling across chapter borders
  // when the verse shape is known. Returns null at the ends of a book.
  function stepRef(ref, delta) {
    var p = root.refToParts(ref)
    if (!p) return null
    var book = p.book, chap = p.chap

    if (p.vEnd === 0) {   // a whole chapter is loaded
      if (delta > 0) return (chap >= root.chapCount(book)) ? null : (book + " " + (chap + 1))
      return (chap <= 1) ? null : (book + " " + (chap - 1))
    }

    var v = (delta > 0 ? p.vEnd : p.vStart) + delta
    if (v < 1) {
      if (chap <= 1) return null
      var pc = root.verseCount(book, chap - 1)
      return book + " " + (chap - 1) + ":" + (pc > 0 ? pc : 200)  // 200 -> Sefaria clamps
    }
    var cc = root.verseCount(book, chap)
    if (cc > 0 && v > cc) {
      if (chap >= root.chapCount(book)) return null
      return book + " " + (chap + 1) + ":1"
    }
    return book + " " + chap + ":" + v
  }

  function syncMenuFrom(reference) {
    var p = root.refToParts(reference)
    if (!p) return
    root.syncingMenu = true
    if (root.books.indexOf(p.book) !== -1) bookDrop.value = p.book
    root.selChap = p.chap
    root.selVerse = p.vStart
    root.syncingMenu = false
  }

  // Jump to a chapter (verse 1). Clamped; no-op past a book's ends.
  function goToChapter(chap) {
    if (root.loading) return
    var book = (root._navParts ? root._navParts.book : bookDrop.value)
    var c = Math.max(1, Math.min(root.chapCount(book), chap))
    if (root._navParts && c === root._navParts.chap) return
    root.load(book + " " + c + ":1", true)
  }
  function stepChapter(delta) { root.goToChapter((root._navParts ? root._navParts.chap : root.selChap) + delta) }

  function scrollVerses(dir) {
    var f = versesFlick
    if (!f) return
    var maxY = Math.max(0, f.contentHeight - f.height)
    if (maxY <= 0) return
    scrollAnim.stop()
    scrollAnim.to = Math.max(0, Math.min(maxY, f.contentY + dir * Style.space(84)))
    scrollAnim.start()
  }

  // ---- text shaping -----------------------------------------
  function stripHtml(s) {
    return String(s || "")
      .replace(/<[^>]*>/g, "")
      .replace(/&nbsp;/g, " ")
      .replace(/&thinsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, "\"")
      .replace(/&#39;/g, "'")
      .replace(/&rsquo;/g, "’")
      .replace(/&lsquo;/g, "‘")
      .replace(/\s+/g, " ")
      .trim()
  }

  // Hebrew as it should currently render: strip cantillation and/or vowels
  // per the toggles. Kept out of the model so flipping a toggle is instant.
  function renderHe(raw) {
    var t = root.stripHtml(raw)
    if (!root.heTaamim) t = t.replace(/[֑-֯]/g, "")
    if (!root.heNiqqud) t = t.replace(/[ְ-ׇֽֿׁׂׅׄ]/g, "")
    return t
  }

  function flatten(value, out) {
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i++) root.flatten(value[i], out)
    } else if (value !== null && value !== undefined && String(value) !== "") {
      out.push(String(value))
    }
    return out
  }

  function buildEntry(data) {
    var he = [], en = []
    var list = data.versions || []
    for (var i = 0; i < list.length; i++) {
      var v = list[i]
      if (v.language === "he" || v.actualLanguage === "he") he = root.flatten(v.text, [])
      else if (v.language === "en" || v.actualLanguage === "en") en = root.flatten(v.text, [])
    }
    var startVerse = 1
    if (Array.isArray(data.sections) && data.sections.length > 0) {
      var n = parseInt(data.sections[data.sections.length - 1], 10)
      if (!isNaN(n)) startVerse = n
    }
    return {
      "he": he, "en": en, "startVerse": startVerse,
      "loadedRef": String(data.ref || ""), "heRef": String(data.heRef || ""),
      "count": Math.max(he.length, en.length)
    }
  }

  function buildRows(he, en, startVerse) {
    var count = Math.max(he.length, en.length)
    var cap = 120, rows = []
    for (var j = 0; j < Math.min(count, cap); j++) {
      rows.push({ "num": startVerse + j, "heRaw": he[j] || "", "en": root.stripHtml(en[j] || "") })
    }
    return rows
  }

  // ---- cache ------------------------------------------------
  function cachePut(key, entry) {
    var k = root.normKey(key)
    if (k === "") return
    if (!(k in root._cache)) root._cacheOrder.push(k)
    root._cache[k] = entry
    while (root._cacheOrder.length > 80) {
      var old = root._cacheOrder.shift()
      delete root._cache[old]
    }
  }

  // ---- load -----------------------------------------------
  function curlFor(reference) {
    return ["curl", "-fsSL", "--max-time", "12", "-G",
      "https://www.sefaria.org/api/v3/texts/" + encodeURIComponent(reference),
      "--data-urlencode", "version=" + root.englishVersion,
      "--data-urlencode", "version=hebrew"]
  }

  function load(reference, remember) {
    var r = String(reference || "").trim()
    if (r === "") return
    var hit = root._cache[root.normKey(r)]
    if (hit) { root.applyEntry(hit, remember === true, r); return }
    root.pendingRef = r
    root.rememberPending = remember === true
    root.loading = true
    root.errorText = ""
    if (fetchProc.running) fetchProc.running = false
    fetchProc.command = root.curlFor(r)
    fetchProc.running = true
  }

  function applyEntry(entry, remember, requestedRef) {
    root.loading = false
    root.errorText = entry.count > 120
      ? ("Showing the first 120 of " + entry.count + " verses.") : ""
    root.verses = root.buildRows(entry.he, entry.en, entry.startVerse)
    root.loadedRef = entry.loadedRef || requestedRef
    root.loadedHeRef = entry.heRef
    root.ref = root.loadedRef
    root.syncMenuFrom(root.loadedRef)
    root.ensureShape(root.bookOf(root.loadedRef))
    if (remember) root.persistSettings()
    prefetchTimer.restart()
  }

  readonly property int _randomPoolTarget: 4

  function loadRandom() {
    if (root.loading) return
    root._randomTries = 0
    if (root._randomPool.length > 0) {
      root.load(root._randomPool.shift(), true)
    } else {
      root.loading = true
      root.errorText = ""
      randomNowProc.running = true
    }
    // Refill straight away so the next Random is ready, not just eventually.
    randomFillTimer.restart()
  }

  function fillRandomPool() {
    if (root._randomPool.length >= root._randomPoolTarget) return
    if (randomRefProc.running || root._randomTries >= 8) return
    randomRefProc.running = true
  }

  // ---- shapes (chapter / verse counts) ---------------------
  function ensureShape(book) {
    if (!book || root._shapes[book] || root._shapePending[book]) return
    root._shapePending[book] = true
    root._shapeQueue.push(book)
    root.pumpShape()
  }

  function pumpShape() {
    if (shapeProc.running || root._shapeQueue.length === 0) return
    root._shapeActive = root._shapeQueue.shift()
    shapeProc.command = ["curl", "-fsSL", "--max-time", "10",
      "https://www.sefaria.org/api/shape/" + encodeURIComponent(root._shapeActive)]
    shapeProc.running = true
  }

  // ---- prefetch ------------------------------------------
  function buildPrefetch() {
    if (root.loadedRef === "") return
    var span = 3, refs = [], cur, i

    cur = root.loadedRef
    for (i = 0; i < span; i++) { cur = root.stepRef(cur, 1); if (!cur) break; refs.push(cur) }
    cur = root.loadedRef
    for (i = 0; i < span; i++) { cur = root.stepRef(cur, -1); if (!cur) break; refs.push(cur) }

    // The first / last few verses of the neighbouring chapters, so a jump
    // with the chapter stepper (not just Prev/Next) is ready too.
    var p = root.refToParts(root.loadedRef)
    if (p && p.chap) {
      if (p.chap + 1 <= root.chapCount(p.book)) {
        for (i = 1; i <= span; i++) refs.push(p.book + " " + (p.chap + 1) + ":" + i)
      }
      if (p.chap - 1 >= 1) {
        var pv = root.verseCount(p.book, p.chap - 1)
        var last = pv > 0 ? pv : 200
        for (i = 0; i < span; i++) {
          if (pv > 0 && last - i < 1) break
          refs.push(p.book + " " + (p.chap - 1) + ":" + (last - i))
        }
      }
    }

    if (root._randomPool.length < root._randomPoolTarget) {
      root._randomTries = 0
      randomFillTimer.restart()
    }

    var q = []
    for (i = 0; i < refs.length; i++) {
      if (!root._cache[root.normKey(refs[i])] && q.indexOf(refs[i]) < 0) q.push(refs[i])
    }
    for (i = 0; i < root._randomPool.length; i++) {
      var rr = root._randomPool[i]
      if (!root._cache[root.normKey(rr)] && q.indexOf(rr) < 0) q.push(rr)
    }
    root._prefetchQueue = q
    root.pumpPrefetch()
  }

  function pumpPrefetch() {
    if (prefetchProc.running || randomRefProc.running) return
    while (root._prefetchQueue.length > 0 && root._cache[root.normKey(root._prefetchQueue[0])])
      root._prefetchQueue.shift()
    if (root._prefetchQueue.length > 0) {
      root._prefetchActive = root._prefetchQueue.shift()
      prefetchProc.command = root.curlFor(root._prefetchActive)
      prefetchProc.running = true
      return
    }
  }

  // ---- processes ----------------------------------------
  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t === "") { root.loading = false; root.errorText = "No answer from Sefaria."; return }
        var data
        try { data = JSON.parse(t) }
        catch (e) { root.loading = false; root.errorText = "Could not read Sefaria's reply."; return }
        if (data.error) { root.loading = false; root.errorText = String(data.error); return }
        var entry = root.buildEntry(data)
        if (entry.he.length === 0 && entry.en.length === 0) {
          root.loading = false; root.errorText = "Nothing here for that reference."; return
        }
        root.cachePut(root.pendingRef, entry)
        if (entry.loadedRef) root.cachePut(entry.loadedRef, entry)
        root.applyEntry(entry, root.rememberPending, root.pendingRef)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var e = String(text || "").trim()
        if (e === "" || !root.loading) return
        root.loading = false
        root.errorText = e.indexOf("404") !== -1
          ? "Sefaria doesn't recognise “" + root.pendingRef + "”."
          : "Could not reach Sefaria."
      }
    }
  }

  Process {
    id: prefetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").trim())
          if (d && !d.error) {
            var e = root.buildEntry(d)
            if (e.he.length > 0 || e.en.length > 0) {
              root.cachePut(root._prefetchActive, e)
              if (e.loadedRef) root.cachePut(e.loadedRef, e)
            }
          }
        } catch (err) { /* a missed prefetch just means a slower step later */ }
      }
    }
    onExited: { root._prefetchActive = ""; root.pumpPrefetch() }
  }

  // Restricting the pick to the 39 book titles keeps `random` inside the
  // plain text — `categories=Tanakh` also sweeps in Steinsaltz introductions
  // and other commentary filed under the category.
  readonly property string _randomTitles: root.books.join("|")
  function randomCurl() {
    return ["curl", "-fsSL", "--max-time", "12", "-G",
      "https://www.sefaria.org/api/texts/random",
      "--data-urlencode", "titles=" + root._randomTitles]
  }
  // A plain "Book Chapter:Verse" in one of our 39 books, or "" if not.
  function plainTanakhRef(s) {
    var p = root.refToParts(s)
    return (p && root.books.indexOf(p.book) >= 0) ? String(s) : ""
  }

  Process {
    id: randomRefProc
    command: root.randomCurl()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").trim())
          var rr = root.plainTanakhRef(d && d.ref ? d.ref : "")
          if (rr !== "" && root._randomPool.indexOf(rr) < 0) {
            root._randomPool.push(rr)
            // Cache its text too, so drawing it later is instant.
            if (!root._cache[root.normKey(rr)] && root._prefetchQueue.indexOf(rr) < 0) {
              root._prefetchQueue.push(rr)
              root.pumpPrefetch()
            }
          }
        } catch (e) { /* ignore */ }
      }
    }
    onExited: {
      root._randomTries++
      if (root._randomPool.length < root._randomPoolTarget && root._randomTries < 8)
        randomFillTimer.restart()
    }
  }

  property int _randomNowTries: 0
  Process {
    id: randomNowProc
    command: root.randomCurl()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rr = ""
        try {
          var d = JSON.parse(String(text || "").trim())
          rr = root.plainTanakhRef(d && d.ref ? d.ref : "")
        } catch (e) { /* handled below */ }
        if (rr !== "") { root._randomNowTries = 0; root.load(rr, true); return }
        if (root._randomNowTries < 5) {
          root._randomNowTries++
          Qt.callLater(function() { randomNowProc.running = true })
          return
        }
        root._randomNowTries = 0
        root.loading = false
        root.errorText = "Couldn't fetch a random passage."
      }
    }
  }

  Process {
    id: shapeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").trim())
          var e = Array.isArray(d) ? d[0] : d
          if (e && Array.isArray(e.chapters)) {
            root._shapes[root._shapeActive] = e.chapters
            root.shapeRev++
          }
        } catch (err) { /* keep the hardcoded fallback */ }
      }
    }
    onExited: {
      delete root._shapePending[root._shapeActive]
      root._shapeActive = ""
      root.pumpShape()
    }
  }

  Timer { id: prefetchTimer; interval: 700; onTriggered: root.buildPrefetch() }
  Timer { id: randomFillTimer; interval: 350; onTriggered: root.fillRandomPool() }

  // ---- bar button --------------------------------------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var label = root.loadedRef !== "" ? root.loadedRef : root.ref
      return (root.showRefInBar && label !== "") ? (root.barIcon + "  " + label) : root.barIcon
    }
    tooltipText: (root.loadedRef !== "" ? root.loadedRef + "  —  " : "")
      + "left-click to open · middle-click for a random verse"
    onPressed: function(which) {
      if (which === Qt.RightButton) {
        root.showRefInBar = !root.showRefInBar
        root.persistSettings()
        return
      }
      if (which === Qt.MiddleButton) {
        root.loadRandom()
        if (!root.opened) root.open()
        return
      }
      root.opened ? root.close() : root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(580))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(660))

    // Ease the card between sizes as the passage length or the display
    // toggles change, instead of snapping. Off until the panel is up so the
    // first open doesn't animate from zero.
    Behavior on contentHeight {
      enabled: panel.open && root.verses.length > 0
      NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Only the book search field swallows keys; everything else is buttons.
      blocked: bookDrop.popupOpen
      onCloseRequested: root.close()
      // h / l (← / →) walk verses; j / k (↑ / ↓) scroll a long passage.
      onMoveRequested: function(dx, dy) {
        if (dx > 0) root.step(1)
        else if (dx < 0) root.step(-1)
        else if (dy !== 0) root.scrollVerses(dy)
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.loadRandom()
        else if (t === "s" || t === "S") {
          if (root.showHebrew && root.showEnglish) { root.hebrewFirst = !root.hebrewFirst; root.persistSoon() }
        }
        else if (t === "[" || t === "H") root.stepChapter(-1)
        else if (t === "]" || t === "L") root.stepChapter(1)
        else if (t === "-" || t === "_") root.setScale(root.textScale - 0.125)
        else if (t === "+" || t === "=") root.setScale(root.textScale + 0.125)
        else if (t === "0") root.setScale(1.0)
      }

      NumberAnimation {
        id: scrollAnim
        target: versesFlick
        property: "contentY"
        duration: 110
        easing.type: Easing.OutQuad
      }

      ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---- header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            id: headerRef
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.loadedRef !== "" ? root.loadedRef : "Verse"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            transform: Translate { id: headerShift }

            Connections {
              target: root
              function onLoadedRefChanged() {
                if (root.loadedRef !== "") headerAnim.restart()
              }
            }
            SequentialAnimation {
              id: headerAnim
              PropertyAction { target: headerRef; property: "opacity"; value: 0.15 }
              PropertyAction { target: headerShift; property: "x"; value: Style.space(-6) }
              ParallelAnimation {
                NumberAnimation { target: headerRef; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic }
                NumberAnimation { target: headerShift; property: "x"; to: 0; duration: 260; easing.type: Easing.OutCubic }
              }
            }
          }

          // Quiet activity spinner — content stays put underneath while it turns.
          Text {
            Layout.alignment: Qt.AlignVCenter
            textFormat: Text.PlainText
            opacity: root.loading ? 0.9 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 180 } }
            text: "\uf1ce"                               // nf-fa-circle_o_notch
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            RotationAnimator on rotation {
              running: root.loading
              loops: Animation.Infinite
              from: 0; to: 360
              duration: 750
            }
          }

          Text {
            visible: root.loadedHeRef !== ""
            textFormat: Text.PlainText
            text: root.loadedHeRef
            color: root.dim
            font.family: root.hebrewFont
            font.pixelSize: Style.font.subtitle
          }
        }

        // ---- book
        SearchableDropdown {
          id: bookDrop
          Layout.fillWidth: true
          showLabel: false
          value: "Genesis"
          options: root.books
          placeholderText: "Find a book…"
          foreground: root.fg
          accent: Color.accent
          fontFamily: root.fontFamily
          onChanged: function(v) {
            if (root.syncingMenu) return
            root.ensureShape(v)
            root.load(v + " 1:1", true)
          }
          onHovered: function(h) { if (h) keyCatcher.forceActiveFocus() }
        }

        // ---- chapter / verse steppers + random
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          RowLayout {
            spacing: Style.space(3)
            Text {
              text: "CHAPTER"
              color: Qt.darker(root.fg, 2.1)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.5
              Layout.alignment: Qt.AlignVCenter
            }
            Button {
              text: "‹"
              foreground: root.fg
              enabled: root.canPrevChap
              opacity: enabled ? 1.0 : 0.25
              tooltipText: "Previous chapter  ( [ )"
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.stepChapter(-1)
              Behavior on opacity { NumberAnimation { duration: 140 } }
            }
            Text {
              text: root.selChap
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              Layout.preferredWidth: Style.space(24)
              Layout.alignment: Qt.AlignVCenter
            }
            Button {
              text: "›"
              foreground: root.fg
              enabled: root.canNextChap
              opacity: enabled ? 1.0 : 0.25
              tooltipText: "Next chapter  ( ] )"
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.stepChapter(1)
              Behavior on opacity { NumberAnimation { duration: 140 } }
            }
          }

          RowLayout {
            spacing: Style.space(3)
            Text {
              text: "VERSE"
              color: Qt.darker(root.fg, 2.1)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.5
              Layout.alignment: Qt.AlignVCenter
            }
            Button {
              text: "‹"
              foreground: root.fg
              enabled: root.canPrevVerse
              opacity: enabled ? 1.0 : 0.25
              tooltipText: "Previous verse  ( h )"
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.step(-1)
              Behavior on opacity { NumberAnimation { duration: 140 } }
            }
            Text {
              text: root.selVerse
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              Layout.preferredWidth: Style.space(24)
              Layout.alignment: Qt.AlignVCenter
            }
            Button {
              text: "›"
              foreground: root.fg
              enabled: root.canNextVerse
              opacity: enabled ? 1.0 : 0.25
              tooltipText: "Next verse  ( l )"
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.step(1)
              Behavior on opacity { NumberAnimation { duration: 140 } }
            }
          }

          Item { Layout.fillWidth: true }

          Button {
            text: "Random"
            foreground: root.fg
            enabled: !root.loading
            tooltipText: "A random passage from the Tanakh  (r)"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.loadRandom()
          }
        }

        Text {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: "h l  verse     j k  scroll     [ ]  chapter     r  random     s  swap"
          color: Qt.darker(root.fg, 2.4)
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.caption * 0.9)
          font.letterSpacing: 0.4
        }

        // ---- display controls
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(5)

          Button {
            text: "Hebrew"
            foreground: root.fg
            active: root.showHebrew
            tooltipText: "Show the Hebrew text"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.showHebrew = !root.showHebrew; root.persistSoon() }
          }

          Button {
            text: "English"
            foreground: root.fg
            active: root.showEnglish
            tooltipText: "Show the JPS 1917 translation"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.showEnglish = !root.showEnglish; root.persistSoon() }
          }

          // Swap which script sits on top. Only meaningful with both showing.
          Button {
            text: "\uf07d"   // nf-fa-arrows_v
            foreground: root.fg
            visible: root.showHebrew && root.showEnglish
            tooltipText: root.hebrewFirst ? "Put English on top" : "Put Hebrew on top"
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.hebrewFirst = !root.hebrewFirst; root.persistSoon() }
          }

          Rectangle {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: Style.spacing.hairline
            implicitHeight: Style.space(16)
            color: root.fg
            opacity: 0.2
          }

          Button {
            text: "Trop"
            foreground: root.fg
            active: root.heTaamim
            enabled: root.showHebrew
            tooltipText: "Cantillation marks (te'amim)"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.heTaamim = !root.heTaamim; root.persistSoon() }
          }

          Button {
            text: "Niqqud"
            foreground: root.fg
            active: root.heNiqqud
            enabled: root.showHebrew
            tooltipText: "Vowel points"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.heNiqqud = !root.heNiqqud; root.persistSoon() }
          }

          Item { Layout.fillWidth: true }

          Button {
            text: "A−"
            foreground: root.fg
            enabled: root.textScale > 0.75
            tooltipText: "Smaller"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.setScale(root.textScale - 0.125)
          }

          Text {
            id: zoomLabel
            Layout.alignment: Qt.AlignVCenter
            // Fixed width so "88%" / "100%" / "175%" don't nudge the A− / A+
            // buttons as the number changes length.
            Layout.preferredWidth: Style.space(38)
            horizontalAlignment: Text.AlignHCenter
            text: Math.round(root.textScale * 100) + "%"
            color: zoomHover.hovered ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            HoverHandler { id: zoomHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.setScale(1.0) }

            PanelToolTip {
              visible: zoomHover.hovered
              text: "Reset to 100%"
              panelForeground: root.fg
              fontFamily: root.fontFamily
            }
          }

          Button {
            text: "A+"
            foreground: root.fg
            enabled: root.textScale < 2.0
            tooltipText: "Bigger"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.setScale(root.textScale + 0.125)
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.fg }

        Text {
          visible: root.loading && root.verses.length === 0
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Loading…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          visible: root.errorText !== ""
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.errorText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: !root.loading && root.verses.length > 0 && !root.showHebrew && !root.showEnglish
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Both Hebrew and English are hidden."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flickable {
          id: versesFlick
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(versesCol.implicitHeight, Style.space(380))
          visible: root.verses.length > 0 && (root.showHebrew || root.showEnglish)
          clip: true
          contentWidth: width
          contentHeight: versesCol.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          // Settle the text in on every change of passage — a short fade
          // plus a small upward drift. Noticeable, not sluggish.
          Connections {
            target: root
            function onVersesChanged() {
              var now = Date.now()
              // When they're tapping through faster than the animation, drop
              // it and just show each verse — no strobing.
              if (now - root._lastSwapAt < 340) {
                swapFade.stop()
                versesCol.opacity = 1
                swapShift.y = 0
              } else {
                swapFade.restart()
              }
              root._lastSwapAt = now
            }
          }
          SequentialAnimation {
            id: swapFade
            PropertyAction { target: versesCol; property: "opacity"; value: 0 }
            PropertyAction { target: swapShift; property: "y"; value: Style.space(12) }
            ParallelAnimation {
              NumberAnimation { target: versesCol; property: "opacity"; to: 1; duration: 320; easing.type: Easing.OutCubic }
              NumberAnimation { target: swapShift; property: "y"; to: 0; duration: 320; easing.type: Easing.OutCubic }
            }
          }

          // Flipping the Hebrew/English order: fade through, with a little
          // vertical bounce so it reads as the blocks trading places.
          Connections {
            target: root
            function onHebrewFirstChanged() { orderSwap.restart() }
          }
          SequentialAnimation {
            id: orderSwap
            PropertyAction { target: versesCol; property: "opacity"; value: 0 }
            PropertyAction { target: swapShift; property: "y"; value: Style.space(-12) }
            ParallelAnimation {
              NumberAnimation { target: versesCol; property: "opacity"; to: 1; duration: 300; easing.type: Easing.OutCubic }
              NumberAnimation { target: swapShift; property: "y"; to: 0; duration: 360; easing.type: Easing.OutBack }
            }
          }

          Column {
            id: versesCol
            width: versesFlick.width
            spacing: Style.space(16)
            transform: Translate { id: swapShift }

            Repeater {
              model: root.verses

              delegate: GridLayout {
                id: verseBlock
                required property var modelData
                width: versesCol.width
                columns: 1
                rowSpacing: Style.space(7)

                readonly property string heText: root.renderHe(verseBlock.modelData.heRaw)

                Text {
                  Layout.fillWidth: true
                  Layout.row: root.hebrewFirst ? 0 : 1
                  Layout.column: 0
                  visible: root.showHebrew && verseBlock.heText !== ""
                  textFormat: Text.PlainText
                  text: verseBlock.heText
                  color: root.fg
                  font.family: root.hebrewFont
                  font.pixelSize: Math.round(Style.font.display * root.textScale)
                  horizontalAlignment: Text.AlignRight
                  lineHeight: 1.5
                  wrapMode: Text.WordWrap
                }

                Text {
                  Layout.fillWidth: true
                  Layout.row: root.hebrewFirst ? 1 : 0
                  Layout.column: 0
                  visible: root.showEnglish && verseBlock.modelData.en !== ""
                  textFormat: Text.PlainText
                  text: (root.verses.length > 1 ? (verseBlock.modelData.num + " ") : "")
                    + verseBlock.modelData.en
                  color: Qt.darker(root.fg, 1.32)
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(Style.font.body * root.textScale)
                  lineHeight: 1.42
                  wrapMode: Text.WordWrap
                  renderType: Text.NativeRendering
                }
              }
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.fg }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          maximumLineCount: 1
          elide: Text.ElideRight
          text: "MAM (CC BY-SA)      JPS 1917 (public domain)      sefaria.org"
          color: Qt.darker(root.fg, 2.4)
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.caption * 0.9)
          font.letterSpacing: 0.3
        }
      }
    }
  }

  // ---- step (kept below the tree so `panel` etc. are in scope) ----
  //
  // While a fetch is in flight we ignore further steps: a cached neighbour
  // resolves instantly and never trips this, so quick tapping still flies
  // through the prefetched window; it only stalls once you outrun the cache,
  // and then one press lands per fetch instead of a queue of them.
  function step(delta) {
    if (root.loading) return
    var target = root.stepRef(root.loadedRef !== "" ? root.loadedRef : root.ref, delta)
    if (!target) return
    root.load(target, true)
  }
}
