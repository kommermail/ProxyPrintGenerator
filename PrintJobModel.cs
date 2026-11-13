// PrintJobModel.cs
// The build screen's state, ported from PrintJobModel.swift: holds the
// settings, runs one job at a time through ProxyPrintEngine and turns
// its progress into bindable values. Finished files land in
// Documents\ProxyPrintGenerator, ready to open, reveal, or Save As.

using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        OnChanged(name);
        return true;
    }
    protected virtual void OnChanged(string? name) { }
}

public sealed class PrintJobModel : Observable
{
    private string _deckText = "";
    private int _scale = 4;
    private bool _guides = true, _useCalibration, _maximizeGap, _thickGuides, _shuffle, _pngOverride, _backToBack;
    private double _cyan = 1, _magenta = 1, _yellow = 1, _vibrance, _midtone;
    private SafeAreaProfile _safeArea = SafeAreaProfile.None;
    private string _outputName = "proxies";
    private OutputFormat _format = OutputFormat.Pdf;
    private double _jpegQuality = 0.65, _shiftUp, _extraGap;
    private bool _isRunning;
    private string _stageText = "";
    private double _fraction;
    private PrintJobResult? _result;
    private string? _errorText;
    private string? _savedMessage;
    private int _twoSidedHint;
    private CancellationTokenSource? _cts;

    public string DeckText { get => _deckText; set => Set(ref _deckText, value); }
    public int Scale { get => _scale; set => Set(ref _scale, value); }
    public bool Guides { get => _guides; set => Set(ref _guides, value); }
    public bool ThickGuides { get => _thickGuides; set => Set(ref _thickGuides, value); }
    public bool UseCalibration { get => _useCalibration; set => Set(ref _useCalibration, value); }
    public double CyanBoost { get => _cyan; set => Set(ref _cyan, value); }
    public double MagentaBoost { get => _magenta; set => Set(ref _magenta, value); }
    public double YellowBoost { get => _yellow; set => Set(ref _yellow, value); }
    public double Vibrance { get => _vibrance; set => Set(ref _vibrance, Math.Round(value / 0.05) * 0.05); }
    public double MidtoneLift { get => _midtone; set => Set(ref _midtone, Math.Round(value, 2)); }

    /// The realism preset behind the Auto switch.
    public const double AutoVibrance = 0.40, AutoMidtoneLift = 0.12;
    private double _vibranceBeforeAuto, _midtoneBeforeAuto;

    /// On whenever vibrance and lift sit at the preset (40% and 12%).
    /// Turning it on applies the preset; turning it off puts back the
    /// values from before. Moving either slider turns it off by itself.
    public bool AutoTone
    {
        get => Math.Abs(Vibrance - AutoVibrance) < 0.001 && Math.Abs(MidtoneLift - AutoMidtoneLift) < 0.001;
        set
        {
            if (value == AutoTone) return;
            if (value)
            {
                (_vibranceBeforeAuto, _midtoneBeforeAuto) = (Vibrance, MidtoneLift);
                Vibrance = AutoVibrance;
                MidtoneLift = AutoMidtoneLift;
            }
            else
            {
                Vibrance = _vibranceBeforeAuto;
                MidtoneLift = _midtoneBeforeAuto;
            }
        }
    }
    public SafeAreaProfile SafeArea { get => _safeArea; set => Set(ref _safeArea, value); }
    public bool MaximizeGap { get => _maximizeGap; set => Set(ref _maximizeGap, value); }
    public bool ShuffleBeforeRender { get => _shuffle; set => Set(ref _shuffle, value); }
    /// Two sided cards go after the one sided pages as front/back page
    /// pairs, printed double sided, instead of each back as its own card.
    public bool BackToBack { get => _backToBack; set => Set(ref _backToBack, value); }
    /// Session only: a fresh launch starts with the override off.
    public bool PngOverride { get => _pngOverride; set => Set(ref _pngOverride, value); }
    public string OutputName { get => _outputName; set => Set(ref _outputName, value); }
    public OutputFormat Format { get => _format; set => Set(ref _format, value); }
    public double JpegQuality { get => _jpegQuality; set => Set(ref _jpegQuality, value); }
    public double ShiftUpMM { get => _shiftUp; set => Set(ref _shiftUp, Math.Clamp(value, 0, 4)); }
    public double ExtraGapMM { get => _extraGap; set => Set(ref _extraGap, Math.Clamp(value, 0, 2)); }
    /// Two sided cards known to the deck page from its preview fetch.
    public int TwoSidedHint { get => _twoSidedHint; set => Set(ref _twoSidedHint, value); }

    // MARK: - Paper and printer (remembered between sessions)

    private PaperSize _paper = PaperSize.Letter;
    private bool _fitToPrinter;
    private string? _fitPrinter;
    private PrinterMargins? _fitMargins;
    private string _fitStatus = "";
    private IReadOnlyList<PaperSize> _printerSizes = [];
    private IReadOnlyList<string> _printers = [];
    private bool _loadingLayout;

    public PrintJobModel() => ReloadLayout();

    public PaperSize Paper { get => _paper; set { if (value != null && Set(ref _paper, value)) SaveLayout(); } }
    /// Keep the cards inside what FitPrinter's driver says it can reach.
    public bool FitToPrinter { get => _fitToPrinter; set { if (Set(ref _fitToPrinter, value)) SaveLayout(); } }
    /// A list that hasn't loaded yet can push null; only a load clears it.
    public string? FitPrinter { get => _fitPrinter; set { if ((value != null || _loadingLayout) && Set(ref _fitPrinter, value)) SaveLayout(); } }
    /// The reach last read from FitPrinter's driver, for Paper.
    public PrinterMargins? FitMargins { get => _fitMargins; set { if (Set(ref _fitMargins, value)) SaveLayout(); } }
    /// What the last read of the driver found, in a sentence.
    public string FitStatus { get => _fitStatus; set => Set(ref _fitStatus, value); }
    public IReadOnlyList<string> Printers { get => _printers; set => Set(ref _printers, value); }
    /// The sizes FitPrinter's driver lists, for the paper picker.
    public IReadOnlyList<PaperSize> PrinterSizes { get => _printerSizes; set => Set(ref _printerSizes, value); }

    /// The paper picker: the standard sizes, then the printer's own, then
    /// the chosen paper if it is none of those (a size from an earlier
    /// printer).
    public IReadOnlyList<PaperSize> PaperChoices
    {
        get
        {
            var list = PaperSize.Standard.ToList();
            foreach (var p in PrinterSizes) if (!list.Any(s => s.SameSheet(p))) list.Add(p);
            if (!list.Contains(Paper)) list.Add(Paper);
            return list;
        }
    }

    /// The page layout these settings make, as the engine will lay it out.
    public PrintSettings LayoutSettings() => new()
    {
        Paper = Paper,
        PrinterMargins = FitToPrinter ? FitMargins : null,
        GapMM = 3.0 + ExtraGapMM,
        SafeArea = SafeArea,
        MaximizeGap = MaximizeGap,
        ShiftUpMM = ShiftUpMM,
    };

    public string GridCaption
    {
        get
        {
            var s = LayoutSettings();
            return s.CardsPerPage == 0
                ? $"{Paper.ShortLabel} paper is too small for a card once the printer's edges are left clear."
                : $"{s.CardsPerPage} card{(s.CardsPerPage == 1 ? "" : "s")} per page, {s.Columns} across and {s.Rows} down";
        }
    }

    public string PaperSummary
    {
        get
        {
            var text = $"{Paper.ShortLabel}, {LayoutSettings().CardsPerPage} per page";
            return FitToPrinter && FitPrinter != null ? $"{text}, fit to {FitPrinter}" : text;
        }
    }

    /// The Canon safe area only matters when not fitting to a printer.
    public bool ShowSafeArea => !FitToPrinter;

    /// Picks up a change made on another page (the file is the truth).
    public void ReloadLayout()
    {
        var m = LayoutMemory.Load();
        _loadingLayout = true;
        try
        {
            Paper = m.Paper() ?? PaperSize.Letter;
            FitToPrinter = m.FitToPrinter;
            FitPrinter = m.FitPrinter;
            FitMargins = m.FitMargins is [var t, var b, var l, var r] ? new PrinterMargins(t, b, l, r) : null;
        }
        finally { _loadingLayout = false; }
    }

    private void SaveLayout()
    {
        if (_loadingLayout) return;
        new LayoutMemory
        {
            PaperKey = Paper.Key, PaperLabel = Paper.Label, PaperWidthMM = Paper.WidthMM, PaperHeightMM = Paper.HeightMM,
            FitToPrinter = FitToPrinter, FitPrinter = FitPrinter,
            FitMargins = FitMargins is { } m ? [m.Top, m.Bottom, m.Left, m.Right] : null,
        }.Save();
    }

    public bool IsRunning { get => _isRunning; private set => Set(ref _isRunning, value); }
    public string StageText { get => _stageText; private set => Set(ref _stageText, value); }
    public double Fraction { get => _fraction; private set => Set(ref _fraction, value); }
    public PrintJobResult? Result { get => _result; private set => Set(ref _result, value); }
    public string? ErrorText { get => _errorText; set => Set(ref _errorText, value); }
    public string? SavedMessage { get => _savedMessage; set => Set(ref _savedMessage, value); }

    private bool _isPrinting;
    private string? _printStatus;
    /// True while pages are being prepared and spooled.
    public bool IsPrinting { get => _isPrinting; set => Set(ref _isPrinting, value); }
    /// The bar's line about the last print: progress, then the outcome.
    public string? PrintStatus { get => _printStatus; set => Set(ref _printStatus, value); }
    /// Print is offered for finished PDFs.
    public bool CanPrint => HasResult && !IsPrinting && Result!.OutputPath.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase);
    public bool ShowPrint => HasResult && Result!.OutputPath.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase);
    /// The build's own resolution, the ceiling for print rendering.
    public int ResultDpi { get; private set; } = 300;

    private static readonly string[] Derived =
    [
        nameof(ResolvedGapCaption), nameof(SizeCaption), nameof(PngWarning), nameof(PngRefused), nameof(PngLimitNotice),
        nameof(ShowOverride), nameof(CanBuild), nameof(BuildLabel), nameof(SaveLabel), nameof(FormatCaption),
        nameof(DeckLineCount), nameof(HasResult), nameof(ShowIdle), nameof(ResultSummary), nameof(ResultBacks),
        nameof(ResultSize), nameof(StatusLine), nameof(ResultWarnings), nameof(IsSafeAreaOn), nameof(JpegQualityText),
        nameof(CyanText), nameof(MagentaText), nameof(YellowText), nameof(VibranceText), nameof(MidtoneText),
        nameof(ShiftUpText), nameof(ExtraGapText), nameof(IsJpeg), nameof(CanPrint), nameof(ShowPrint),
        nameof(CanEditSettings), nameof(SettingsOpacity), nameof(AutoTone), nameof(PrintOptionsSummary), nameof(CalibrationSummary),
        nameof(PaperChoices), nameof(GridCaption), nameof(PaperSummary), nameof(ShowSafeArea),
    ];

    /// Settings lock while a build runs, so the result always matches them.
    public bool CanEditSettings => !IsRunning;
    public double SettingsOpacity => IsRunning ? 0.55 : 1.0;

    /// Everything that changes what a build produces. When one of these
    /// moves after a build, that build no longer matches the screen.
    private static readonly HashSet<string> BuildInputs =
    [
        nameof(DeckText), nameof(Scale), nameof(Guides), nameof(ThickGuides), nameof(UseCalibration), nameof(CyanBoost),
        nameof(MagentaBoost), nameof(YellowBoost), nameof(Vibrance), nameof(MidtoneLift), nameof(SafeArea), nameof(MaximizeGap),
        nameof(ShuffleBeforeRender), nameof(Format), nameof(JpegQuality), nameof(ShiftUpMM), nameof(ExtraGapMM), nameof(BackToBack),
        nameof(Paper), nameof(FitToPrinter), nameof(FitMargins),
    ];

    private string? _staleNote;
    /// Said under the Build button after settings moved past a build.
    public string? StaleNote { get => _staleNote; private set => Set(ref _staleNote, value); }

    /// Every finished build this session, keyed by the exact settings that
    /// made it, so returning to settings already built brings that file
    /// straight back instead of building it again.
    private readonly Dictionary<string, PrintJobResult> _builds = [];
    private string _runningSignature = "";

    private string InputSignature() => string.Join("|", DeckText, Scale, Guides, ThickGuides, UseCalibration, CyanBoost,
        MagentaBoost, YellowBoost, Vibrance, MidtoneLift, SafeArea, MaximizeGap, ShuffleBeforeRender, Format,
        Format == OutputFormat.Jpeg ? JpegQuality : 0, ShiftUpMM, ExtraGapMM, BackToBack, OutputName.Trim().ToLowerInvariant(),
        Paper.Key, Paper.WidthMM, Paper.HeightMM, FitToPrinter ? FitMargins?.ToString() : "");

    protected override void OnChanged(string? name)
    {
        if (name != null && Derived.Contains(name)) return;
        if (name != null && !IsRunning && (BuildInputs.Contains(name) || name == nameof(OutputName)))
        {
            // Settings that were already built: show that file again.
            if (_builds.TryGetValue(InputSignature(), out var known) && File.Exists(known.OutputPath))
            {
                if (Result != known) { Result = known; StaleNote = null; SavedMessage = null; PrintStatus = null; }
            }
            else if (Result != null && BuildInputs.Contains(name))
            {
                // The finished file no longer matches the settings. A
                // format switch renders the deck again in the new format
                // right away (the face cache makes that quick); any other
                // change brings Build back so nothing stale can be saved.
                var last = Path.GetFileName(Result.OutputPath);
                Result = null;
                SavedMessage = null;
                PrintStatus = null;
                if (name == nameof(Format) && CanBuild)
                {
                    StaleNote = null;
                    Start();
                    return;
                }
                StaleNote = $"Settings changed since {last} was built. Build again to use them ({last} is still in your builds folder).";
            }
        }
        foreach (var d in Derived) Raise(d);
    }

    // MARK: - Derived text

    public string CyanText => $"{CyanBoost:0.00}x";
    public string MagentaText => $"{MagentaBoost:0.00}x";
    public string YellowText => $"{YellowBoost:0.00}x";
    public string VibranceText => $"+{(int)Math.Round(Vibrance * 100)}%";
    public string MidtoneText => $"+{(int)Math.Round(MidtoneLift * 100)}%";
    public string ShiftUpText => $"{ShiftUpMM:0.0}";
    public string ExtraGapText => $"{ExtraGapMM:0.00}";
    public string JpegQualityText => $"{(int)(JpegQuality * 100)}%";
    public bool IsJpeg => Format == OutputFormat.Jpeg;
    public bool IsSafeAreaOn => SafeArea != SafeAreaProfile.None;

    /// What the closed Print options dropdown has turned on.
    public string PrintOptionsSummary
    {
        get
        {
            var on = new List<string>();
            if (BackToBack) on.Add("back to back");
            if (ShiftUpMM > 0) on.Add($"shift up {ShiftUpMM:0.0} mm");
            if (ExtraGapMM > 0) on.Add($"extra gap {ExtraGapMM:0.00} mm");
            if (IsSafeAreaOn && !FitToPrinter) on.Add("safe area");
            if (MaximizeGap) on.Add("max gap");
            return on.Count == 0 ? "all off" : string.Join(", ", on);
        }
    }

    public string CalibrationSummary => UseCalibration ? "on" : "off";

    public string ResolvedGapCaption
    {
        get
        {
            var g = LayoutSettings().ResolvedGapsMM();
            return $"Resolved gaps: {g.Row:0.0}mm between rows, {g.Column:0.0}mm between columns";
        }
    }

    public string FormatCaption => Format switch
    {
        OutputFormat.Pdf => "One printable PDF at full quality",
        OutputFormat.Png => "Every page stitched into one tall PNG at full quality",
        _ => "Every page stitched into one tall JPEG. Quality down, file down",
    };

    public int DeckLineCount => DeckText.Split('\n').Count(l => l.Trim().Length > 0);

    /// Cards in the list, counting quantities (approximate by design).
    public static int CardCount(string text)
    {
        var total = 0;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("//") || line.StartsWith('#')) continue;
            var first = line.Split(' ')[0];
            if (int.TryParse(first, out var q)) total += q;
            else if (line.Contains('(')) total += 1;
        }
        return total;
    }

    public long EstimatedOutputBytes
    {
        get
        {
            var cards = CardCount(DeckText);
            if (cards <= 0) return 0;
            var dpi = Scale * 300.0;
            var pagePixels = Paper.WidthMM / 25.4 * dpi * (Paper.HeightMM / 25.4 * dpi);
            var pages = (int)Math.Ceiling(cards / (double)Math.Max(1, LayoutSettings().CardsPerPage));
            return Format switch
            {
                OutputFormat.Pdf => (long)(cards * (63.0 / 25.4 * dpi) * (88.0 / 25.4 * dpi) * 0.95),
                OutputFormat.Png => (long)(pages * pagePixels * 0.85),
                _ => (long)(pages * pagePixels * (0.12 + 0.42 * JpegQuality)),
            };
        }
    }

    public long EstimatedWorkingBytes
    {
        get
        {
            var output = EstimatedOutputBytes;
            if (output <= 0) return 0;
            var dpi = Scale * 300.0;
            var cache = (long)(CardCount(DeckText) * (63.0 / 25.4 * dpi) * (88.0 / 25.4 * dpi) * 0.45);
            var staging = Format == OutputFormat.Pdf ? output / 3 : output * 3 / 2;
            return output + staging + cache;
        }
    }

    public static string OutputFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "ProxyPrintGenerator");

    public long FreeDiskBytes
    {
        get
        {
            try { return new DriveInfo(Path.GetPathRoot(OutputFolder)!).AvailableFreeSpace; } catch { return 0; }
        }
    }

    public static string FormatBytes(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double v = bytes; var u = 0;
        while (v >= 1000 && u < units.Length - 1) { v /= 1000; u++; }
        return u == 0 ? $"{bytes} bytes" : $"{v:0.#} {units[u]}";
    }

    public string SizeCaption => EstimatedOutputBytes <= 0 ? ""
        : $"Output ≈ {FormatBytes(EstimatedOutputBytes)}  •  Free {FormatBytes(FreeDiskBytes)}";

    public string? PngWarning
    {
        get
        {
            if (Format != OutputFormat.Png || Scale != 6) return null;
            var options = (UseCalibration ? 1 : 0) + (Vibrance > 0 ? 1 : 0) + (MidtoneLift > 0 ? 1 : 0) + (MaximizeGap ? 1 : 0) + (ThickGuides ? 1 : 0);
            return options > 2 ? "Heads up: PNG at 1800 with several options on takes a long time. Figure 6 minutes or more, even for a small print." : null;
        }
    }

    public bool PngRefused => Format == OutputFormat.Png && !PngOverride && (CardCount(DeckText) > 12 || TwoSidedHint > 2);

    public string PngLimitNotice => $"PNG is limited to 12 cards and 2 two sided cards. This build has {CardCount(DeckText)} cards" +
                                    (TwoSidedHint > 0 ? $" and {TwoSidedHint} two sided" : "") + ".";

    public bool ShowOverride => !IsRunning && Format == OutputFormat.Png && (PngRefused || PngOverride);
    public bool CanRun => !IsRunning && DeckText.Trim().Length > 0;
    public bool CanBuild => CanRun && !PngRefused;
    public string BuildLabel => Format == OutputFormat.Pdf ? "Build PDF" : $"Build {Format.Label()}";
    /// Named for the file that was actually built, never the picker.
    public string SaveLabel => Result == null ? $"Save {Format.Label()}…"
        : Path.GetExtension(Result.OutputPath).ToLowerInvariant() switch
        {
            ".png" => "Save PNG…",
            ".jpg" => "Save JPEG…",
            _ => "Save PDF…",
        };
    public bool HasResult => Result != null && !IsRunning;
    public bool ShowIdle => Result == null && !IsRunning;
    public string StatusLine => ErrorText ?? StageText;
    public string ResultSummary => Result == null ? ""
        : Result.DuplexSheets > 0
            ? $"{Result.FrontCount} card fronts, {Result.PageCount} pages: {Result.DuplexStartPage} one sided, then {Result.DuplexSheets} double sided sheet{(Result.DuplexSheets == 1 ? "" : "s")} (pages {Result.DuplexStartPage + 1}–{Result.PageCount})"
            : $"{Result.FrontCount} card fronts, {Result.PageCount} pages";
    public string ResultBacks => Result is { BackCount: > 0 } r ? $"Two sided backs: {string.Join(", ", r.BackNames)}" : "";
    public string ResultSize => Result == null ? "" : $"Size: {FormatBytes(Result.SizeBytes)}";
    public string ResultWarnings => Result == null ? "" : string.Join("\n", Result.Warnings);

    // MARK: - Running

    public void LoadDeckFile(string path)
    {
        try { DeckText = File.ReadAllText(path); ErrorText = null; }
        catch (Exception e) { ErrorText = $"Could not read that file: {e.Message}"; }
    }

    public void Cancel() => _cts?.Cancel();

    public async void Start()
    {
        if (IsRunning) return;
        SavedMessage = null;
        PrintStatus = null;
        StaleNote = null;
        ResultDpi = Scale * 300;
        _runningSignature = InputSignature();
        IsRunning = true;
        Result = null;
        ErrorText = null;
        StageText = "Starting";
        Fraction = 0;
        _cts = new CancellationTokenSource();
        try
        {
            var name = OutputName.Trim();
            foreach (var suffix in new[] { ".pdf", ".zip", ".png", ".jpg" })
                if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) name = name[..^suffix.Length];
            name = string.Concat(name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c));
            if (name.Length == 0) name = "proxies";
            var outputPath = Path.Combine(OutputFolder, name + "." + Format.FileExtension());

            var free = FreeDiskBytes; var needed = EstimatedWorkingBytes;
            if (free > 0 && needed > 0 && free < needed)
            {
                ErrorText = $"[PPG:DISK-SPACE] Not enough free space for this build: it wants about {FormatBytes(needed)} of working room and only {FormatBytes(free)} is free.";
                return;
            }

            var options = new PrintJobOptions
            {
                Scale = Scale,
                Calibration = UseCalibration ? new InkCalibration(CyanBoost, MagentaBoost, YellowBoost) : InkCalibration.None,
                Vibrance = Vibrance, MidtoneLift = MidtoneLift, PngOverride = PngOverride, ShuffleDeck = ShuffleBeforeRender,
                SafeArea = SafeArea, MaximizeGap = MaximizeGap, ThickGuides = ThickGuides, Guides = Guides, Format = Format,
                JpegQuality = JpegQuality, ExtraGapMM = ExtraGapMM, ShiftUpMM = ShiftUpMM, BackToBack = BackToBack,
                Paper = Paper, PrinterMargins = FitToPrinter ? FitMargins : null,
            };
            var progress = new Progress<PrintProgress>(p => { StageText = p.Stage; Fraction = p.Fraction; });
            var text = DeckText;
            var token = _cts.Token;
            var built = await Task.Run(() => ProxyPrintEngine.RunAsync(text, outputPath, options, progress, token), token);
            // A rebuild to the same path replaces that file, so any older
            // entry pointing at it no longer describes what is on disk.
            foreach (var stale in _builds.Where(b => string.Equals(b.Value.OutputPath, built.OutputPath, StringComparison.OrdinalIgnoreCase)).Select(b => b.Key).ToList())
                _builds.Remove(stale);
            _builds[_runningSignature] = built;
            Result = built;
            StageText = "Done";
            Fraction = 1;
        }
        catch (OperationCanceledException) { StageText = "Cancelled"; }
        catch (Exception e)
        {
            ErrorText = e is PpgException ? e.Message : e.ToString();
            StageText = "";
        }
        finally
        {
            IsRunning = false;
            OnChanged(null);
        }
    }
}

/// The paper and printer fit, remembered between sessions in layout.json
/// next to the decks.
public sealed class LayoutMemory
{
    public string? PaperKey { get; set; }
    public string? PaperLabel { get; set; }
    public double PaperWidthMM { get; set; }
    public double PaperHeightMM { get; set; }
    public bool FitToPrinter { get; set; }
    public string? FitPrinter { get; set; }
    /// Top, bottom, left, right in mm.
    public double[]? FitMargins { get; set; }

    public PaperSize? Paper()
    {
        if (PaperKey == null) return null;
        if (PaperSize.Standard.FirstOrDefault(p => p.Key == PaperKey) is { } standard) return standard;
        return PaperWidthMM > 0 && PaperHeightMM > 0 ? new PaperSize(PaperKey, PaperLabel ?? PaperKey, PaperWidthMM, PaperHeightMM) : null;
    }

    private static string FilePath => Path.Combine(
        Environment.GetEnvironmentVariable("PPG_DATA_DIR") is { Length: > 0 } custom ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ProxyPrintGenerator"),
        "layout.json");

    public static LayoutMemory Load()
    {
        try { return System.Text.Json.JsonSerializer.Deserialize<LayoutMemory>(File.ReadAllText(FilePath)) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, System.Text.Json.JsonSerializer.Serialize(this));
        }
        catch { /* best effort */ }
    }
}
