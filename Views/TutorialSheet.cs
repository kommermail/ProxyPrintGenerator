// TutorialSheet.cs
// The quick tutorial for new users: a foil "WOW!" sticker on the Deck
// Library that opens a sheet walking through finding a deck on Moxfield,
// adding it, and building and printing it at top quality.

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using ProxyPrintGenerator.Controls;

namespace ProxyPrintGenerator.Views;

public static class TutorialSheet
{
    /// Featured decks. Opens in the web browser, like the Ko-fi button;
    /// the app itself never connects to Moxfield.
    public const string DecksUrl = "https://moxfield.com/users/derptron4000";

    /// The tilted foil sticker with a WOW! burst on its corner, the same
    /// look as the realism sticker. Click it to open the tutorial.
    public static Button Sticker()
    {
        var text = new TextBlock
        {
            Text = "Click me for a tutorial!", FontFamily = Theme.Plaque, FontWeight = FontWeights.Black, FontSize = 21,
            Foreground = Theme.Brush(Theme.Ink), VerticalAlignment = VerticalAlignment.Center,
        };
        var inner = new Grid();
        inner.Children.Add(new GlitterOverlay { Seed = 77 });
        inner.Children.Add(text);
        var card = new Border
        {
            CornerRadius = new CornerRadius(14), BorderBrush = Brushes.White, BorderThickness = new Thickness(3),
            Padding = new Thickness(52, 12, 22, 12), Background = Theme.FoilLinear(), Child = inner,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 9, ShadowDepth = 3, Opacity = 0.45 },
        };

        var burstTilt = new RotateTransform(-12);
        var burst = new Starburst
        {
            Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(-28, -30, 0, 0), RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = burstTilt,
            IsHitTestVisible = false,
        };
        // A slow wobble on the burst, so a first-time eye lands on it.
        burst.Loaded += (_, _) => burstTilt.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(-12, -2, TimeSpan.FromSeconds(1.4))
        {
            AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        });

        var sticker = new Grid();
        sticker.Children.Add(card);
        sticker.Children.Add(burst);

        var scale = new ScaleTransform(1, 1);
        var transforms = new TransformGroup();
        transforms.Children.Add(scale);
        transforms.Children.Add(new RotateTransform(-1.5));
        var button = new Button
        {
            Content = sticker, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 30, 0, 8),
            RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = transforms,
            ToolTip = "A quick walkthrough: find a deck, add it, and print it in high quality",
        };
        button.SetResourceReference(FrameworkElement.StyleProperty, "PlainButton");
        System.Windows.Automation.AutomationProperties.SetName(button, "Click me for a tutorial");
        void Grow(double to)
        {
            var a = new DoubleAnimation(to, TimeSpan.FromMilliseconds(120)) { EasingFunction = new QuadraticEase() };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }
        button.MouseEnter += (_, _) => Grow(1.05);
        button.MouseLeave += (_, _) => Grow(1);
        button.Click += (_, _) => Show();
        return button;
    }

    public static void Show()
    {
        var steps = new StackPanel { Margin = new Thickness(4, 0, 12, 4) };
        steps.Children.Add(new OrnamentCaption
        {
            Size = 19, Margin = new Thickness(0, 0, 0, 10),
            Text = "Five easy steps from a deck list to proxies that look like the real thing.",
        });

        var browse = new Button { Content = "Browse derptron4000's decks on Moxfield", FontSize = 18, HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 4, 0, 0), ToolTip = "Opens moxfield.com/users/derptron4000 in your web browser" };
        browse.SetResourceReference(FrameworkElement.StyleProperty, "FantasyButton");
        browse.Click += (_, _) => { try { Process.Start(new ProcessStartInfo(DecksUrl) { UseShellExecute = true }); } catch { } };

        steps.Children.Add(Step(1, "Find a deck",
            [
                "Ready-to-print decks are waiting at **moxfield.com/users/derptron4000**, and any other Moxfield account's public decks work too.",
                "Open a deck, click **More**, then **Export**, then **Copy for Moxfield**. That copies the list with every card's exact printing.",
            ], browse));
        steps.Children.Add(Step(2, "Add it to your library",
            [
                "Click **ADD A DECK**, choose **Paste a deck list**, give it a name and paste. A saved .txt list works too: choose **Open a .txt file**.",
                "Just want to print once without saving? Paste it on the **Quick Build** tab instead.",
            ]));
        steps.Children.Add(Step(3, "Check your cards",
            [
                "Open the deck from your library. Click a card to flip it, double-click to zoom in, and swap any card to a printing whose art you like better.",
            ]));
        steps.Children.Add(Step(4, "Set it up for top quality",
            [
                "**Scale:** 600 is right for home printers. Save 1200 or 1800 for a print shop.",
                "Flip on **AUTO** on the **WOW!** realism sticker. It adds vibrance and lifts the midtones, so cards print bright and punchy instead of dull.",
                "Under **Paper and printer**, pick your paper size. If a card edge gets cut off, turn on **Fit to my printer**.",
            ]));
        steps.Children.Add(Step(5, "Build and print",
            [
                "Click **Build PDF**, then **Print**. The app always prints at actual size, so every card comes out true to size.",
                "For the richest colors, print on matte photo paper and pick its preset in the print window.",
                "Cut along the guides and slide each proxy into a sleeve in front of an old card. It feels just like the real thing.",
            ]));

        steps.Children.Add(new OrnamentCaption
        {
            Size = 16, Margin = new Thickness(0, 6, 0, 0),
            Text = "For personal playtesting only. Don't sell proxies or use them in sanctioned play.",
        });

        var close = MainWindow.Instance.ShowSheet("Quick tutorial", SheetParts.Scroll(steps), 820);
        var done = new Button { Content = "Got it, let's print!", FontSize = 20, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 14, 0, 6) };
        done.SetResourceReference(FrameworkElement.StyleProperty, "FantasyButton");
        done.Click += (_, _) => close();
        steps.Children.Add(done);
    }

    /// One numbered step: a gold medallion, a title, and its lines.
    private static FrameworkElement Step(int number, string title, string[] lines, FrameworkElement? extra = null)
    {
        var medal = new Grid { Width = 40, Height = 40, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 14, 0) };
        medal.Children.Add(new System.Windows.Shapes.Ellipse
        {
            Fill = new LinearGradientBrush(Color.FromRgb(250, 222, 128), Color.FromRgb(160, 112, 36), 90),
            Stroke = Theme.Brush(Theme.Ivory, 0.9), StrokeThickness = 2,
        });
        medal.Children.Add(new TextBlock
        {
            Text = number.ToString(), FontFamily = Theme.Plaque, FontWeight = FontWeights.Black, FontSize = 21,
            Foreground = Theme.Brush(Theme.Ink), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        });

        var body = new StackPanel();
        body.Children.Add(new OutlinedText { Text = title, Size = 25, Margin = new Thickness(0, 0, 0, 2) });
        foreach (var line in lines) body.Children.Add(Line(line));
        if (extra != null) body.Children.Add(extra);

        var row = new DockPanel { Margin = new Thickness(0, 6, 0, 14) };
        DockPanel.SetDock(medal, Dock.Left);
        row.Children.Add(medal);
        row.Children.Add(body);
        return row;
    }

    /// A line of help text; **words** in double asterisks are the names
    /// of buttons and settings, set in bold gold.
    private static TextBlock Line(string text)
    {
        var block = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, FontFamily = Theme.Fell, FontSize = 18, Margin = new Thickness(0, 3, 0, 3),
            Foreground = Theme.Brush(Theme.Parchment, 0.94),
        };
        var parts = text.Split("**");
        for (var i = 0; i < parts.Length; i++)
        {
            if (parts[i].Length == 0) continue;
            block.Inlines.Add(i % 2 == 1
                ? new Run(parts[i]) { FontWeight = FontWeights.Bold, Foreground = Theme.Brush(Theme.Gold) }
                : new Run(parts[i]));
        }
        return block;
    }
}
