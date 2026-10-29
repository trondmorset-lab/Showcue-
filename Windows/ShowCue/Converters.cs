using System.Globalization;
using System.Windows;
using System.Windows.Data;
using ShowCue.Models;

namespace ShowCue;

/// <summary>Viser enum-verdier med norske navn.</summary>
public sealed class EnumTextConverter : IValueConverter
{
    private static readonly Dictionary<object, string> Names = new()
    {
        [ContinueMode.None] = "Ingen",
        [ContinueMode.AutoContinue] = "Auto-continue (start neste samtidig)",
        [ContinueMode.AutoFollow] = "Auto-follow (start neste når ferdig)",
        [VisualStretch.Uniform] = "Tilpass (behold format)",
        [VisualStretch.UniformToFill] = "Fyll (beskjær)",
        [VisualStretch.Fill] = "Strekk",
        [VisualStretch.None] = "Originalstørrelse",
        [MidiMessageType.NoteOn] = "Note on",
        [MidiMessageType.NoteOff] = "Note off",
        [MidiMessageType.ProgramChange] = "Program change",
        [MidiMessageType.ControlChange] = "Control change (CC)",
        [MidiMessageType.MscGo] = "MSC GO (MIDI Show Control)",
        [AudioDriverType.Wasapi] = "WASAPI (vanlige lydkort)",
        [AudioDriverType.Asio] = "ASIO (proff lydkort, lav latens)",
        [AppTheme.Dark] = "Mørk",
        [AppTheme.Light] = "Lys",
        [AppTheme.Night] = "Nattmodus (ekstra dempet)",
        [OscFeedbackFormat.Companion] = "Companion (Custom Variables)",
        [OscFeedbackFormat.Generic] = "Generisk (/showcue/…)",
        [CueColor.None] = "Ingen",
        [CueColor.Red] = "Rød",
        [CueColor.Orange] = "Oransje",
        [CueColor.Yellow] = "Gul",
        [CueColor.Green] = "Grønn",
        [CueColor.Blue] = "Blå",
        [CueColor.Purple] = "Lilla",
        [CueColor.Gray] = "Grå",
    };

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value != null && Names.TryGetValue(value, out var s) ? s : value?.ToString() ?? "";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => DependencyProperty.UnsetValue;
}

/// <summary>Kort symbol for continue-modus i cuelista.</summary>
public sealed class ContinueGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        ContinueMode.AutoContinue => "↓",
        ContinueMode.AutoFollow => "↧",
        _ => ""
    };
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => DependencyProperty.UnsetValue;
}

public sealed class InverseBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is bool b ? !b : value;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => value is bool b ? !b : value;
}

/// <summary>Synlig når verdien er lik parameteren (brukes til MIDI-felt).</summary>
public sealed class EqualsToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var match = parameter is string p && (p.Split('|').Contains(value?.ToString()));
        return match ^ Invert ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => DependencyProperty.UnsetValue;
}

/// <summary>Toppnivå (lineært) → høyde i prosent av meter (−60..0 dB).</summary>
public static class MeterMath
{
    public static double ToFraction(float peak)
    {
        if (peak <= 0.001f) return 0;
        var db = 20 * Math.Log10(peak);
        return Math.Clamp((db + 60) / 60.0, 0, 1);
    }
}

public static class EnumValues
{
    public static Array ContinueModes { get; } = Enum.GetValues(typeof(ContinueMode));
    public static Array Stretches { get; } = Enum.GetValues(typeof(VisualStretch));
    public static Array MidiTypes { get; } = Enum.GetValues(typeof(MidiMessageType));
    public static Array AudioDrivers { get; } = Enum.GetValues(typeof(AudioDriverType));
    public static Array Themes { get; } = Enum.GetValues(typeof(AppTheme));
    public static Array FeedbackFormats { get; } = Enum.GetValues(typeof(OscFeedbackFormat));
    public static Array CueColors { get; } = Enum.GetValues(typeof(CueColor));
}

public sealed class MidiTriggerTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value is string s && s.Length > 0 ? MidiTriggers.Describe(s) : "(ingen)";
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => DependencyProperty.UnsetValue;
}

public sealed class NonEmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value is string s && s.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => DependencyProperty.UnsetValue;
}

/// <summary>Cuefarge → penselen «Cue{Farge}Stripe» fra gjeldende tema (for fargevelgeren og hurtigknapper).</summary>
public sealed class CueColorBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not CueColor c || c == CueColor.None) return System.Windows.Media.Brushes.Transparent;
        return Application.Current.TryFindResource($"Cue{c}Stripe") as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.Transparent;
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => DependencyProperty.UnsetValue;
}
