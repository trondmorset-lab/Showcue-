using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using ShowCue.Engine;
using ShowCue.Models;

namespace ShowCue;

/// <summary>
/// Redigering av start- og sluttpunkt i en lyd- eller video-cue: bølgeform med dra-bare markører,
/// zoom, og forhåndslytting gjennom lydpatchen.
/// </summary>
public sealed class WaveformEditor : UserControl
{
    /// <summary>Settes av hovedvinduet ved oppstart.</summary>
    public static CueEngine? Engine { get; set; }

    public static readonly DependencyProperty CueProperty = DependencyProperty.Register(
        nameof(Cue), typeof(ITrimmable), typeof(WaveformEditor), new PropertyMetadata(null, (d, e) => ((WaveformEditor)d).OnCueChanged(e)));

    public static readonly DependencyProperty LargeProperty = DependencyProperty.Register(
        nameof(Large), typeof(bool), typeof(WaveformEditor), new PropertyMetadata(false, (d, _) => ((WaveformEditor)d).ApplySize()));

    public ITrimmable? Cue { get => (ITrimmable?)GetValue(CueProperty); set => SetValue(CueProperty, value); }
    /// <summary>Stort redigeringsvindu (høyere bølgeform, ingen «åpne stort»-knapp).</summary>
    public bool Large { get => (bool)GetValue(LargeProperty); set => SetValue(LargeProperty, value); }

    private readonly WaveCanvas _canvas;
    private readonly ScrollBar _scroll;
    private readonly TextBlock _info = new() { FontSize = 11.5, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _bigButton;
    private readonly Button _stopButton;
    private int _loadId;

    public WaveformEditor()
    {
        _canvas = new WaveCanvas(this);
        _scroll = new ScrollBar { Orientation = Orientation.Horizontal, Height = 12, Minimum = 0, SmallChange = 1 };
        _scroll.Scroll += (_, _) => { _canvas.ViewStart = _scroll.Value; _canvas.InvalidateVisual(); };

        var playRow = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        playRow.Children.Add(MakeButton("▶ Fra start", "Lytt fra startpunktet (gjennom lydpatchen)", () => PlayFrom(Cue?.StartTime ?? 0)));
        playRow.Children.Add(MakeButton("▶ Fra markør", "Lytt fra den blå markøren. Klikk i bølgeformen for å flytte markøren, dobbeltklikk for å lytte derfra.", () => PlayFrom(_canvas.CursorTime)));
        playRow.Children.Add(MakeButton("▶ Slutten", "Lytt til de siste 5 sekundene før sluttpunktet", () => PlayFrom(Math.Max(Cue?.StartTime ?? 0, _canvas.EffectiveEnd - 5))));
        _stopButton = MakeButton("■ Stopp", "Stopp forhåndslyttingen", () => Engine?.Preview.Stop());
        playRow.Children.Add(_stopButton);

        var editRow = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        editRow.Children.Add(MakeButton("Start = markør", "Sett startpunktet der markøren (eller lyttingen) er nå", () => SetStart(CurrentPoint())));
        editRow.Children.Add(MakeButton("Slutt = markør", "Sett sluttpunktet der markøren (eller lyttingen) er nå", () => SetEnd(CurrentPoint())));
        editRow.Children.Add(MakeButton("Nullstill", "Hele fila: start 0, slutt = filslutt", () => { if (Cue != null) { Cue.StartTime = 0; Cue.EndTime = 0; } }));
        editRow.Children.Add(MakeButton("−", "Zoom ut (eller musehjul)", () => _canvas.Zoom(2, null)));
        editRow.Children.Add(MakeButton("+", "Zoom inn (eller musehjul)", () => _canvas.Zoom(0.5, null)));
        editRow.Children.Add(MakeButton("Hele", "Vis hele fila", () => _canvas.ZoomAll()));
        _bigButton = MakeButton("⤢ Stort vindu", "Åpne et stort redigeringsvindu", OpenLarge);
        editRow.Children.Add(_bigButton);

        var border = new Border
        {
            Child = _canvas,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(3),
            ClipToBounds = true,
        };
        border.SetResourceReference(Border.BorderBrushProperty, "Line");
        _info.SetResourceReference(TextBlock.ForegroundProperty, "Muted");

        var root = new StackPanel();
        root.Children.Add(_info);
        root.Children.Add(border);
        root.Children.Add(_scroll);
        root.Children.Add(playRow);
        root.Children.Add(editRow);
        Content = root;
        ApplySize();

        Loaded += (_, _) =>
        {
            ThemeManager.Changed += _canvas.InvalidateVisual;
            if (Engine != null) { Engine.Ticked += OnTick; Engine.Preview.Changed += OnPreviewChanged; }
            OnPreviewChanged();
        };
        Unloaded += (_, _) =>
        {
            ThemeManager.Changed -= _canvas.InvalidateVisual;
            if (Engine != null) { Engine.Ticked -= OnTick; Engine.Preview.Changed -= OnPreviewChanged; }
        };
    }

    private static Button MakeButton(string text, string tip, Action onClick)
    {
        var b = new Button { Content = text, ToolTip = tip, Margin = new Thickness(0, 0, 6, 4), Padding = new Thickness(8, 3, 8, 3), FontSize = 11.5 };
        b.Click += (_, _) => onClick();
        return b;
    }

    private void ApplySize()
    {
        _canvas.Height = Large ? 360 : 120;
        _bigButton.Visibility = Large ? Visibility.Collapsed : Visibility.Visible;
    }

    // ------------------------------------------------------------------
    private void OnCueChanged(DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is INotifyPropertyChanged o) o.PropertyChanged -= OnCuePropertyChanged;
        if (e.NewValue is INotifyPropertyChanged n) n.PropertyChanged += OnCuePropertyChanged;
        _canvas.ViewStart = 0;
        _canvas.ViewLength = 0;
        _canvas.CursorTime = Cue?.StartTime ?? 0;
        LoadWaveform();
    }

    private void OnCuePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ITrimmable.FilePath)) { _canvas.ViewLength = 0; LoadWaveform(); return; }
        Refresh();
    }

    private async void LoadWaveform()
    {
        var cue = Cue;
        int id = ++_loadId;
        _canvas.Data = null;
        _canvas.Status = cue == null || string.IsNullOrEmpty(cue.FilePath) ? "Ingen fil valgt" : "Leser bølgeform …";
        Refresh();
        if (cue == null || string.IsNullOrEmpty(cue.FilePath)) return;
        var data = await WaveformCache.Get(cue.FilePath, cue.IsVideo);
        if (id != _loadId) return;
        _canvas.Data = data;
        _canvas.Status = data == null ? (cue.IsVideo ? "Videoen har ikke noe lydspor – markørene virker likevel" : "Kunne ikke lese fila") : null;
        Refresh();
    }

    /// <summary>Tegn på nytt og oppdater tekst og rullefelt.</summary>
    private void Refresh()
    {
        var cue = Cue;
        double len = _canvas.Length;
        if (_canvas.ViewLength <= 0 || _canvas.ViewLength > len) { _canvas.ViewLength = len; _canvas.ViewStart = 0; }
        _scroll.Maximum = Math.Max(0, len - _canvas.ViewLength);
        _scroll.ViewportSize = Math.Max(0.001, _canvas.ViewLength);
        _scroll.LargeChange = Math.Max(0.001, _canvas.ViewLength * 0.8);
        _scroll.SmallChange = Math.Max(0.001, _canvas.ViewLength * 0.05);
        _scroll.Value = _canvas.ViewStart;
        _scroll.Visibility = len > 0 && _canvas.ViewLength < len - 1e-6 ? Visibility.Visible : Visibility.Hidden;

        if (cue == null) _info.Text = "";
        else
        {
            var end = _canvas.EffectiveEnd;
            _info.Text = len <= 0
                ? "Start " + Fmt(cue.StartTime) + "   Slutt " + (cue.EndTime > 0 ? Fmt(cue.EndTime) : "filslutt")
                : $"Start {Fmt(cue.StartTime)}   Slutt {(cue.EndTime > 0 ? Fmt(end) : Fmt(end) + " (filslutt)")}   Lengde {Fmt(Math.Max(0, end - cue.StartTime))}   Markør {Fmt(_canvas.CursorTime)}";
        }
        _canvas.InvalidateVisual();
    }

    internal void ViewChanged() => Refresh();

    public static string Fmt(double s)
    {
        if (s < 0) s = 0;
        int m = (int)(s / 60);
        return m.ToString(CultureInfo.InvariantCulture) + ":" + (s - m * 60).ToString("00.00", CultureInfo.InvariantCulture);
    }

    // ------------------------------------------------------------------
    // Forhåndslytting
    private bool PreviewingThis => Engine?.Preview is { IsPlaying: true } p && ReferenceEquals(p.Cue, Cue);

    private double CurrentPoint() => PreviewingThis && Engine!.Preview.Position is double p ? p : _canvas.CursorTime;

    internal void PlayFrom(double t)
    {
        if (Engine == null || Cue is not ShowCue.Models.Cue c) return;
        if (!Engine.Audio.IsRunning) { MessageBox.Show("Lydutgangen er ikke startet. Sjekk Innstillinger → Lyd.", "ShowCue"); return; }
        if (!Engine.Preview.Play(c, t, Cue.EndTime))
            MessageBox.Show("Klarte ikke å spille av lyden i denne cuen.", "ShowCue");
    }

    private void OnTick()
    {
        double? pos = PreviewingThis ? Engine!.Preview.Position : null;
        if (pos != _canvas.PlayTime)
        {
            _canvas.PlayTime = pos;
            if (pos is double p && _canvas.ViewLength > 0 && (p > _canvas.ViewStart + _canvas.ViewLength || p < _canvas.ViewStart))
            {
                _canvas.ViewStart = Math.Clamp(p - _canvas.ViewLength * 0.1, 0, Math.Max(0, _canvas.Length - _canvas.ViewLength));
                Refresh();
            }
            else _canvas.InvalidateVisual();
        }
    }

    private void OnPreviewChanged()
    {
        _stopButton.IsEnabled = PreviewingThis;
        if (!PreviewingThis && _canvas.PlayTime != null) { _canvas.PlayTime = null; _canvas.InvalidateVisual(); }
    }

    // ------------------------------------------------------------------
    // Markører
    internal const double MinLength = 0.05;

    internal void SetStart(double t)
    {
        if (Cue == null) return;
        var end = _canvas.EffectiveEnd;
        if (end > 0) t = Math.Min(t, end - MinLength);
        Cue.StartTime = Math.Round(Math.Max(0, t), 3);
    }

    internal void SetEnd(double t)
    {
        if (Cue == null) return;
        t = Math.Max(t, Cue.StartTime + MinLength);
        double len = _canvas.Length;
        Cue.EndTime = len > 0 && t >= len - 0.005 ? 0 : Math.Round(t, 3);   // helt til slutten = «filslutt»
    }

    private void OpenLarge()
    {
        if (Cue == null) return;
        var ed = new WaveformEditor { Large = true, Cue = Cue, Margin = new Thickness(14) };
        var fields = new WrapPanel { Margin = new Thickness(14, 0, 14, 14) };
        fields.Children.Add(Field("Start (s)", nameof(ITrimmable.StartTime)));
        fields.Children.Add(Field("Slutt (s, 0 = filslutt)", nameof(ITrimmable.EndTime)));
        var panel = new DockPanel();
        DockPanel.SetDock(fields, Dock.Bottom);
        panel.Children.Add(fields);
        panel.Children.Add(ed);

        var w = new Window
        {
            Title = "Rediger start og slutt – " + ((Cue as ShowCue.Models.Cue)?.DisplayName ?? ""),
            Width = 1100, Height = 620, MinWidth = 600, MinHeight = 400,
            Owner = Window.GetWindow(this),
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = panel,
            DataContext = Cue,
        };
        w.SetResourceReference(BackgroundProperty, "Bg");
        w.SetResourceReference(ForegroundProperty, "Text");
        w.Closed += (_, _) => { if (ReferenceEquals(Engine?.Preview.Cue, Cue)) Engine?.Preview.Stop(); };
        w.Show();

        FrameworkElement Field(string label, string path)
        {
            var sp = new StackPanel { Width = 200, Margin = new Thickness(0, 0, 14, 0) };
            var tb = new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, 3) };
            tb.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
            var box = new TextBox();
            box.SetBinding(TextBox.TextProperty, new System.Windows.Data.Binding(path) { UpdateSourceTrigger = System.Windows.Data.UpdateSourceTrigger.LostFocus });
            sp.Children.Add(tb);
            sp.Children.Add(box);
            return sp;
        }
    }

    // ==================================================================
    /// <summary>Selve bølgeformen med markører.</summary>
    private sealed class WaveCanvas : FrameworkElement
    {
        private readonly WaveformEditor _owner;
        public WaveformData? Data;
        public string? Status;
        public double ViewStart, ViewLength;
        public double CursorTime;
        public double? PlayTime;

        private enum Drag { None, Start, End, Cursor }
        private Drag _drag;
        private const double Grab = 7;

        public WaveCanvas(WaveformEditor owner)
        {
            _owner = owner;
            Focusable = true;
            ClipToBounds = true;
            SizeChanged += (_, _) => InvalidateVisual();
        }

        private ITrimmable? Cue => _owner.Cue;

        /// <summary>Lengden på hele fila (fra bølgeformen, ellers fra cuen).</summary>
        public double Length
        {
            get
            {
                double d = Data?.Duration ?? 0;
                if (d <= 0) d = Cue?.MediaLength ?? 0;
                if (d <= 0 && Cue != null) d = Math.Max(Cue.EndTime, Cue.StartTime) + 1;
                return d;
            }
        }

        public double EffectiveEnd
        {
            get
            {
                if (Cue == null) return 0;
                double len = Length;
                return Cue.EndTime > 0 ? (len > 0 ? Math.Min(Cue.EndTime, len) : Cue.EndTime) : len;
            }
        }

        private double X(double t) => ViewLength <= 0 ? 0 : (t - ViewStart) / ViewLength * ActualWidth;
        private double T(double x) => ViewStart + x / Math.Max(1, ActualWidth) * ViewLength;

        private Brush Res(string key, Color fallback) => TryFindResource(key) as Brush ?? new SolidColorBrush(fallback);

        protected override void OnRender(DrawingContext dc)
        {
            double w = ActualWidth, h = ActualHeight;
            if (w <= 0 || h <= 0) return;
            const double ruler = 16;
            var bg = Res("Panel3", Colors.DimGray);
            var text = Res("Text", Colors.White);
            var muted = Res("Muted", Colors.Gray);
            var line = Res("Line", Colors.Gray);
            var go = Res("Go", Colors.LimeGreen);
            var danger = Res("Danger", Colors.Red);
            var playhead = Res("Playhead", Colors.DodgerBlue);
            var wait = Res("Wait", Colors.Orange);
            dc.DrawRectangle(bg, null, new Rect(0, 0, w, h));

            var typeface = new Typeface("Segoe UI");
            double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            void Label(string s, double x, double y, Brush b)
                => dc.DrawText(new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, typeface, 10, b, dpi), new Point(x, y));

            var cue = Cue;
            if (cue == null || ViewLength <= 0)
            {
                if (Status != null) Label(Status, 8, h / 2 - 7, muted);
                return;
            }

            // Tidslinjal
            double step = NiceStep(ViewLength / Math.Max(1, w / 90));
            var linePen = new Pen(line, 1); linePen.Freeze();
            for (double t = Math.Floor(ViewStart / step) * step; t <= ViewStart + ViewLength; t += step)
            {
                double x = Math.Round(X(t)) + 0.5;
                if (x < 0) continue;
                dc.DrawLine(linePen, new Point(x, 0), new Point(x, ruler));
                Label(Fmt(t), x + 3, 1, muted);
            }
            dc.DrawLine(linePen, new Point(0, ruler + 0.5), new Point(w, ruler + 0.5));

            double top = ruler + 2, mid = (top + h) / 2, amp = (h - top) / 2 - 2;

            // Bølgeform
            if (Data is { Buckets: > 0 } d)
            {
                var waveBrush = Res("Muted", Colors.Gray);
                var geo = new StreamGeometry();
                using (var g = geo.Open())
                {
                    double bPerSec = d.Buckets / Math.Max(1e-6, d.Duration);
                    for (int px = 0; px < (int)w; px++)
                    {
                        double t0 = T(px), t1 = T(px + 1);
                        int b0 = (int)Math.Floor(t0 * bPerSec), b1 = (int)Math.Ceiling(t1 * bPerSec);
                        if (b1 <= 0 || b0 >= d.Buckets) continue;
                        b0 = Math.Max(0, b0); b1 = Math.Min(d.Buckets, Math.Max(b1, b0 + 1));
                        float mn = 0, mx = 0;
                        for (int b = b0; b < b1; b++) { if (d.Min[b] < mn) mn = d.Min[b]; if (d.Max[b] > mx) mx = d.Max[b]; }
                        double y0 = mid - Math.Min(1, mx) * amp, y1 = mid - Math.Max(-1, mn) * amp;
                        if (y1 - y0 < 1) { y0 = mid - 0.5; y1 = mid + 0.5; }
                        g.BeginFigure(new Point(px, y0), true, true);
                        g.LineTo(new Point(px + 1, y0), false, false);
                        g.LineTo(new Point(px + 1, y1), false, false);
                        g.LineTo(new Point(px, y1), false, false);
                    }
                }
                geo.Freeze();
                dc.DrawGeometry(waveBrush, null, geo);
            }
            else if (Status != null) Label(Status, 8, mid - 7, muted);

            // Skygge utenfor start–slutt
            double start = cue.StartTime, end = EffectiveEnd;
            var shade = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)); shade.Freeze();
            double xs = X(start), xe = X(end);
            if (xs > 0) dc.DrawRectangle(shade, null, new Rect(0, top, Math.Min(w, xs), h - top));
            if (xe < w) dc.DrawRectangle(shade, null, new Rect(Math.Max(0, xe), top, w - Math.Max(0, xe), h - top));

            // Fader
            var fadePen = new Pen(wait, 1.5); fadePen.Freeze();
            if (cue.FadeIn > 0)
                dc.DrawLine(fadePen, new Point(xs, h - 1), new Point(X(Math.Min(end, start + cue.FadeIn)), top + 1));
            if (cue.FadeOut > 0 && !cue.Loop && !cue.IsVideo)
                dc.DrawLine(fadePen, new Point(X(Math.Max(start, end - cue.FadeOut)), top + 1), new Point(xe, h - 1));

            // Markør og avspillingsposisjon
            var curPen = new Pen(playhead, 1) { DashStyle = DashStyles.Dash }; curPen.Freeze();
            double xc = Math.Round(X(CursorTime)) + 0.5;
            dc.DrawLine(curPen, new Point(xc, top), new Point(xc, h));
            if (PlayTime is double p)
            {
                var playPen = new Pen(text, 1.5); playPen.Freeze();
                double xp = X(p);
                dc.DrawLine(playPen, new Point(xp, top), new Point(xp, h));
            }

            // Start- og sluttmarkør med «flagg»
            DrawHandle(dc, xs, top, h, go, true);
            DrawHandle(dc, xe, top, h, danger, false);
        }

        private static void DrawHandle(DrawingContext dc, double x, double top, double h, Brush b, bool isStart)
        {
            var pen = new Pen(b, 2); pen.Freeze();
            dc.DrawLine(pen, new Point(x, top), new Point(x, h));
            var g = new StreamGeometry();
            using (var c = g.Open())
            {
                double dir = isStart ? 1 : -1;
                c.BeginFigure(new Point(x, top), true, true);
                c.LineTo(new Point(x + 10 * dir, top), true, false);
                c.LineTo(new Point(x, top + 10), true, false);
            }
            g.Freeze();
            dc.DrawGeometry(b, null, g);
        }

        private static double NiceStep(double raw)
        {
            double[] steps = { 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600 };
            foreach (var s in steps) if (s >= raw) return s;
            return 3600;
        }

        // ------------------------------------------------------------------
        public void Zoom(double factor, double? aroundX)
        {
            double len = Length;
            if (len <= 0) return;
            double anchorT = aroundX is double ax ? T(ax) : (PlayTime ?? CursorTime);
            double frac = ViewLength > 0 ? (anchorT - ViewStart) / ViewLength : 0.5;
            if (aroundX == null) frac = Math.Clamp(frac, 0, 1);
            double newLen = Math.Clamp(ViewLength * factor, Math.Min(len, 0.05), len);
            ViewStart = Math.Clamp(anchorT - frac * newLen, 0, Math.Max(0, len - newLen));
            ViewLength = newLen;
            _owner.ViewChanged();
        }

        public void ZoomAll()
        {
            ViewStart = 0;
            ViewLength = Length;
            _owner.ViewChanged();
        }

        private Drag HitTest(double x)
        {
            if (Cue == null) return Drag.Cursor;
            double xs = X(Cue.StartTime), xe = X(EffectiveEnd);
            double ds = Math.Abs(x - xs), de = Math.Abs(x - xe);
            if (ds <= Grab && ds <= de) return Drag.Start;
            if (de <= Grab) return Drag.End;
            return Drag.Cursor;
        }

        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            if (Cue == null || ViewLength <= 0) return;
            Focus();
            double x = e.GetPosition(this).X;
            if (e.ClickCount == 2)
            {
                CursorTime = Math.Clamp(T(x), 0, Length);
                _owner.PlayFrom(CursorTime);
                _owner.ViewChanged();
                e.Handled = true;
                return;
            }
            _drag = HitTest(x);
            CaptureMouse();
            Apply(x);
            e.Handled = true;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            double x = e.GetPosition(this).X;
            if (_drag != Drag.None && e.LeftButton == MouseButtonState.Pressed) { Apply(x); return; }
            Cursor = HitTest(x) is Drag.Start or Drag.End ? Cursors.SizeWE : Cursors.IBeam;
        }

        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            _drag = Drag.None;
            ReleaseMouseCapture();
        }

        private void Apply(double x)
        {
            double t = Math.Clamp(T(Math.Clamp(x, 0, ActualWidth)), 0, Length);
            switch (_drag)
            {
                case Drag.Start: _owner.SetStart(t); break;
                case Drag.End: _owner.SetEnd(t); break;
                case Drag.Cursor: CursorTime = t; _owner.ViewChanged(); break;
            }
        }

        protected override void OnMouseWheel(MouseWheelEventArgs e)
        {
            if (ViewLength <= 0) return;
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
            {
                double len = Length;
                ViewStart = Math.Clamp(ViewStart - Math.Sign(e.Delta) * ViewLength * 0.15, 0, Math.Max(0, len - ViewLength));
                _owner.ViewChanged();
            }
            else Zoom(e.Delta > 0 ? 0.7 : 1 / 0.7, e.GetPosition(this).X);
            e.Handled = true;
        }
    }
}
