// PaperPresets.cs
// Driver-native print options for the Print sheet.
//
// Windows' typed print API only knows generic paper names, while drivers
// like Canon's list their real papers ("Matte Photo Paper", "Photo Paper
// Plus Glossy II") under their own keywords. These helpers read those
// options straight from the driver's capabilities and write the chosen
// one into the print ticket, so a preset picks exactly what the driver's
// own Preferences window would.

using System.IO;
using System.Printing;
using System.Text.Json;
using System.Xml;

namespace ProxyPrintGenerator.Views;

public sealed record DriverOption(string Name, string Display);

public static class DriverTicket
{
    private const string Psf = "http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework";

    private static XmlNamespaceManager Ns(XmlDocument x)
    {
        var ns = new XmlNamespaceManager(x.NameTable);
        ns.AddNamespace("psf", Psf);
        return ns;
    }

    private static XmlDocument Capabilities(PrintQueue q, PrintTicket t)
    {
        var x = new XmlDocument();
        using var ms = q.GetPrintCapabilitiesAsXml(t);
        x.Load(ms);
        return x;
    }

    private static XmlDocument TicketXml(PrintTicket t)
    {
        var x = new XmlDocument();
        using var ms = t.GetXmlStream();
        x.Load(ms);
        return x;
    }

    /// Every option the driver offers for a feature, with its own names.
    public static List<DriverOption> Options(PrintQueue q, PrintTicket t, string feature)
    {
        var x = Capabilities(q, t);
        var ns = Ns(x);
        var list = new List<DriverOption>();
        foreach (XmlElement o in x.SelectNodes($"/psf:PrintCapabilities/psf:Feature[@name='{feature}']/psf:Option", ns)!)
        {
            var display = o.SelectSingleNode("psf:Property[@name='psk:DisplayName']/psf:Value", ns)?.InnerText;
            list.Add(new DriverOption(o.GetAttribute("name"), string.IsNullOrWhiteSpace(display) ? o.GetAttribute("name") : display));
        }
        return list;
    }

    /// The highest resolution option the driver offers, by its X dpi.
    public static (string Name, int Dpi)? BestResolution(PrintQueue q, PrintTicket t)
    {
        var x = Capabilities(q, t);
        var ns = Ns(x);
        (string, int)? best = null;
        foreach (XmlElement o in x.SelectNodes("/psf:PrintCapabilities/psf:Feature[@name='psk:PageResolution']/psf:Option", ns)!)
        {
            var rx = o.SelectSingleNode(".//psf:ScoredProperty[@name='psk:ResolutionX']/psf:Value", ns)?.InnerText;
            if (int.TryParse(rx, out var dpi) && (best == null || dpi > best.Value.Item2)) best = (o.GetAttribute("name"), dpi);
        }
        return best;
    }

    /// The option the ticket currently holds for a feature.
    public static string? Current(PrintTicket t, string feature)
    {
        var x = TicketXml(t);
        var opt = x.SelectSingleNode($"/psf:PrintTicket/psf:Feature[@name='{feature}']/psf:Option", Ns(x)) as XmlElement;
        return opt?.GetAttribute("name");
    }

    /// A copy of the ticket with one feature set to a driver option,
    /// validated by the driver.
    public static PrintTicket With(PrintQueue q, PrintTicket t, string feature, string option)
    {
        var x = TicketXml(t);
        var ns = Ns(x);
        var root = x.DocumentElement!;
        // Driver keywords carry the driver's own namespace prefix; make
        // sure the ticket declares it before naming the option.
        var caps = Capabilities(q, t).DocumentElement!;
        foreach (var name in new[] { feature, option })
        {
            var colon = name.IndexOf(':');
            if (colon <= 0) continue;
            var prefix = name[..colon];
            if (string.IsNullOrEmpty(root.GetNamespaceOfPrefix(prefix)) && caps.GetNamespaceOfPrefix(prefix) is { Length: > 0 } uri)
                root.SetAttribute("xmlns:" + prefix, uri);
        }
        var feat = x.SelectSingleNode($"/psf:PrintTicket/psf:Feature[@name='{feature}']", ns) as XmlElement;
        if (feat == null)
        {
            feat = x.CreateElement("psf", "Feature", Psf);
            feat.SetAttribute("name", feature);
            root.AppendChild(feat);
        }
        foreach (var old in feat.SelectNodes("psf:Option", ns)!.Cast<XmlNode>().ToList()) feat.RemoveChild(old);
        var opt = x.CreateElement("psf", "Option", Psf);
        opt.SetAttribute("name", option);
        feat.PrependChild(opt);
        using var ms = new MemoryStream();
        x.Save(ms);
        ms.Position = 0;
        return q.MergeAndValidatePrintTicket(t, new PrintTicket(ms)).ValidatedPrintTicket;
    }
}

/// One click paper setup: the paper type, High quality, the build's paper size, and the
/// printer's top resolution, matched against what the driver offers.
public sealed record PaperPreset(string Label, string MediaOption, string QualityOption, string Hint)
{
    private static readonly (string Label, Func<DriverOption, bool> Match, string Fallback, string Hint)[] Wanted =
    [
        ("Plain", o => o.Name == "psk:Plain", "psk:Plain",
            "Plain paper at High quality: fine for test sheets and playtest proxies."),
        ("Matte Photo", o => o.Display.Contains("Matte Photo", StringComparison.OrdinalIgnoreCase), "psk:PhotographicMatte",
            "Canon Matte Photo Paper: ink tuned for matte, no glare, and it takes a sleeve well. Print side is the brighter white side."),
        ("Glossy II", o => o.Display.Contains("Plus Glossy II", StringComparison.OrdinalIgnoreCase), "psk:PhotographicHighGloss",
            "Canon Photo Paper Plus Glossy II: the richest color and deepest blacks. Let prints dry a few minutes before cutting."),
        ("Glossy", o => o.Display.Trim().StartsWith("Glossy Photo Paper", StringComparison.OrdinalIgnoreCase)
                        || o.Name.EndsWith(":GlossyPaperStandard", StringComparison.OrdinalIgnoreCase), "psk:PhotographicGlossy",
            "Canon Glossy Photo Paper (everyday use). Let prints dry a few minutes before cutting."),
    ];

    /// The presets this printer can honor, by its own paper names.
    public static List<PaperPreset> For(PrintQueue q, PrintTicket t)
    {
        var media = DriverTicket.Options(q, t, "psk:PageMediaType");
        var quality = DriverTicket.Options(q, t, "psk:PageOutputQuality");
        var high = quality.FirstOrDefault(o => o.Name == "psk:High")?.Name
                   ?? quality.FirstOrDefault(o => o.Name == "psk:Photographic")?.Name
                   ?? quality.FirstOrDefault()?.Name ?? "psk:High";
        var list = new List<PaperPreset>();
        foreach (var (label, match, fallback, hint) in Wanted)
        {
            var found = media.FirstOrDefault(match) ?? media.FirstOrDefault(o => o.Name == fallback);
            if (found != null && list.All(p => p.MediaOption != found.Name)) list.Add(new PaperPreset(label, found.Name, high, hint));
        }
        return list;
    }

    /// Sets the paper type and quality on the given paper size (the size
    /// the pages were built for).
    public PrintTicket Apply(PrintQueue q, PrintTicket t, PageMediaSize paperSize)
    {
        t = t.Clone();
        t.PageMediaSize = paperSize;
        t.PageOrientation = PageOrientation.Portrait;
        t = q.MergeAndValidatePrintTicket(t, t).ValidatedPrintTicket;
        t = DriverTicket.With(q, t, "psk:PageMediaType", MediaOption);
        t = DriverTicket.With(q, t, "psk:PageOutputQuality", QualityOption);
        if (DriverTicket.BestResolution(q, t) is { } best) t = DriverTicket.With(q, t, "psk:PageResolution", best.Name);
        return t;
    }
}

/// The printer and paper last used, so the sheet opens ready to go.
/// The last printer, paper preset and paper source (the driver's own
/// option name, such as a cassette), remembered between prints.
public sealed record PrintMemory(string? Printer, string? Paper, string? Source = null)
{
    private static string FilePath => Path.Combine(
        Environment.GetEnvironmentVariable("PPG_DATA_DIR") is { Length: > 0 } custom ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ProxyPrintGenerator"),
        "print.json");

    public static PrintMemory Load()
    {
        try { return JsonSerializer.Deserialize<PrintMemory>(File.ReadAllText(FilePath)) ?? new(null, null); }
        catch { return new(null, null); }
    }

    public static void Save(PrintMemory m)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(m));
        }
        catch { /* best effort */ }
    }
}
