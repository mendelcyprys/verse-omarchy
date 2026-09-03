import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: pick a reference and read it in the original language alongside
// a public-domain English translation. Three corpora, each its own source:
//
//   Tanakh          Hebrew (MAM) + JPS 1917      Sefaria    sefaria.org
//   New Testament   Greek (Textus Receptus) + KJV bolls.life bolls.life
//   Quran           Arabic (Uthmani) + Pickthall  AlQuran    alquran.cloud
//
// None of the text belongs to this widget. What's kept is the corpus and
// last reference you looked at plus your display preferences, in this
// widget's shell.json entry, so the next open lands where you left off.
//
// Neighbouring verses and a pool of random passages are fetched in the
// background and cached, so Prev / Next / Random are usually instant.
Panel {
  id: root
  moduleName: "erikmanhem.verse"
  ipcTarget: "erikmanhem.verse"

  // ---- reference + result state -------------------------------------
  property string corpus: "tanakh"           // "tanakh" | "nt" | "quran"
  property string ref: "Genesis 1:1"
  property var corpusRef: ({})                // corpus -> last ref there
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
  property var _history: []                   // back-stack of user-visited refs
  property bool _restoringHistory: false      // set while a Back navigation resolves

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // Cardo: an OFL book face with complete Biblical Hebrew (full cantillation
  // and vocalisation) and polytonic Greek. Amiri: an OFL Naskh face for the
  // Quran, full harakat. Both bundled; Qt falls back on its own if missing.
  FontLoader { id: cardo; source: Qt.resolvedUrl("fonts/Cardo-Regular.ttf") }
  FontLoader { id: amiri; source: Qt.resolvedUrl("fonts/Amiri-Regular.ttf") }
  readonly property string hebrewFont: cardo.status === FontLoader.Ready ? cardo.font.family : "Noto Serif Hebrew"
  readonly property string greekFont: cardo.status === FontLoader.Ready ? cardo.font.family : "Noto Serif"
  readonly property string arabicFont: amiri.status === FontLoader.Ready ? amiri.font.family : "Noto Naskh Arabic"
  // The script the current corpus's original text is set in. Cardo covers
  // Greek and Latin as well as Hebrew.
  readonly property string nativeFont: root.corpus === "quran" ? root.arabicFont
    : (root.corpus === "nt" || root.corpus === "vulgate") ? root.greekFont : root.hebrewFont

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

  // ---- New Testament (Textus Receptus Greek + KJV, via bolls.life) ----
  readonly property var ntBooks: [
    "Matthew", "Mark", "Luke", "John", "Acts",
    "Romans", "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians",
    "Philippians", "Colossians", "1 Thessalonians", "2 Thessalonians", "1 Timothy",
    "2 Timothy", "Titus", "Philemon", "Hebrews", "James",
    "1 Peter", "2 Peter", "1 John", "2 John", "3 John",
    "Jude", "Revelation"
  ]
  // Verses per chapter (KJV versification). bolls bookid = 40 + index.
  readonly property var ntShape: ({
    "Matthew": [25, 23, 17, 25, 48, 34, 29, 34, 38, 42, 30, 50, 58, 36, 39, 28, 27, 35, 30, 34, 46, 46, 39, 51, 46, 75, 66, 20],
    "Mark": [45, 28, 35, 41, 43, 56, 37, 38, 50, 52, 33, 44, 37, 72, 47, 20],
    "Luke": [80, 52, 38, 44, 39, 49, 50, 56, 62, 42, 54, 59, 35, 35, 32, 31, 37, 43, 48, 47, 38, 71, 56, 53],
    "John": [51, 25, 36, 54, 47, 71, 53, 59, 41, 42, 57, 50, 38, 31, 27, 33, 26, 40, 42, 31, 25],
    "Acts": [26, 47, 26, 37, 42, 15, 60, 40, 43, 48, 30, 25, 52, 28, 41, 40, 34, 28, 41, 38, 40, 30, 35, 27, 27, 32, 44, 31],
    "Romans": [32, 29, 31, 25, 21, 23, 25, 39, 33, 21, 36, 21, 14, 23, 33, 27],
    "1 Corinthians": [31, 16, 23, 21, 13, 20, 40, 13, 27, 33, 34, 31, 13, 40, 58, 24],
    "2 Corinthians": [24, 17, 18, 18, 21, 18, 16, 24, 15, 18, 33, 21, 14],
    "Galatians": [24, 21, 29, 31, 26, 18],
    "Ephesians": [23, 22, 21, 32, 33, 24],
    "Philippians": [30, 30, 21, 23],
    "Colossians": [29, 23, 25, 18],
    "1 Thessalonians": [10, 20, 13, 18, 28],
    "2 Thessalonians": [12, 17, 18],
    "1 Timothy": [20, 15, 16, 16, 25, 21],
    "2 Timothy": [18, 26, 17, 22],
    "Titus": [16, 15, 15],
    "Philemon": [25],
    "Hebrews": [14, 18, 19, 16, 14, 20, 28, 13, 28, 39, 40, 29, 25],
    "James": [27, 26, 18, 17, 20],
    "1 Peter": [25, 25, 22, 19, 14],
    "2 Peter": [21, 22, 18],
    "1 John": [10, 29, 24, 21, 21],
    "2 John": [13],
    "3 John": [14],
    "Jude": [25],
    "Revelation": [20, 29, 22, 11, 14, 17, 17, 13, 21, 11, 19, 17, 18, 20, 8, 21, 18, 24, 21, 15, 27, 21]
  })
  // ---- Vulgate (Clementine Latin + Douay-Rheims, via bolls.life) ----
  // 66-book canon, bolls bookid = 1 + index. Verses-per-chapter follows
  // the Clementine Vulgate; Psalms use Vulgate (Septuagint) numbering,
  // so the Douay-Rheims chapter is remapped on fetch (see _drbPsalm).
  readonly property var vulgBooks: [
    "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy",
    "Joshua", "Judges", "Ruth", "1 Samuel", "2 Samuel",
    "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra",
    "Nehemiah", "Esther", "Job", "Psalms", "Proverbs",
    "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah", "Lamentations",
    "Ezekiel", "Daniel", "Hosea", "Joel", "Amos",
    "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk",
    "Zephaniah", "Haggai", "Zechariah", "Malachi", "Matthew",
    "Mark", "Luke", "John", "Acts", "Romans",
    "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians", "Philippians",
    "Colossians", "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy",
    "Titus", "Philemon", "Hebrews", "James", "1 Peter",
    "2 Peter", "1 John", "2 John", "3 John", "Jude",
    "Revelation"
  ]
  readonly property var vulgShape: ({
    "Genesis": [31, 25, 24, 26, 31, 22, 24, 22, 29, 32, 32, 20, 18, 24, 21, 16, 27, 33, 38, 18, 34, 24, 20, 67, 34, 35, 46, 22, 35, 43, 55, 32, 20, 31, 29, 43, 36, 30, 23, 23, 57, 38, 34, 34, 28, 34, 31, 22, 32, 25],
    "Exodus": [22, 25, 22, 31, 23, 30, 25, 32, 35, 29, 10, 51, 22, 31, 27, 36, 16, 27, 25, 26, 36, 31, 33, 18, 40, 37, 21, 43, 46, 38, 18, 35, 23, 35, 35, 38, 29, 31, 43, 36],
    "Leviticus": [17, 16, 17, 35, 19, 30, 38, 36, 24, 20, 47, 8, 59, 57, 33, 34, 16, 30, 37, 27, 24, 33, 44, 23, 55, 45, 34],
    "Numbers": [54, 34, 51, 49, 31, 27, 89, 26, 23, 36, 34, 15, 34, 45, 41, 50, 13, 32, 22, 30, 35, 41, 30, 25, 18, 65, 23, 31, 39, 17, 54, 42, 56, 29, 34, 13],
    "Deuteronomy": [46, 37, 29, 49, 33, 25, 26, 20, 29, 22, 32, 32, 18, 29, 23, 22, 20, 22, 21, 20, 23, 30, 25, 22, 19, 19, 26, 68, 29, 20, 30, 52, 29, 12],
    "Joshua": [18, 24, 17, 25, 16, 27, 26, 35, 27, 43, 23, 24, 33, 15, 63, 10, 18, 28, 51, 9, 43, 34, 16, 33],
    "Judges": [36, 23, 31, 24, 32, 40, 25, 35, 57, 18, 40, 15, 25, 20, 20, 31, 13, 31, 30, 48, 24],
    "Ruth": [22, 23, 18, 22],
    "1 Samuel": [28, 36, 21, 22, 12, 21, 17, 22, 27, 27, 15, 25, 23, 52, 35, 23, 58, 30, 24, 43, 15, 23, 28, 23, 44, 25, 12, 25, 11, 31, 13],
    "2 Samuel": [27, 32, 39, 12, 25, 23, 29, 18, 13, 19, 27, 31, 39, 33, 37, 23, 29, 33, 43, 26, 22, 51, 39, 25],
    "1 Kings": [53, 46, 28, 34, 18, 38, 51, 66, 28, 29, 43, 33, 34, 31, 34, 34, 24, 46, 21, 43, 29, 54],
    "2 Kings": [18, 25, 27, 44, 27, 33, 20, 29, 37, 36, 21, 21, 25, 29, 38, 20, 41, 37, 37, 21, 26, 20, 37, 20, 30],
    "1 Chronicles": [54, 55, 24, 43, 26, 81, 40, 40, 44, 14, 46, 40, 14, 17, 29, 43, 27, 17, 19, 7, 30, 19, 32, 31, 31, 32, 34, 21, 30],
    "2 Chronicles": [17, 18, 17, 22, 14, 42, 22, 18, 31, 19, 23, 16, 22, 15, 19, 14, 19, 34, 11, 37, 20, 12, 21, 27, 28, 23, 9, 27, 36, 27, 21, 33, 25, 33, 27, 23],
    "Ezra": [11, 70, 13, 24, 17, 22, 28, 36, 15, 44],
    "Nehemiah": [11, 20, 31, 23, 19, 19, 73, 18, 38, 39, 36, 46, 31],
    "Esther": [22, 23, 15, 17, 14, 14, 10, 17, 32, 13, 12, 6, 18, 19, 19, 24],
    "Job": [22, 13, 26, 21, 27, 30, 21, 22, 35, 22, 20, 25, 28, 22, 35, 23, 16, 21, 29, 29, 34, 30, 17, 25, 6, 14, 23, 28, 25, 31, 40, 22, 33, 37, 16, 33, 24, 41, 35, 28, 25, 16],
    "Psalms": [6, 13, 9, 10, 13, 11, 18, 10, 39, 8, 9, 6, 7, 5, 10, 15, 51, 15, 10, 14, 32, 6, 10, 22, 12, 14, 9, 11, 13, 25, 11, 22, 23, 28, 13, 40, 23, 14, 18, 14, 12, 5, 26, 18, 12, 10, 15, 21, 23, 21, 11, 7, 9, 24, 13, 12, 12, 18, 14, 9, 13, 12, 11, 14, 20, 8, 36, 37, 6, 24, 20, 28, 23, 11, 13, 21, 72, 13, 20, 17, 8, 19, 13, 14, 17, 7, 19, 53, 17, 16, 16, 5, 23, 11, 13, 12, 9, 9, 5, 8, 29, 22, 35, 45, 48, 43, 14, 31, 7, 10, 10, 9, 26, 9, 10, 2, 29, 176, 7, 8, 9, 4, 8, 5, 6, 5, 6, 8, 8, 3, 18, 3, 3, 21, 26, 9, 8, 24, 14, 10, 8, 12, 15, 21, 10, 11, 9, 14, 9, 6],
    "Proverbs": [33, 22, 35, 27, 23, 35, 27, 36, 18, 32, 31, 28, 25, 35, 33, 33, 28, 24, 29, 30, 31, 29, 35, 34, 28, 28, 27, 28, 27, 33, 31],
    "Ecclesiastes": [18, 26, 22, 17, 19, 11, 30, 17, 18, 20, 10, 14],
    "Song of Solomon": [16, 17, 11, 16, 17, 12, 13, 14],
    "Isaiah": [31, 22, 26, 6, 30, 13, 25, 22, 21, 34, 16, 6, 22, 32, 9, 14, 14, 7, 25, 6, 17, 25, 18, 23, 12, 21, 13, 29, 24, 33, 9, 20, 24, 17, 10, 22, 38, 22, 8, 31, 29, 25, 28, 28, 25, 13, 15, 22, 26, 11, 23, 15, 12, 17, 13, 12, 21, 14, 21, 22, 11, 12, 19, 12, 25, 24],
    "Jeremiah": [19, 37, 25, 31, 31, 30, 34, 22, 26, 25, 23, 17, 27, 22, 21, 21, 27, 23, 15, 18, 14, 30, 40, 10, 38, 24, 22, 17, 32, 24, 40, 44, 26, 22, 19, 32, 20, 28, 18, 16, 18, 22, 13, 30, 5, 28, 7, 47, 39, 46, 64, 34],
    "Lamentations": [22, 22, 66, 22, 22],
    "Ezekiel": [28, 9, 27, 17, 17, 14, 27, 18, 11, 22, 25, 28, 23, 23, 8, 63, 24, 32, 14, 49, 32, 31, 49, 27, 17, 21, 36, 26, 21, 26, 18, 32, 33, 31, 15, 38, 28, 23, 29, 49, 26, 20, 27, 31, 25, 24, 23, 35],
    "Daniel": [21, 49, 100, 34, 31, 28, 28, 27, 27, 21, 45, 13, 65, 42],
    "Hosea": [11, 24, 5, 19, 15, 11, 16, 14, 17, 15, 12, 14, 15, 10],
    "Joel": [20, 32, 21],
    "Amos": [15, 16, 15, 13, 27, 15, 17, 14, 15],
    "Obadiah": [21],
    "Jonah": [16, 11, 10, 11],
    "Micah": [16, 13, 12, 13, 14, 16, 20],
    "Nahum": [15, 13, 19],
    "Habakkuk": [17, 20, 19],
    "Zephaniah": [18, 15, 20],
    "Haggai": [14, 24],
    "Zechariah": [21, 13, 10, 14, 11, 15, 14, 23, 17, 12, 17, 14, 9, 21],
    "Malachi": [14, 17, 18, 6],
    "Matthew": [25, 23, 17, 25, 48, 34, 29, 34, 38, 42, 30, 50, 58, 36, 39, 28, 26, 35, 30, 34, 46, 46, 39, 51, 46, 75, 66, 20],
    "Mark": [45, 28, 35, 40, 43, 56, 37, 39, 49, 52, 33, 44, 37, 72, 47, 20],
    "Luke": [80, 52, 38, 44, 39, 49, 50, 56, 62, 42, 54, 59, 35, 35, 32, 31, 37, 43, 48, 47, 38, 71, 56, 53],
    "John": [51, 25, 36, 54, 47, 72, 53, 59, 41, 42, 56, 50, 38, 31, 27, 33, 26, 40, 42, 31, 25],
    "Acts": [26, 47, 26, 37, 42, 15, 59, 40, 43, 48, 30, 25, 52, 27, 41, 40, 34, 28, 40, 38, 40, 30, 35, 27, 27, 32, 44, 31],
    "Romans": [32, 29, 31, 25, 21, 23, 25, 39, 33, 21, 36, 21, 14, 23, 33, 27],
    "1 Corinthians": [31, 16, 23, 21, 13, 20, 40, 13, 27, 33, 34, 31, 13, 40, 58, 24],
    "2 Corinthians": [23, 17, 18, 18, 21, 18, 16, 24, 15, 18, 33, 21, 13],
    "Galatians": [24, 21, 29, 31, 26, 18],
    "Ephesians": [23, 22, 21, 32, 33, 24],
    "Philippians": [30, 30, 21, 23],
    "Colossians": [29, 23, 25, 18],
    "1 Thessalonians": [10, 20, 13, 18, 28],
    "2 Thessalonians": [12, 17, 18],
    "1 Timothy": [20, 15, 16, 16, 25, 21],
    "2 Timothy": [18, 26, 17, 22],
    "Titus": [16, 15, 15],
    "Philemon": [25],
    "Hebrews": [14, 18, 19, 16, 14, 20, 28, 13, 28, 39, 40, 29, 25],
    "James": [27, 26, 18, 17, 20],
    "1 Peter": [25, 25, 22, 19, 14],
    "2 Peter": [21, 22, 18],
    "1 John": [10, 29, 24, 21, 21],
    "2 John": [13],
    "3 John": [14],
    "Jude": [25],
    "Revelation": [20, 29, 22, 11, 14, 17, 17, 13, 21, 11, 19, 18, 18, 20, 8, 21, 18, 24, 21, 15, 27, 21]
  })

  // ---- Quran (Uthmani + Pickthall, via api.alquran.cloud) ----
  readonly property var surahNames: [
    "Al-Faatiha", "Al-Baqara", "Aal-i-Imraan", "An-Nisaa", "Al-Maaida", "Al-An'aam",
    "Al-A'raaf", "Al-Anfaal", "At-Tawba", "Yunus", "Hud", "Yusuf",
    "Ar-Ra'd", "Ibrahim", "Al-Hijr", "An-Nahl", "Al-Israa", "Al-Kahf",
    "Maryam", "Taa-Haa", "Al-Anbiyaa", "Al-Hajj", "Al-Muminoon", "An-Noor",
    "Al-Furqaan", "Ash-Shu'araa", "An-Naml", "Al-Qasas", "Al-Ankaboot", "Ar-Room",
    "Luqman", "As-Sajda", "Al-Ahzaab", "Saba", "Faatir", "Yaseen",
    "As-Saaffaat", "Saad", "Az-Zumar", "Ghafir", "Fussilat", "Ash-Shura",
    "Az-Zukhruf", "Ad-Dukhaan", "Al-Jaathiya", "Al-Ahqaf", "Muhammad", "Al-Fath",
    "Al-Hujuraat", "Qaaf", "Adh-Dhaariyat", "At-Tur", "An-Najm", "Al-Qamar",
    "Ar-Rahmaan", "Al-Waaqia", "Al-Hadid", "Al-Mujaadila", "Al-Hashr", "Al-Mumtahana",
    "As-Saff", "Al-Jumu'a", "Al-Munaafiqoon", "At-Taghaabun", "At-Talaaq", "At-Tahrim",
    "Al-Mulk", "Al-Qalam", "Al-Haaqqa", "Al-Ma'aarij", "Nooh", "Al-Jinn",
    "Al-Muzzammil", "Al-Muddaththir", "Al-Qiyaama", "Al-Insaan", "Al-Mursalaat", "An-Naba",
    "An-Naazi'aat", "Abasa", "At-Takwir", "Al-Infitaar", "Al-Mutaffifin", "Al-Inshiqaaq",
    "Al-Burooj", "At-Taariq", "Al-A'laa", "Al-Ghaashiya", "Al-Fajr", "Al-Balad",
    "Ash-Shams", "Al-Lail", "Ad-Dhuhaa", "Ash-Sharh", "At-Tin", "Al-Alaq",
    "Al-Qadr", "Al-Bayyina", "Az-Zalzala", "Al-Aadiyaat", "Al-Qaari'a", "At-Takaathur",
    "Al-Asr", "Al-Humaza", "Al-Fil", "Quraish", "Al-Maa'un", "Al-Kawthar",
    "Al-Kaafiroon", "An-Nasr", "Al-Masad", "Al-Ikhlaas", "Al-Falaq", "An-Naas"
  ]
  readonly property var surahAr: [
    "ٱلْفَاتِحَةِ", "البَقَرَةِ", "آلِ عِمۡرَانَ", "النِّسَاءِ", "المَائـِدَةِ", "الأَنۡعَامِ",
    "الأَعۡرَافِ", "الأَنفَالِ", "التَّوۡبَةِ", "يُونُسَ", "هُودٍ", "يُوسُفَ",
    "الرَّعۡدِ", "إِبۡرَاهِيمَ", "الحِجۡرِ", "النَّحۡلِ", "الإِسۡرَاءِ", "الكَهۡفِ",
    "مَرۡيَمَ", "طه", "الأَنبِيَاءِ", "الحَجِّ", "المُؤۡمِنُونَ", "النُّورِ",
    "الفُرۡقَانِ", "الشُّعَرَاءِ", "النَّمۡلِ", "القَصَصِ", "العَنكَبُوتِ", "الرُّومِ",
    "لُقۡمَانَ", "السَّجۡدَةِ", "الأَحۡزَابِ", "سَبَإٍ", "فَاطِرٍ", "يسٓ",
    "الصَّافَّاتِ", "صٓ", "الزُّمَرِ", "غَافِرٍ", "فُصِّلَتۡ", "الشُّورَىٰ",
    "الزُّخۡرُفِ", "الدُّخَانِ", "الجَاثِيَةِ", "الأَحۡقَافِ", "مُحَمَّدٍ", "الفَتۡحِ",
    "الحُجُرَاتِ", "قٓ", "الذَّارِيَاتِ", "الطُّورِ", "النَّجۡمِ", "القَمَرِ",
    "الرَّحۡمَٰن", "الوَاقِعَةِ", "الحَدِيدِ", "المُجَادلَةِ", "الحَشۡرِ", "المُمۡتَحنَةِ",
    "الصَّفِّ", "الجُمُعَةِ", "المُنَافِقُونَ", "التَّغَابُنِ", "الطَّلَاقِ", "التَّحۡرِيمِ",
    "المُلۡكِ", "القَلَمِ", "الحَاقَّةِ", "المَعَارِجِ", "نُوحٍ", "الجِنِّ",
    "المُزَّمِّلِ", "المُدَّثِّرِ", "القِيَامَةِ", "الإِنسَانِ", "المُرۡسَلَاتِ", "النَّبَإِ",
    "النَّازِعَاتِ", "عَبَسَ", "التَّكۡوِيرِ", "الانفِطَارِ", "المُطَفِّفِينَ", "الانشِقَاقِ",
    "البُرُوجِ", "الطَّارِقِ", "الأَعۡلَىٰ", "الغَاشِيَةِ", "الفَجۡرِ", "البَلَدِ",
    "الشَّمۡسِ", "اللَّيۡلِ", "الضُّحَىٰ", "الشَّرۡحِ", "التِّينِ", "العَلَقِ",
    "القَدۡرِ", "البَيِّنَةِ", "الزَّلۡزَلَةِ", "العَادِيَاتِ", "القَارِعَةِ", "التَّكَاثُرِ",
    "العَصۡرِ", "الهُمَزَةِ", "الفِيلِ", "قُرَيۡشٍ", "المَاعُونِ", "الكَوۡثَرِ",
    "الكَافِرُونَ", "النَّصۡرِ", "المَسَدِ", "الإِخۡلَاصِ", "الفَلَقِ", "النَّاسِ"
  ]
  readonly property var surahAyahs: [
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, 111, 110,
    98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73, 54, 45, 83,
    182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, 49, 62, 55,
    78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28,
    20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19, 26, 30, 20,
    15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3,
    6, 3, 5, 4, 5, 6
  ]

  // ---- corpus config -------------------------------------------------
  // Per-corpus constants the UI and fetch layer read through `cx`.
  readonly property var _corpora: ({
    "tanakh": {
      "label": "Tanakh", "defaultRef": "Genesis 1:1", "books": root.books,
      "nativeLabel": "Hebrew", "rtl": true, "unit": "chapter", "sub": "verse",
      "hasTrop": true, "hasVowels": true, "vowelLabel": "Niqqud",
      "c1": "MAM (CC BY-SA)", "c2": "JPS 1917 (public domain)", "host": "sefaria.org"
    },
    "nt": {
      "label": "New Testament", "defaultRef": "John 3:16", "books": root.ntBooks,
      "nativeLabel": "Greek", "rtl": false, "unit": "chapter", "sub": "verse",
      "hasTrop": false, "hasVowels": false, "vowelLabel": "",
      "c1": "Textus Receptus", "c2": "KJV (public domain)", "host": "bolls.life"
    },
    "vulgate": {
      "label": "Vulgate", "defaultRef": "Genesis 1:1", "books": root.vulgBooks,
      "nativeLabel": "Latin", "rtl": false, "unit": "chapter", "sub": "verse",
      "hasTrop": false, "hasVowels": false, "vowelLabel": "",
      "c1": "Clementine Vulgate", "c2": "Douay-Rheims (public domain)", "host": "bolls.life"
    },
    "quran": {
      "label": "Quran", "defaultRef": "Quran 1:1", "books": root.surahNames,
      "nativeLabel": "Arabic", "rtl": true, "unit": "surah", "sub": "ayah",
      "hasTrop": false, "hasVowels": true, "vowelLabel": "Tashkeel",
      "c1": "Uthmani", "c2": "Pickthall (public domain)", "host": "alquran.cloud"
    }
  })
  readonly property var cx: root._corpora[root.corpus] || root._corpora["tanakh"]
  readonly property var corpusOptions: ["Tanakh", "New Testament", "Vulgate", "Quran"]
  readonly property var _corpusKey: ({
    "Tanakh": "tanakh", "New Testament": "nt", "Vulgate": "vulgate", "Quran": "quran"
  })

  // A printer's ornament — a hairline broken by a small centred lozenge —
  // in place of the plain rules bracketing the passage.
  component OrnamentRule: RowLayout {
    Layout.fillWidth: true
    Layout.topMargin: Style.space(1)
    Layout.bottomMargin: Style.space(1)
    spacing: Style.space(9)
    Rectangle { Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; implicitHeight: 1; color: root.fg; opacity: 0.16 }
    Rectangle {
      Layout.alignment: Qt.AlignVCenter
      implicitWidth: Style.space(4); implicitHeight: Style.space(4)
      rotation: 45; antialiasing: true
      color: root.fg; opacity: 0.35
    }
    Rectangle { Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; implicitHeight: 1; color: root.fg; opacity: 0.16 }
  }

  // The "book" segment a bare ref carries in the current corpus. For the Quran
  // every ref is "Quran S:A", so the surah lives in the chapter slot.
  readonly property string _navBook: root.corpus === "quran"
    ? "Quran" : (root._navParts ? root._navParts.book : bookDrop.value)

  // The loaded reference as a human would name it — "Quran 2:255" reads as
  // "Al-Baqara 255"; the rest are already fine.
  readonly property string displayRef: {
    if (root.loadedRef === "") return ""
    if (root.corpus !== "quran") return root.loadedRef
    var p = root.refToParts(root.loadedRef)
    if (!p) return root.loadedRef
    var name = (p.chap >= 1 && p.chap <= 114) ? root.surahNames[p.chap - 1] : "Quran"
    return name + " " + p.vStart
  }

  // The bundled verses-per-chapter table for the current corpus, if it has
  // one (NT, Vulgate); the Quran and Tanakh are handled separately.
  function _bundledShape(book) {
    if (root.corpus === "nt") return root.ntShape[book]
    if (root.corpus === "vulgate") return root.vulgShape[book]
    return null
  }
  function chapCount(book) {
    if (root.corpus === "quran") return 114
    var t = root._bundledShape(book)
    if (t) return t.length || 1
    var sh = root._shapes[book]
    if (sh && sh.length) return sh.length
    return root.chapterCounts[book] || 150
  }
  function verseCount(book, chap) {
    if (root.corpus === "quran")
      return (chap >= 1 && chap <= 114) ? root.surahAyahs[chap - 1] : 0
    var t = root._bundledShape(book)
    if (t) return (chap >= 1 && chap <= t.length) ? t[chap - 1] : 0
    var sh = root._shapes[book]
    return (sh && chap >= 1 && chap <= sh.length) ? sh[chap - 1] : 0
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
  readonly property bool canGoBack: root._history.length > 0 && !root.loading

  // A ref that belongs to `corpus` — "Book C:V" in that corpus's book list
  // (for the Quran, "Quran S:A" with S in 1..114).
  function validRef(corpus, ref) {
    var p = root.refToParts(ref)
    if (!p) return false
    if (corpus === "quran") return p.book === "Quran" && p.chap >= 1 && p.chap <= 114
    if (corpus === "nt") return root.ntBooks.indexOf(p.book) >= 0
    if (corpus === "vulgate") return root.vulgBooks.indexOf(p.book) >= 0
    return root.books.indexOf(p.book) >= 0
  }

  // The last ref visited in each corpus, restored when you switch to it.
  function corpusRefFor(key) {
    var r = root.corpusRef ? root.corpusRef[key] : ""
    return (r && root.validRef(key, r)) ? String(r) : root._corpora[key].defaultRef
  }
  function rememberCorpusRef() {
    var m = {}
    for (var k in root.corpusRef) m[k] = root.corpusRef[k]
    m[root.corpus] = root.loadedRef !== "" ? root.loadedRef : root.ref
    root.corpusRef = m
  }

  // ---- settings -------------------------------------------------
  function loadSettings() {
    var s = root.settings || ({})
    if (s.corpus && root._corpora[s.corpus]) root.corpus = String(s.corpus)
    if (s.corpusRef && typeof s.corpusRef === "object") {
      var m = {}
      for (var k in s.corpusRef) {
        if (root._corpora[k] && root.validRef(k, s.corpusRef[k])) m[k] = String(s.corpusRef[k])
      }
      root.corpusRef = m
    }
    if (s.ref) root.ref = String(s.ref)
    // A stale / wrong-corpus ref shouldn't strand us.
    if (!root.validRef(root.corpus, root.ref)) root.ref = root.corpusRefFor(root.corpus)
    if (s.showRefInBar !== undefined) root.showRefInBar = s.showRefInBar !== false
    if (s.showHebrew !== undefined) root.showHebrew = s.showHebrew !== false
    if (s.showEnglish !== undefined) root.showEnglish = s.showEnglish !== false
    if (s.taamim !== undefined) root.heTaamim = s.taamim !== false
    if (s.niqqud !== undefined) root.heNiqqud = s.niqqud !== false
    if (s.hebrewFirst !== undefined) root.hebrewFirst = s.hebrewFirst !== false
    if (s.scale !== undefined) {
      var sc = parseFloat(s.scale)
      if (!isNaN(sc)) root.textScale = Math.max(0.75, Math.min(2.5, sc))
    }
  }

  function persistSettings() {
    root.rememberCorpusRef()
    var next = {
      corpus: root.corpus,
      ref: root.ref,
      corpusRef: root.corpusRef,
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
    var clamped = Math.max(0.75, Math.min(2.5, Math.round(v * 1000) / 1000))
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

  // The bare-ref book segment for a menu selection. Tanakh/NT: the book name
  // itself. Quran: the dropdown shows surah names but every ref is "Quran S:A".
  function _bookForRef(sel) {
    if (root.corpus === "quran") return "Quran"
    return sel
  }
  // The chapter number a menu selection maps to (Quran: the surah's number).
  function _chapForSelection(sel) {
    if (root.corpus === "quran") {
      var i = root.surahNames.indexOf(sel)
      return i >= 0 ? i + 1 : 1
    }
    return 1
  }

  function syncMenuFrom(reference) {
    var p = root.refToParts(reference)
    if (!p) return
    root.syncingMenu = true
    if (root.corpus === "quran") {
      if (p.chap >= 1 && p.chap <= 114) bookDrop.value = root.surahNames[p.chap - 1]
    } else if (root.cx.books.indexOf(p.book) !== -1) {
      bookDrop.value = p.book
    }
    root.selChap = p.chap
    root.selVerse = p.vStart
    root.syncingMenu = false
  }

  // Jump to a chapter / surah (verse 1). Clamped; no-op past the ends.
  function goToChapter(chap) {
    if (root.loading) return
    var book = root._navBook
    var c = Math.max(1, Math.min(root.chapCount(book), chap))
    if (root._navParts && c === root._navParts.chap) return
    root.load(book + " " + c + ":1", true)
  }
  function stepChapter(delta) { root.goToChapter((root._navParts ? root._navParts.chap : root.selChap) + delta) }

  // Back to verse 1 of the chapter/surah we're already in — the verse-number
  // tap target (goToChapter's same-chapter guard would swallow this).
  function goToVerseOne() {
    if (root.loading) return
    var chap = root._navParts ? root._navParts.chap : root.selChap
    root.load(root._navBook + " " + chap + ":1", true)
  }

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

  // bolls.life KJV carries <S>NNNN</S> Strong's tags and <i>…</i> italics.
  function stripBolls(s) {
    return root.stripHtml(String(s || "").replace(/<S>\d+<\/S>/g, "").replace(/<\/?i>/g, ""))
  }

  // The Uthmani edition prepends the 4-word Basmala to ayah 1 of every surah
  // but 1 & 9, where the English edition doesn't — drop those four words so
  // the two columns line up. (Its combining-mark order isn't stable enough to
  // match as a literal string.)
  function stripBasmala(s, surah) {
    var t = String(s || "").replace(/[\u200B-\u200F\u202A-\u202E\uFEFF]/g, "").trim()
    if (surah === 1 || surah === 9) return t
    var w = t.split(/\s+/)
    return w.length > 4 ? w.slice(4).join(" ") : t
  }

  function _arabicNum(n) {
    return String(n).replace(/[0-9]/g, function (d) { return String.fromCharCode(0x0660 + parseInt(d, 10)) })
  }

  // The original-language text as it should currently render: strip the
  // pointing the toggles say to hide. Kept out of the model so a toggle is
  // instant. Hebrew: te'amim + niqqud. Arabic: tashkeel. Greek: nothing.
  function renderHe(raw) {
    var t = root.stripHtml(raw)
    if (root.corpus === "nt" || root.corpus === "vulgate") return t
    if (root.corpus === "quran") {
      // Arabic harakat + Quranic annotation signs.
      if (!root.heNiqqud)
        t = t.replace(/[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8\u06EA-\u06ED\u08D3-\u08FF]/g, "")
      return t
    }
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

  function _entry(he, en, startVerse, loadedRef, heRef) {
    return {
      "he": he, "en": en, "startVerse": startVerse,
      "loadedRef": loadedRef, "heRef": heRef,
      "count": Math.max(he.length, en.length)
    }
  }

  // Parse a raw fetch response into the common entry shape, per corpus.
  // `reqRef` is the reference asked for — the bolls / AlQuran APIs don't
  // echo a canonical ref the way Sefaria does. Takes the raw text so a
  // corpus can use its own wire format (the Vulgate Psalms path glues two
  // chapter responses together with a separator, which isn't JSON).
  function buildEntryFor(rawText, reqRef) {
    var t = String(rawText || "").trim()
    if (t === "") return { "error": "No answer from " + root._sourceName + "." }

    var p = root.refToParts(reqRef)
    if (root.corpus === "vulgate" && p && p.book === "Psalms") {
      var halves = t.split("<<SEP>>")   // written between the two --next fetches
      if (halves.length < 2) return { "error": "Couldn't read the Psalm from bolls.life." }
      try {
        return root._buildEntryBolls([JSON.parse(halves[0]), JSON.parse(halves[1])], reqRef)
      } catch (e1) { return { "error": "Couldn't read the Psalm from bolls.life." } }
    }

    var data
    try { data = JSON.parse(t) }
    catch (e) { return { "error": "Could not read the reply from " + root._sourceName + "." } }
    if (root.corpus === "nt" || root.corpus === "vulgate") return root._buildEntryBolls(data, reqRef)
    if (root.corpus === "quran") return root._buildEntryQuran(data, reqRef)
    return root.buildEntry(data)
  }

  // Sefaria API v3.
  function buildEntry(data) {
    if (data && data.error) return { "error": String(data.error) }
    var he = [], en = []
    var list = (data && data.versions) || []
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
    return root._entry(he, en, startVerse, String(data.ref || ""), String(data.heRef || ""))
  }

  // bolls responses -> [ [original verses…], [English verses…] ]. NT and most
  // of the Vulgate come from /get-paralel-verses/ (only the requested verses);
  // Vulgate Psalms come as two whole-chapter /get-text/ arrays wrapped in one
  // JSON array (the numbering differs, so the DRB chapter is fetched
  // separately). Either way: pair the two sides up by verse number and keep
  // only what the reference asked for.
  readonly property string _bollsEnglish: root.corpus === "vulgate" ? "DRB" : "KJV"
  function _buildEntryBolls(data, reqRef) {
    if (!Array.isArray(data) || data.length < 2) return { "error": "Nothing here for that reference." }
    var a = data[0] || [], b = data[1] || []
    var orig = a, eng = b
    if (a.length && a[0] && a[0].translation === root._bollsEnglish) { orig = b; eng = a }

    var p = root.refToParts(reqRef)
    var lo = p ? p.vStart : 1
    var hi = (p && p.vEnd !== 0) ? p.vEnd : 100000
    function collect(arr) {
      var by = {}
      for (var i = 0; i < arr.length; i++) by[arr[i].verse] = root.stripBolls(String(arr[i].text || ""))
      var res = []
      for (var v = lo; v <= hi; v++) { if (by[v] === undefined) break; res.push(by[v]) }
      return res
    }
    var he = collect(orig), en = collect(eng)
    if (he.length === 0 && en.length === 0) return { "error": "Nothing here for that reference." }
    return root._entry(he, en, lo, reqRef, "")
  }

  // api.alquran.cloud: whole surah -> data.data = [ed, ed] each with .ayahs;
  // single ayah -> data.data = [ed, ed] each a bare ayah object.
  function _buildEntryQuran(data, reqRef) {
    var eds = (data && data.data) || []
    if (data && data.status && data.status !== "OK") return { "error": String(data.status) }
    if (eds.length < 2) return { "error": "Nothing here for that reference." }
    var ar = eds[0], tr = eds[1]
    if (ar.edition && String(ar.edition.identifier || "").indexOf("uthmani") < 0) { ar = eds[1]; tr = eds[0] }
    var p = root.refToParts(reqRef)
    var surah = p ? p.chap : 1
    var he = [], en = [], startVerse = p ? p.vStart : 1
    if (Array.isArray(ar.ayahs)) {                 // whole surah
      he = ar.ayahs.map(function (x) { return String(x.text || "") })
      en = tr.ayahs.map(function (x) { return String(x.text || "") })
      startVerse = (ar.ayahs[0] && ar.ayahs[0].numberInSurah) || 1
    } else {                                       // single ayah
      he = [String(ar.text || "")]
      en = [String(tr.text || "")]
      startVerse = ar.numberInSurah || startVerse
    }
    if (startVerse === 1 && he.length) he[0] = root.stripBasmala(he[0], surah)
    var heRef = (surah >= 1 && surah <= 114)
      ? (root.surahAr[surah - 1] + " " + root._arabicNum(startVerse)) : ""
    return root._entry(he, en, startVerse, reqRef, heRef)
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

  // The reader page for a reference on the corpus's own site.
  //   Tanakh -> sefaria.org/Song_of_Songs.3.2   NT -> bolls.life/KJV/43/3/#16
  //   Vulgate -> bolls.life/DRB/1/1/           Quran -> quran.com/2/255
  function sourceUrl(reference) {
    var p = root.refToParts(reference)
    if (root.corpus === "quran")
      return p ? ("https://quran.com/" + p.chap + "/" + p.vStart) : "https://quran.com"
    if (root.corpus === "nt" || root.corpus === "vulgate") {
      var tr = root._bollsEnglish
      if (!p) return "https://bolls.life/" + tr + "/"
      return "https://bolls.life/" + tr + "/" + root._bollsBookId(p.book) + "/" + p.chap + "/"
        + (p.vEnd !== 0 ? "#" + p.vStart : "")
    }
    if (!p) return "https://www.sefaria.org/texts/Tanakh"
    var seg = p.book.replace(/ /g, "_") + "." + p.chap
    if (p.vEnd !== 0) {
      seg += "." + p.vStart
      if (p.vEnd > p.vStart) seg += "-" + p.vEnd
    }
    return "https://www.sefaria.org/" + encodeURI(seg)
  }

  // Open the current passage on the source site in the default browser. Routed
  // through a login shell (like Omarchy's own Util.execArgv) so xdg-open
  // inherits the session PATH; `exec "$@"` keeps the URL a literal arg.
  function openSource() {
    var url = root.sourceUrl(root.loadedRef !== "" ? root.loadedRef : root.ref)
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash", "xdg-open", url])
  }

  // ---- load -----------------------------------------------
  // bolls.life book id. NT books sit at 40-66; the Vulgate spans 1-66.
  function _bollsBookId(book) {
    if (root.corpus === "vulgate") {
      var vi = root.vulgBooks.indexOf(book)
      return vi >= 0 ? vi + 1 : 1
    }
    var i = root.ntBooks.indexOf(book)
    return i >= 0 ? 40 + i : 40
  }

  // The Vulgate (Septuagint) Psalm number → the Douay-Rheims (Masoretic) one
  // bolls serves it under. Off by one through most of the Psalter; the few
  // split/merge psalms land on their first Masoretic half.
  function _drbPsalm(v) {
    if (v <= 8) return v
    if (v === 9) return 9
    if (v <= 112) return v + 1
    if (v === 113) return 114
    if (v === 114 || v === 115) return 116
    if (v <= 145) return v + 1
    if (v === 146 || v === 147) return 147
    return v
  }

  function curlFor(reference) {
    var p = root.refToParts(reference)

    // Vulgate Psalms: the Latin and the Douay-Rheims are numbered differently,
    // so fetch each chapter on its own and wrap the two arrays as one JSON.
    if (root.corpus === "vulgate" && p && p.book === "Psalms") {
      var uV = "https://bolls.life/get-text/VULG/19/" + p.chap + "/"
      var uD = "https://bolls.life/get-text/DRB/19/" + root._drbPsalm(p.chap) + "/"
      return ["curl", "-fsS", "--max-time", "12", uV,
        "-w", "<<SEP>>", "--next", "-fsS", "--max-time", "12", uD]
    }

    if (root.corpus === "nt" || root.corpus === "vulgate") {
      var vs = []
      if (p && p.vEnd === 0) {
        var n = root.verseCount(p.book, p.chap) || 60
        for (var i = 1; i <= n; i++) vs.push(i)
      } else if (p) {
        for (var v = p.vStart; v <= p.vEnd; v++) vs.push(v)
      }
      var pair = root.corpus === "vulgate" ? ["VULG", "DRB"] : ["TR", "KJV"]
      var body = JSON.stringify({
        "translations": pair, "verses": vs,
        "book": root._bollsBookId(p ? p.book : root.cx.books[0]), "chapter": p ? p.chap : 1
      })
      return ["curl", "-fsSL", "--max-time", "12", "-X", "POST",
        "https://bolls.life/get-paralel-verses/",
        "-H", "Content-Type: application/json", "-d", body]
    }
    if (root.corpus === "quran") {
      var eds = "quran-uthmani,en.pickthall"
      if (p && p.vEnd === 0)
        return ["curl", "-fsSL", "--max-time", "12",
          "https://api.alquran.cloud/v1/surah/" + p.chap + "/editions/" + eds]
      return ["curl", "-fsSL", "--max-time", "12",
        "https://api.alquran.cloud/v1/ayah/" + (p ? p.chap : 1) + ":" + (p ? p.vStart : 1)
          + "/editions/" + eds]
    }
    return ["curl", "-fsSL", "--max-time", "12", "-G",
      "https://www.sefaria.org/api/v3/texts/" + encodeURIComponent(reference),
      "--data-urlencode", "version=" + root.englishVersion,
      "--data-urlencode", "version=hebrew"]
  }

  // Switch corpus. Each corpus keeps its own place: stash where we are, drop
  // the navigation context (history, random pool, in-flight fetches — those
  // hold refs meaningless in the other corpus), then restore that corpus's
  // last reference. The verse / shape caches are keyed by disjoint ref names
  // across corpora, so they stay warm and switching back is instant.
  function setCorpus(key) {
    if (key === root.corpus || !root._corpora[key]) return
    root.flushPersist()
    root.rememberCorpusRef()
    if (fetchProc.running) fetchProc.running = false
    if (prefetchProc.running) prefetchProc.running = false
    root._prefetchQueue = []; root._prefetchActive = ""
    root._randomPool = []; root._randomTries = 0
    root._history = []; root._restoringHistory = false
    root.verses = []
    root.loadedRef = ""; root.loadedHeRef = ""; root.pendingRef = ""; root.errorText = ""
    root.corpus = key
    root.ref = root.corpusRefFor(key)
    root.syncMenuFrom(root.ref)
    root.load(root.ref, true)
    randomFillTimer.restart()
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
    var newRef = entry.loadedRef || requestedRef
    // Push the passage we're leaving onto the back-stack, unless this load
    // *is* a Back navigation (or the very first one).
    if (root._restoringHistory) {
      root._restoringHistory = false
    } else if (root.loadedRef !== "" && root.normKey(root.loadedRef) !== root.normKey(newRef)) {
      var h = root._history.slice()
      h.push(root.loadedRef)
      while (h.length > 50) h.shift()
      root._history = h
    }
    root.errorText = entry.count > 120
      ? ("Showing the first 120 of " + entry.count + " " + root.cx.sub + "s.") : ""
    root.verses = root.buildRows(entry.he, entry.en, entry.startVerse)
    root.loadedRef = newRef
    root.loadedHeRef = entry.heRef
    root.ref = root.loadedRef
    root.syncMenuFrom(root.loadedRef)
    root.ensureShape(root.bookOf(root.loadedRef))
    if (remember) root.persistSettings()
    prefetchTimer.restart()
  }

  readonly property int _randomPoolTarget: 4

  // A random ref inside the current corpus. Tanakh uses Sefaria's random
  // endpoint (async, elsewhere); the rest we can pick locally from a table.
  function localRandomRef() {
    if (root.corpus === "nt" || root.corpus === "vulgate") {
      var list = root.corpus === "vulgate" ? root.vulgBooks : root.ntBooks
      var table = root.corpus === "vulgate" ? root.vulgShape : root.ntShape
      var b = list[Math.floor(Math.random() * list.length)]
      var t = table[b]
      var c = 1 + Math.floor(Math.random() * t.length)
      var v = 1 + Math.floor(Math.random() * t[c - 1])
      return b + " " + c + ":" + v
    }
    if (root.corpus === "quran") {
      var s = 1 + Math.floor(Math.random() * 114)
      var a = 1 + Math.floor(Math.random() * root.surahAyahs[s - 1])
      return "Quran " + s + ":" + a
    }
    return ""
  }

  function loadRandom() {
    if (root.loading) return
    root._randomTries = 0
    if (root._randomPool.length > 0) {
      root.load(root._randomPool.shift(), true)
    } else if (root.corpus === "tanakh") {
      root.loading = true
      root.errorText = ""
      randomNowProc.running = true
    } else {
      root.load(root.localRandomRef(), true)
    }
    // Refill straight away so the next Random is ready, not just eventually.
    randomFillTimer.restart()
  }

  function fillRandomPool() {
    if (root._randomPool.length >= root._randomPoolTarget) return
    if (root.corpus === "tanakh") {
      if (randomRefProc.running || root._randomTries >= 8) return
      randomRefProc.running = true
      return
    }
    // NT / Quran: fill locally, and queue each for a content prefetch.
    var guard = 0
    while (root._randomPool.length < root._randomPoolTarget && guard++ < 20) {
      var rr = root.localRandomRef()
      if (rr === "" || root._randomPool.indexOf(rr) >= 0) continue
      root._randomPool.push(rr)
      if (!root._cache[root.normKey(rr)] && root._prefetchQueue.indexOf(rr) < 0)
        root._prefetchQueue.push(rr)
    }
    root.pumpPrefetch()
  }

  // ---- shapes (chapter / verse counts) ---------------------
  // Only the Tanakh needs a live shape fetch; NT and Quran ship full tables.
  function ensureShape(book) {
    if (root.corpus !== "tanakh") return
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
  readonly property string _sourceName: root.cx.host

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var entry = root.buildEntryFor(text, root.pendingRef)
        if (entry.error) { root.loading = false; root.errorText = String(entry.error); return }
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
          ? root._sourceName + " doesn't recognise “" + root.pendingRef + "”."
          : "Could not reach " + root._sourceName + "."
      }
    }
  }

  Process {
    id: prefetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var e = root.buildEntryFor(text, root._prefetchActive)
          if (e && !e.error && (e.he.length > 0 || e.en.length > 0)) {
            root.cachePut(root._prefetchActive, e)
            if (e.loadedRef) root.cachePut(e.loadedRef, e)
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
      var label = root.displayRef !== "" ? root.displayRef : root.ref
      return (root.showRefInBar && label !== "") ? (root.barIcon + "  " + label) : root.barIcon
    }
    tooltipText: (root.displayRef !== "" ? root.displayRef + "  —  " : "")
      + "left-click to open · middle-click for a random passage"
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
    // Drop the card under the bar icon, not the screen centre. KeyboardPanel
    // then clamps it to `margin` from either screen edge, so an icon parked
    // in a corner still opens a fully-visible card.
    centerOnBar: false
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
      blocked: bookDrop.popupOpen || corpusDrop.popupOpen
      onCloseRequested: root.close()
      // h / l (← / →) walk verses; j / k (↑ / ↓) scroll a long passage.
      onMoveRequested: function(dx, dy) {
        if (dx > 0) root.step(1)
        else if (dx < 0) root.step(-1)
        else if (dy !== 0) root.scrollVerses(dy)
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.loadRandom()
        else if (t === "b" || t === "B") root.goBack()
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

        // ---- header: English reference on the left, Hebrew on the right,
        // matched in size, weight and colour, no fade. The activity indicator
        // sits centred between them while a passage loads.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            id: headerRef
            Layout.alignment: Qt.AlignVCenter
            Layout.maximumWidth: Style.space(230)
            textFormat: Text.PlainText
            text: root.displayRef !== "" ? root.displayRef : "Verse"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          // Loading indicator: three accent dots breathing in sequence,
          // centred between the two references. Subtle; nothing below shifts.
          Item {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: Style.space(6)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(4)
              opacity: root.loading ? 1 : 0
              visible: opacity > 0.01
              Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

              Repeater {
                model: 3
                delegate: Rectangle {
                  id: dot
                  required property int index
                  width: Style.space(5)
                  height: Style.space(5)
                  radius: width / 2
                  color: Color.accent
                  opacity: 0.25
                  SequentialAnimation on opacity {
                    running: root.loading
                    loops: Animation.Infinite
                    PauseAnimation { duration: dot.index * 150 }
                    NumberAnimation { from: 0.25; to: 0.95; duration: 400; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.95; to: 0.25; duration: 400; easing.type: Easing.InOutSine }
                    PauseAnimation { duration: (2 - dot.index) * 150 }
                  }
                }
              }
            }
          }

          Text {
            id: headerHeRef
            Layout.alignment: Qt.AlignVCenter
            Layout.maximumWidth: Style.space(230)
            visible: root.loadedHeRef !== ""
            textFormat: Text.PlainText
            text: root.loadedHeRef
            color: root.fg
            font.family: root.nativeFont
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }
        }

        // ---- corpus + book / surah
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          // Three options — a plain dropdown, not the searchable one (whose
          // popup reserves a minimum height and looks half-empty here).
          Dropdown {
            id: corpusDrop
            Layout.preferredWidth: Style.space(150)
            showLabel: false
            value: root.cx.label
            options: root.corpusOptions
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fontFamily
            onChanged: function(v) {
              if (root.syncingMenu) return
              root.setCorpus(root._corpusKey[v] || "tanakh")
            }
            onHovered: function(h) { if (h) keyCatcher.forceActiveFocus() }
          }

          SearchableDropdown {
            id: bookDrop
            Layout.fillWidth: true
            showLabel: false
            value: "Genesis"
            options: root.cx.books
            placeholderText: root.corpus === "quran" ? "Find a surah…" : "Find a book…"
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fontFamily
            onChanged: function(v) {
              if (root.syncingMenu) return
              if (root.corpus === "quran") {
                var n = root.surahNames.indexOf(v)
                if (n >= 0) root.load("Quran " + (n + 1) + ":1", true)
              } else {
                root.ensureShape(v)
                root.load(v + " 1:1", true)
              }
            }
            onHovered: function(h) { if (h) keyCatcher.forceActiveFocus() }
          }
        }

        // ---- chapter / verse steppers + random
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          RowLayout {
            spacing: Style.space(3)
            Text {
              text: root.cx.unit.toUpperCase()
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
              tooltipText: "Previous " + root.cx.unit + "  ( [ )"
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.stepChapter(-1)
              Behavior on opacity { NumberAnimation { duration: 140 } }
            }
            Text {
              id: chapNum
              // Tap to jump to chapter 1 — live only when we're not there,
              // like A− / A+ going inert at the zoom limits.
              readonly property bool resettable: root.selChap > 1 && !root.loading
              text: root.selChap
              color: (chapNumHover.hovered && chapNum.resettable) ? Color.accent : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              Layout.preferredWidth: Style.space(24)
              Layout.alignment: Qt.AlignVCenter

              HoverHandler {
                id: chapNumHover
                enabled: chapNum.resettable
                cursorShape: Qt.PointingHandCursor
              }
              TapHandler { enabled: chapNum.resettable; onTapped: root.goToChapter(1) }
              PanelToolTip {
                visible: chapNumHover.hovered && chapNum.resettable
                text: "Jump to " + root.cx.unit + " 1"
                panelForeground: root.fg
                fontFamily: root.fontFamily
              }
            }
            Button {
              text: "›"
              foreground: root.fg
              enabled: root.canNextChap
              opacity: enabled ? 1.0 : 0.25
              tooltipText: "Next " + root.cx.unit + "  ( ] )"
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
              text: root.cx.sub.toUpperCase()
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
              tooltipText: "Previous " + root.cx.sub + "  ( h )"
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.step(-1)
              Behavior on opacity { NumberAnimation { duration: 140 } }
            }
            Text {
              id: verseNum
              // Tap to jump to verse 1 of this chapter — live only when past it.
              readonly property bool resettable: root.selVerse > 1 && !root.loading
              text: root.selVerse
              color: (verseNumHover.hovered && verseNum.resettable) ? Color.accent : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              Layout.preferredWidth: Style.space(24)
              Layout.alignment: Qt.AlignVCenter

              HoverHandler {
                id: verseNumHover
                enabled: verseNum.resettable
                cursorShape: Qt.PointingHandCursor
              }
              TapHandler { enabled: verseNum.resettable; onTapped: root.goToVerseOne() }
              PanelToolTip {
                visible: verseNumHover.hovered && verseNum.resettable
                text: "Jump to " + root.cx.sub + " 1"
                panelForeground: root.fg
                fontFamily: root.fontFamily
              }
            }
            Button {
              text: "›"
              foreground: root.fg
              enabled: root.canNextVerse
              opacity: enabled ? 1.0 : 0.25
              tooltipText: "Next " + root.cx.sub + "  ( l )"
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
            text: "‹ Back"
            foreground: root.fg
            enabled: root.canGoBack
            opacity: enabled ? 1.0 : 0.25
            tooltipText: "Return to the previous passage  (b)"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.goBack()
            Behavior on opacity { NumberAnimation { duration: 140 } }
          }

          Button {
            text: "Random"
            foreground: root.fg
            enabled: !root.loading
            tooltipText: "A random passage from the " + root.cx.label + "  (r)"
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
          text: "h l  " + root.cx.sub + "    j k  scroll    [ ]  " + root.cx.unit
            + "    r  random    b  back    s  swap"
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
            text: root.cx.nativeLabel
            foreground: root.fg
            active: root.showHebrew
            tooltipText: "Show the " + root.cx.nativeLabel + " text"
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
            tooltipText: "Show the " + root.cx.c2.replace(" (public domain)", "") + " translation"
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
            tooltipText: root.hebrewFirst
              ? "Put English on top" : "Put the " + root.cx.nativeLabel + " on top"
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.hebrewFirst = !root.hebrewFirst; root.persistSoon() }
          }

          Rectangle {
            Layout.alignment: Qt.AlignVCenter
            visible: root.cx.hasTrop || root.cx.hasVowels
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
            visible: root.cx.hasTrop
            tooltipText: "Cantillation marks (te'amim)"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.heTaamim = !root.heTaamim; root.persistSoon() }
          }

          Button {
            text: root.cx.vowelLabel
            foreground: root.fg
            active: root.heNiqqud
            enabled: root.showHebrew
            visible: root.cx.hasVowels
            tooltipText: root.corpus === "quran" ? "Vowel marks (tashkeel)" : "Vowel points"
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
            enabled: root.textScale < 2.5
            tooltipText: "Bigger"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.setScale(root.textScale + 0.125)
          }
        }

        OrnamentRule {}

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
          text: "Both " + root.cx.nativeLabel + " and English are hidden."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // The passage, given a little age: a faint paper grain behind the
        // text, and a soft fade where it meets the top and bottom edges,
        // like a leaf in a bound book.
        Item {
          id: versesArea
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(versesCol.implicitHeight, Style.space(380))
          visible: root.verses.length > 0 && (root.showHebrew || root.showEnglish)
          clip: true

          Canvas {
            id: grain
            // Oversized so the slow drift never exposes an edge.
            anchors.fill: parent
            anchors.margins: -Style.space(12)
            opacity: 1.0
            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var n = Math.floor(width * height / 14)
              for (var i = 0; i < n; i++) {
                ctx.fillStyle = (i % 2)
                  ? "rgba(0,0,0,0.10)" : "rgba(255,255,255,0.09)"
                ctx.fillRect(Math.random() * width, Math.random() * height,
                             Math.random() < 0.78 ? 1 : 2, 1)
              }
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()

            // Film-grain boil: re-scatter the speckle a few times a second so
            // the texture is visibly alive, over a very slow two-axis drift.
            Timer {
              running: grain.visible
              interval: 260
              repeat: true
              onTriggered: grain.requestPaint()
            }
            transform: Translate { id: grainDrift }
            SequentialAnimation {
              running: grain.visible
              loops: Animation.Infinite
              NumberAnimation { target: grainDrift; property: "x"; from: -7; to: 7; duration: 43000; easing.type: Easing.InOutSine }
              NumberAnimation { target: grainDrift; property: "x"; from: 7; to: -7; duration: 43000; easing.type: Easing.InOutSine }
            }
            SequentialAnimation {
              running: grain.visible
              loops: Animation.Infinite
              NumberAnimation { target: grainDrift; property: "y"; from: 6; to: -6; duration: 57000; easing.type: Easing.InOutSine }
              NumberAnimation { target: grainDrift; property: "y"; from: -6; to: 6; duration: 57000; easing.type: Easing.InOutSine }
            }
          }

        Flickable {
          id: versesFlick
          anchors.fill: parent
          contentWidth: width
          contentHeight: versesCol.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          // Settle the text in on every change of passage — a short fade
          // plus a small upward drift. Noticeable, not sluggish.
          Connections {
            target: root
            function onVersesChanged() {
              // A new passage starts at its beginning, not wherever the last
              // one was scrolled to.
              scrollAnim.stop()
              versesFlick.contentY = 0
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
                required property int index
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
                  font.family: root.nativeFont
                  font.pixelSize: Math.round(Style.font.display * root.textScale)
                  horizontalAlignment: root.cx.rtl ? Text.AlignRight : Text.AlignLeft
                  // Arabic tashkeel reaches well above the line; Greek and
                  // Latin need less air than pointed Hebrew.
                  lineHeight: root.corpus === "quran" ? 1.9
                    : (root.corpus === "nt" || root.corpus === "vulgate") ? 1.4 : 1.5
                  // Keep the first line's high marks (Arabic tashkeel, Hebrew
                  // te'amim) off the clipped top edge.
                  topPadding: (verseBlock.index === 0 && root.hebrewFirst
                    && (root.corpus === "quran" || root.corpus === "tanakh"))
                    ? Math.round((root.corpus === "quran" ? 8 : 5) * root.textScale) : 0
                  wrapMode: Text.WordWrap
                }

                // English. The opening verse of a single-verse passage gets
                // an enlarged initial, set in Cardo — an old book's versal.
                RowLayout {
                  id: enRow
                  Layout.fillWidth: true
                  Layout.row: root.hebrewFirst ? 1 : 0
                  Layout.column: 0
                  visible: root.showEnglish && verseBlock.modelData.en !== ""
                  spacing: 0

                  readonly property bool dropCap: verseBlock.index === 0
                    && root.verses.length === 1
                    && /^[A-Za-z]/.test(String(verseBlock.modelData.en))

                  Text {
                    visible: enRow.dropCap
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: Math.round(1 * root.textScale)
                    Layout.rightMargin: Math.round(2 * root.textScale)
                    textFormat: Text.PlainText
                    text: String(verseBlock.modelData.en).charAt(0)
                    color: Qt.darker(root.fg, 1.1)
                    font.family: root.hebrewFont
                    font.pixelSize: Math.round(Style.font.body * root.textScale * 2.35)
                    lineHeight: 0.86
                  }

                  Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    textFormat: Text.PlainText
                    text: enRow.dropCap
                      ? String(verseBlock.modelData.en).slice(1)
                      : ((root.verses.length > 1 ? (verseBlock.modelData.num + " ") : "")
                         + verseBlock.modelData.en)
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
          }

          // The passage meets the edges softly, not with a hard cut.
          Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: Style.space(11)
            gradient: Gradient {
              GradientStop { position: 0.0; color: Color.popups.background }
              GradientStop { position: 1.0; color: "transparent" }
            }
          }
          Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: Style.space(11)
            gradient: Gradient {
              GradientStop { position: 0.0; color: "transparent" }
              GradientStop { position: 1.0; color: Color.popups.background }
            }
          }
        }

        OrnamentRule {}

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(16)

          Text {
            textFormat: Text.PlainText
            text: root.cx.c1
            color: Qt.darker(root.fg, 2.4)
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * 0.9)
            font.letterSpacing: 0.3
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: root.cx.c2
            color: Qt.darker(root.fg, 2.4)
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * 0.9)
            font.letterSpacing: 0.3
            elide: Text.ElideRight
          }

          // Opens the current passage on the source site in the browser.
          Text {
            id: sefariaLink
            textFormat: Text.PlainText
            text: root.cx.host
            color: sefariaLinkHover.hovered ? root.fg : Qt.darker(root.fg, 1.9)
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * 0.9)
            font.letterSpacing: 0.3
            font.underline: sefariaLinkHover.hovered

            HoverHandler { id: sefariaLinkHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.openSource() }
            PanelToolTip {
              visible: sefariaLinkHover.hovered
              text: "Open this passage on " + root.cx.host
              panelForeground: root.fg
              fontFamily: root.fontFamily
            }
          }

          Item { Layout.fillWidth: true }
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

  // Pop the back-stack and reload that passage. `_restoringHistory` keeps
  // `applyEntry` from pushing the passage we're leaving back onto the stack.
  function goBack() {
    if (root.loading || root._history.length === 0) return
    var h = root._history.slice()
    var prev = h.pop()
    root._history = h
    root._restoringHistory = true
    root.load(prev, true)
  }
}
