<p align="right">
  <a href="https://ko-fi.com/kommermail"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Support me on Ko-fi" height="30"></a>
</p>

# ProxyPrintGenerator

Print playtest proxies of your decks on a home printer. Paste a deck list or open a `.txt` file, choose the printing for each card, and get print-ready Letter sheets. Each sheet holds nine cards at true size, with a border-color bleed and dotted cutting guides. You can save the result as a PDF, PNG or JPEG, or print it straight from the app.

The look is embossed forest leather with a fuzzy suede panel, holographic plaques and gold lettering.

## Download

Get the latest `ProxyPrintGenerator-…-win-x64.zip` from **[Releases](../../releases)**, unzip it, and run `ProxyPrintGenerator.exe`. It runs on Windows 10 or 11, 64-bit, and needs nothing installed. The first time you run it, Windows SmartScreen may warn you because the app isn't code-signed. Click **More info → Run anyway**.

## Features

- **Deck Library**
  - Save decks.
  - Browse every card face: click to flip, double-click to zoom.
  - Swap printings, replace cards (and undo), and edit quantities.
  - Add cards through a Scryfall search.
- **Quick Build**: paste a list and build it, with nothing saved.
- **Print settings**
  - Scale: 300, 600, 1200 or 1800 dpi.
  - Cutting guides, regular or thick.
  - Shuffle the deck, with the commander kept first.
  - Shift up, extra gap, max gap, and a Canon safe area.
  - Low-ink calibration, vibrance and midtone lift.
- **Print sheet**
  - Always prints at actual size, with a page preview.
  - Choose the printer, copies and page range.
  - The driver's own quality and paper type lists, plus your printer's full Preferences window.
  - One-click paper presets: Plain, Canon Matte Photo, Photo Paper Plus Glossy II, and Glossy.
  - Warns if your printer can't reach a card edge.
- **Formats**
  - PDF: each unique face is stored once.
  - PNG: one tall image, verified after writing.
  - JPEG: one tall image.
  - Changing the format after a build renders again automatically.

## Build from source

You need the [.NET 10 SDK](https://dotnet.microsoft.com/download).

```
dotnet run --project ProxyPrintGenerator.csproj
```

To package a release (one self-contained exe plus a zip in `..\release\`):

```
powershell -ExecutionPolicy Bypass -File publish.ps1
```

For a headless build:

```
ProxyPrintGenerator.exe --build deck.txt out.pdf [1|2|4|6] [pdf|png|jpeg]
```

## Where things live

| What | Where |
|---|---|
| Saved decks | `%APPDATA%\ProxyPrintGenerator\decks.json` (set `PPG_DATA_DIR` to use another folder) |
| Last printer and paper | `%APPDATA%\ProxyPrintGenerator\print.json` |
| Image caches | `%LOCALAPPDATA%\ProxyPrintGenerator\` (safe to delete) |
| Finished builds | `Documents\ProxyPrintGenerator\` |

## Made with AI

ProxyPrintGenerator was made with the help of AI tools: [Claude](https://claude.com) by Anthropic and Muse.

## Support

ProxyPrintGenerator is free and always will be. I am accepting monetary support at **[ko-fi.com/kommermail](https://ko-fi.com/kommermail)**. Tips never unlock anything; every feature is free for everyone.

## Legal

ProxyPrintGenerator is unofficial Fan Content permitted under the [Wizards of the Coast Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy). It is not approved or endorsed by Wizards. Portions of the materials used are property of Wizards of the Coast. ©Wizards of the Coast LLC.

Card data and images come from [Scryfall](https://scryfall.com) and are fetched on demand. This project is not affiliated with Scryfall.

**Use it for personal playtesting only.** Don't sell proxies or use them in sanctioned play.

- **Code:** MIT License (see `LICENSE`).
- **Fonts:** Cinzel, Cinzel Decorative and IM Fell English are under the SIL Open Font License. Other bundled fonts and the artwork keep their own terms.
