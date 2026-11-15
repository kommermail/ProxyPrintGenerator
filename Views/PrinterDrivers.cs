// PrinterDrivers.cs
// What the print sheet knows about a printer beyond its options: whether
// it is offline, paused or in error, and which driver it uses.
//
// Windows 11 sets most home printers up with Microsoft's own IPP Class
// Driver (Mopria), its generic driver, the way a Mac uses AirPrint. It
// prints fine, but the maker's own driver lists the exact paper types
// (Canon's Matte Photo Paper, Photo Paper Plus Glossy II...) and finer
// quality. Installing the maker's driver doesn't change printers that
// were already added, so the sheet spots a printer on the generic driver
// whose maker driver is installed, and offers to add the printer again
// with it (Set it up for me), on the same port, after Windows' own
// administrator prompt. Mirrored from the Mac app, Nov 15, 2026.
//
// Every value the setup uses comes from Windows itself and passes the
// same checks for every maker: the driver is one installed on this PC
// for this exact model, and the port is the one this printer already
// prints through. The elevated step checks them all again itself.

using System.ComponentModel;
using System.Diagnostics;
using System.Printing;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public enum DriverKind { Maker, Generic, Virtual, Fax }

/// A printer queue as the sheet sees it.
public sealed record PrinterStatus(
    string Queue, string Model, string Maker, string DriverName, string Port, DriverKind Kind,
    bool Offline, bool Paused, bool InError, string? UnusedMakerDriver, string? MakerDriverTwin);

public enum AdviceAction { None, OpenPrinterSettings, SetUpForMe, FindDriver, Choose }

public sealed record PrinterAdvice(string Id, string Text, bool IsProblem, string? ActionLabel, AdviceAction Action, string? Target = null);

public static partial class PrinterDrivers
{
    private static readonly EnumeratedPrintQueueTypes[] Kinds = [EnumeratedPrintQueueTypes.Local, EnumeratedPrintQueueTypes.Connections];

    // MARK: - Reading printers

    public static List<PrinterStatus> Load()
    {
        var drivers = InstalledDrivers();
        var list = new List<PrinterStatus>();
        using var server = new LocalPrintServer();
        foreach (var q in server.GetPrintQueues(Kinds))
        {
            try
            {
                q.Refresh();
                var driver = q.QueueDriver?.Name ?? "";
                var port = q.QueuePort?.Name ?? "";
                var kind = Classify(driver, port);
                var model = ModelFromQueue(q.Name, kind == DriverKind.Maker ? driver : null);
                var maker = model.Split(' ', 2)[0];
                string? unused = null;
                if (kind == DriverKind.Generic)
                    unused = drivers.FirstOrDefault(d => Classify(d, "") == DriverKind.Maker && SameModel(d, model));
                list.Add(new PrinterStatus(q.FullName, model, maker, driver, port, kind,
                    q.IsOffline || q.IsNotAvailable, q.IsPaused, q.IsInError || q.IsPaperJammed || q.IsDoorOpened || q.IsOutOfPaper,
                    unused, null));
            }
            catch { /* a queue that won't answer is left out */ }
            finally { q.Dispose(); }
        }
        // Another queue for the same model already on the maker driver.
        for (var i = 0; i < list.Count; i++)
            if (list[i].UnusedMakerDriver != null)
                list[i] = list[i] with
                {
                    MakerDriverTwin = list.FirstOrDefault(o => o.Kind == DriverKind.Maker && SameModel(o.Model, list[i].Model))?.Queue,
                };
        return list;
    }

    public static bool IsFax(PrintQueue q)
    {
        try { return Classify(q.QueueDriver?.Name ?? "", q.QueuePort?.Name ?? "") == DriverKind.Fax; }
        catch { return false; }
    }

    public static DriverKind Classify(string driver, string port)
    {
        var d = driver.ToLowerInvariant();
        var p = port.ToUpperInvariant();
        if (d.Contains("fax") || p.StartsWith("SHRFAX")) return DriverKind.Fax;
        if (p is "PORTPROMPT:" or "NUL:" or "FILE:" || d.Contains("onenote") || d.Contains("xps document writer")
            || d.Contains("print to pdf") || d.Contains("software printer driver")) return DriverKind.Virtual;
        if (d.StartsWith("microsoft") && (d.Contains("class driver") || d.Contains("ipp") || d.Contains("mopria")
                                          || d.Contains("point and print") || d.Contains("universal print"))
            || d.StartsWith("generic")) return DriverKind.Generic;
        return DriverKind.Maker;
    }

    /// "Canon MB5400 series" from a queue name like "Canon MB5400
    /// series (Copy 1)" or "\\server\Canon MB5400 series".
    private static string ModelFromQueue(string queue, string? makerDriver)
    {
        if (makerDriver != null) return makerDriver;
        var name = queue.Contains('\\') ? queue[(queue.LastIndexOf('\\') + 1)..] : queue;
        name = Regex.Replace(name, @"\s*\((copy|redirected)\s*\d*\)\s*$", "", RegexOptions.IgnoreCase);
        name = Regex.Replace(name, @"\s*-\s*(wsd|ipp|mopria)\s*$", "", RegexOptions.IgnoreCase);
        return name.Trim();
    }

    /// Same printer model, ignoring case, punctuation and "series":
    /// "Canon MB5400 series" = "Canon MB5400 series" = "CANON MB5400".
    public static bool SameModel(string a, string b)
    {
        static string Key(string s) => Regex.Replace(
            Regex.Replace(s.ToLowerInvariant(), @"\b(series|mopria|ipp|wsd|class driver)\b", ""), "[^a-z0-9]", "");
        var ka = Key(a);
        var kb = Key(b);
        if (ka.Length < 4 || kb.Length < 4) return false;
        if (ka == kb) return true;
        // "canonmb5400" inside "canonmb5400copy2": the shorter name must
        // be long enough to be a real model, and must contain a digit.
        var (shorter, longer) = ka.Length <= kb.Length ? (ka, kb) : (kb, ka);
        return shorter.Length >= 8 && shorter.Any(char.IsDigit) && longer.StartsWith(shorter)
               && !char.IsDigit(longer[shorter.Length]);
    }

    // MARK: - Advice

    /// Windows protected print mode allows only Windows' own drivers.
    public static bool ProtectedPrintMode()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP");
            return key?.GetValue("WindowsProtectedPrintGroupPolicyState") is int v && v == 1;
        }
        catch { return false; }
    }

    public static List<PrinterAdvice> Advice(PrinterStatus p)
    {
        var name = p.Queue;
        var list = new List<PrinterAdvice>();
        if (p.Paused)
            list.Add(new("paused", $"{name} is paused, so a job sent to it waits instead of printing. Resume it in Windows' printer settings.", true,
                "Open printer settings", AdviceAction.OpenPrinterSettings));
        else if (p.InError)
            list.Add(new("error", $"{name} reports a problem (paper, jam or an open door). Check the printer; the job waits until it's sorted.", true, null, AdviceAction.None));
        else if (p.Offline)
            list.Add(new("offline", $"{name} looks offline or asleep. Make sure it's on and connected; the job waits until it is.", false, null, AdviceAction.None));

        if (p.Kind != DriverKind.Generic) return list;
        if (ProtectedPrintMode())
        {
            list.Add(new("wpp", $"{name} uses Windows' own printer driver, and Windows protected print mode is on, which only allows that driver. It prints fine; the Paper list shows what it offers.", false, null, AdviceAction.None));
            return list;
        }
        if (p.MakerDriverTwin is { } twin)
            list.Add(new("twin", $"{name} uses Windows' generic driver, but {twin} is the same printer set up with {p.Maker}'s own driver, which has the exact paper types. Print with that one.", false,
                $"Use {twin}", AdviceAction.Choose, twin));
        else if (p.UnusedMakerDriver is { } driver)
            list.Add(new("readd", $"{driver}'s own driver is installed on this PC, but this printer uses Windows' generic driver, so it only offers basic paper types. The app can add this printer again with {p.Maker}'s driver for you; Windows asks for permission first. Your current printer stays as it is.", false,
                "Set it up for me", AdviceAction.SetUpForMe));
        else
            list.Add(new("getdriver", $"{name} uses Windows' generic driver. It prints fine, but {p.Maker}'s own driver adds the exact paper types (like matte photo paper) and finer quality.", false,
                "Get the driver for me", AdviceAction.FindDriver));
        return list;
    }

    /// The maker's driver download page, opened in the web browser.
    public static string? MakerDriverPage(string maker) => DriverDownloads.MakerFor(maker)?.DriverPage;

    public static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    public static void OpenPrinterSettings()
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:printers") { UseShellExecute = true }); } catch { }
    }

    // MARK: - Set it up for me

    /// Adds the printer again with its maker's driver: this exe runs
    /// itself elevated (Windows' administrator prompt) with
    /// --add-printer, which checks every value again before adding.
    /// Returns the new queue's name.
    public static async Task<string> SetUpAsync(PrinterStatus p)
    {
        if (p.UnusedMakerDriver is not { } driver) throw new PpgException("No maker driver for this printer is installed.");
        var name = UniqueQueueName(driver);
        var exe = Environment.ProcessPath ?? throw new PpgException("The app can't find itself to ask Windows for permission.");
        var start = new ProcessStartInfo(exe) { UseShellExecute = true, Verb = "runas" };
        start.ArgumentList.Add("--add-printer");
        start.ArgumentList.Add(p.Port);
        start.ArgumentList.Add(driver);
        start.ArgumentList.Add(name);
        Process? proc;
        try { proc = Process.Start(start); }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223)
        { throw new PpgException("Windows didn't get permission, so nothing was added."); }
        if (proc == null) throw new PpgException("Windows didn't start the setup.");
        await proc.WaitForExitAsync();
        return proc.ExitCode switch
        {
            0 => name,
            2 => throw new PpgException("The setup didn't pass its safety checks, so nothing was added."),
            5 => throw new PpgException("Windows didn't allow adding the printer (access denied)."),
            _ => throw new PpgException($"Windows didn't add the printer (error {proc.ExitCode})."),
        };
    }

    /// The elevated half: re-checks every value, then adds the printer.
    /// Exit codes: 0 added, 2 refused by the checks, else the Windows
    /// error.
    public static int AddPrinterElevated(string port, string driver, string name)
    {
        // The driver must be installed and a maker driver; the port must
        // be one an existing printer already uses with a generic driver
        // for this same model; the name must be plain and unused.
        if (Classify(driver, port) != DriverKind.Maker || !InstalledDrivers().Contains(driver, StringComparer.OrdinalIgnoreCase)) return 2;
        if (!SafeName(name) || !SafeName(driver) || port.Length is 0 or > 200 || port.Any(char.IsControl)) return 2;
        var mine = Load();
        if (!mine.Any(s => s.Kind == DriverKind.Generic && string.Equals(s.Port, port, StringComparison.OrdinalIgnoreCase) && SameModel(s.Model, driver))) return 2;
        if (mine.Any(s => string.Equals(s.Queue, name, StringComparison.OrdinalIgnoreCase))) return 2;

        var info = new PRINTER_INFO_2
        {
            pPrinterName = name, pPortName = port, pDriverName = driver,
            pPrintProcessor = "winprint", pDatatype = "RAW",
            pComment = "Added by ProxyPrintGenerator with the maker's driver",
        };
        var handle = AddPrinter(null, 2, ref info);
        if (handle == IntPtr.Zero) return Marshal.GetLastWin32Error() is var err && err != 0 ? err : 1;
        ClosePrinter(handle);
        return 0;
    }

    private static string UniqueQueueName(string driver)
    {
        var taken = Load().Select(s => s.Queue).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var name = driver;
        for (var n = 2; taken.Contains(name); n++) name = $"{driver} ({n})";
        return name;
    }

    private static bool SafeName(string s) =>
        s.Length is > 0 and <= 200 && !s.Any(c => char.IsControl(c) || c is '\\' or ',' or '!' or '"');

    // MARK: - Windows printing APIs

    /// The printer drivers installed on this PC (x64 and the PC's own).
    public static List<string> InstalledDrivers()
    {
        var names = new List<string>();
        EnumPrinterDrivers(null, null, 1, IntPtr.Zero, 0, out var needed, out _);
        if (needed == 0) return names;
        var buf = Marshal.AllocHGlobal((int)needed);
        try
        {
            if (!EnumPrinterDrivers(null, null, 1, buf, needed, out _, out var count)) return names;
            var size = Marshal.SizeOf<DRIVER_INFO_1>();
            for (var i = 0; i < count; i++)
            {
                var info = Marshal.PtrToStructure<DRIVER_INFO_1>(buf + i * size);
                if (Marshal.PtrToStringUni(info.pName) is { Length: > 0 } n && !names.Contains(n)) names.Add(n);
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
        return names;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DRIVER_INFO_1 { public IntPtr pName; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PRINTER_INFO_2
    {
        public string? pServerName, pPrinterName, pShareName, pPortName, pDriverName, pComment, pLocation;
        public IntPtr pDevMode;
        public string? pSepFile, pPrintProcessor, pDatatype, pParameters;
        public IntPtr pSecurityDescriptor;
        public uint Attributes, Priority, DefaultPriority, StartTime, UntilTime, Status, cJobs, AveragePPM;
    }

    [LibraryImport("winspool.drv", EntryPoint = "EnumPrinterDriversW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool EnumPrinterDrivers(string? pName, string? pEnvironment, uint level, IntPtr pDriverInfo, uint cbBuf, out uint pcbNeeded, out uint pcReturned);

    [DllImport("winspool.drv", EntryPoint = "AddPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr AddPrinter(string? pName, uint level, ref PRINTER_INFO_2 pPrinter);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr hPrinter);
}
