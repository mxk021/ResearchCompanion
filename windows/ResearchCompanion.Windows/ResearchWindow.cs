using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace ResearchCompanion.Windows;

internal sealed partial class ResearchWindow : Window
{
    private readonly WindowsSelection selectionProvider = new();
    private readonly WindowsTranscript transcript = new();
    private readonly Forms.NotifyIcon tray = new();
    private readonly Grid layout = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock materialName = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBox selectionPreview = new() {
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 117,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Visibility = Visibility.Collapsed
    };
    private readonly TextBox composer = new() {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 66, MaxHeight = 145,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto
    };
    private readonly Button send = new() { Content = "发送", IsEnabled = false };
    private readonly Button modelButton = new() { Content = "选择模型" };
    private readonly Button removeFile = new() { Content = "移除文件", Visibility = Visibility.Collapsed };
    private readonly Button removeSelection = new() { Content = "移除选区", Visibility = Visibility.Collapsed };
    private readonly Button manual = new() { Content = "粘贴选区…", Visibility = Visibility.Collapsed };
    private readonly Button cancel = new() { Content = "停止等待", Visibility = Visibility.Collapsed };
    private readonly Button reconnect = new() { Content = "连接 DSH" };
    private readonly Button pin = new() { Content = "固定窗口" };
    private readonly CheckBox include = new() { Content = "带入材料", IsChecked = true, VerticalAlignment = VerticalAlignment.Center };
    private readonly Image brand = new() { Width = 25, Height = 25 };
    private readonly List<Border> panels = new();
    private readonly List<Button> buttons = new();
    private readonly CancellationTokenSource lifetime = new();
    private UserSettings settings = UserSettings.Load();
    private PdfEvidence? document;
    private WindowsSelectionResult? selection;
    private CancellationTokenSource? waiting;
    private bool quitting;
    private bool busy;
    private bool dark;
    private int jump;

    internal ResearchWindow()
    {
        Title = "科研助手";
        Width = 640;
        Height = 822;
        MinWidth = 460;
        MinHeight = 480;
        Topmost = settings.Topmost;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ConfigureLayout();
        ConfigureTray();
        ApplyTheme();
        UpdateMaterial();
        composer.Text = settings.Draft;
        Closing += OnClosing;
        Closed += (_, _) =>
        {
            lifetime.Cancel();
            SystemEvents.UserPreferenceChanged -= OnThemeChanged;
            tray.Visible = false;
            tray.Dispose();
            selectionProvider.Dispose();
            transcript.Dispose();
            lifetime.Dispose();
        };
        SystemEvents.UserPreferenceChanged += OnThemeChanged;
        SourceInitialized += (_, _) => ApplyTitleBar();
        Loaded += FirstLoad;
        Activated += (_, _) => selectionProvider.Observe();
        transcript.Interaction += input => _ = HandleTranscriptAsync(input);
        AutoLabel(composer, "输入问题");
        AutoLabel(selectionPreview, "本次选区原文");
    }

    private static void AutoLabel(DependencyObject control, string text) =>
        System.Windows.Automation.AutomationProperties.SetName(control, text);

    private void ConfigureLayout()
    {
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Content = layout;
        FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI");

        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 10), LastChildFill = true };
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(actions, Dock.Right);
        actions.Children.Add(Tool(modelButton, async () => await PickModelAsync()));
        actions.Children.Add(Tool("历史", async () => await ShowHistoryAsync()));
        actions.Children.Add(Tool("新建", async () => await OpenSessionAsync(null)));
        actions.Children.Add(Tool(pin, () => { TogglePin(); return Task.CompletedTask; }));
        header.Children.Add(actions);
        var identity = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        identity.Children.Add(brand);
        identity.Children.Add(new TextBlock {
            Text = "科研助手", FontSize = 15, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0)
        });
        header.Children.Add(identity);

        var material = new StackPanel();
        var materialControls = new WrapPanel();
        materialControls.Children.Add(Tool("选取文字", async () => await CaptureAsync()));
        materialControls.Children.Add(Tool("选择文件…", async () => await ImportAsync()));
        materialControls.Children.Add(Tool(manual, async () => await ManualSelectionAsync()));
        materialControls.Children.Add(Tool(removeFile, async () => { document = null; UpdateMaterial(); await RenderAsync(); }));
        materialControls.Children.Add(Tool(removeSelection, async () => { selection = null; UpdateMaterial(); await RenderAsync(); }));
        include.Margin = new Thickness(7, 2, 0, 3);
        materialControls.Children.Add(include);
        material.Children.Add(materialControls);
        materialName.Margin = new Thickness(0, 6, 0, 2);
        material.Children.Add(materialName);
        selectionPreview.Margin = new Thickness(0, 5, 0, 0);
        material.Children.Add(selectionPreview);
        var top = new StackPanel { Margin = new Thickness(18, 10, 18, 12) };
        top.Children.Add(header);
        top.Children.Add(Panel(material));
        layout.Children.Add(top);

        Grid.SetRow(transcript.Control, 1);
        layout.Children.Add(transcript.Control);
        var bottom = new StackPanel { Margin = new Thickness(18, 8, 18, 8) };
        composer.BorderThickness = new Thickness(0);
        composer.Padding = new Thickness(4, 4, 4, 2);
        composer.PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control)
            {
                e.Handled = true;
                await RunUiAsync(SendAsync);
            }
        };
        composer.TextChanged += (_, _) => { if (!busy) RefreshSendButton(); };
        var entry = new StackPanel();
        entry.Children.Add(composer);
        var footer = new DockPanel { Margin = new Thickness(3, 4, 0, 0), LastChildFill = true };
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(right, Dock.Right);
        right.Children.Add(Tool(cancel, () => { waiting?.Cancel(); return Task.CompletedTask; }));
        right.Children.Add(Tool(send, SendAsync));
        footer.Children.Add(right);
        footer.Children.Add(new TextBlock { Text = "Ctrl+Enter 发送", VerticalAlignment = VerticalAlignment.Center, FontSize = 11 });
        entry.Children.Add(footer);
        bottom.Children.Add(Panel(entry));

        var connection = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 7, 0, 0) };
        DockPanel.SetDock(reconnect, Dock.Right);
        connection.Children.Add(Tool(reconnect, ConnectAsync));
        status.VerticalAlignment = VerticalAlignment.Center;
        status.FontSize = 12;
        connection.Children.Add(status);
        status.Text = "正在检查科研桥…";
        bottom.Children.Add(connection);
        Grid.SetRow(bottom, 2);
        layout.Children.Add(bottom);
    }

    private Border Panel(UIElement child)
    {
        var border = new Border {
            Padding = new Thickness(9), CornerRadius = new CornerRadius(9),
            BorderThickness = new Thickness(1), Child = child
        };
        panels.Add(border);
        return border;
    }

    private Button Tool(string label, Func<Task> action) => Tool(new Button { Content = label }, action);
    private Button Tool(Button button, Func<Task> action)
    {
        button.MinHeight = 29;
        button.Margin = new Thickness(0, 0, 5, 3);
        button.Padding = new Thickness(9, 3, 9, 3);
        button.Cursor = Cursors.Hand;
        button.Click += async (_, _) => await RunUiAsync(action);
        buttons.Add(button);
        return button;
    }

    private async void FirstLoad(object sender, RoutedEventArgs e)
    {
        Loaded -= FirstLoad;
        try
        {
            await transcript.StartAsync(App.Profile);
            await RenderAsync();
        }
        catch (Exception error) { status.Text = "会话渲染不可用，请检查 Microsoft Edge WebView2 Runtime。 " + error.Message; return; }
        await RunUiAsync(ConnectAsync);
    }

    private async Task RunUiAsync(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) when (quitting) { }
        catch (Exception error) { status.Text = error.Message; }
    }

    private void ConfigureTray()
    {
        tray.Text = "Research Companion · 科研助手";
        var icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        if (icon != null) tray.Icon = icon;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示科研助手", null, (_, _) => Dispatcher.Invoke(ShowMainWindow));
        menu.Items.Add("固定窗口", null, (_, _) => Dispatcher.Invoke(TogglePin));
        var theme = new Forms.ToolStripMenuItem("外观");
        foreach (var pair in new[] { ("跟随系统", "system"), ("浅色", "light"), ("深色", "dark") })
            theme.DropDownItems.Add(pair.Item1, null, (_, _) => Dispatcher.Invoke(() =>
            {
                settings = settings with { Theme = pair.Item2 };
                ApplyTheme();
                SaveSettings();
            }));
        menu.Items.Add(theme);
        menu.Items.Add("退出", null, (_, _) => Dispatcher.Invoke(() =>
        {
            quitting = true;
            Application.Current.Shutdown();
        }));
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMainWindow);
        tray.Visible = true;
        TogglePinLabel();
    }

    private void ShowMainWindow()
    {
        selectionProvider.Observe();
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        composer.Focus();
    }

    private void TogglePin()
    {
        Topmost = !Topmost;
        settings = settings with { Topmost = Topmost };
        TogglePinLabel();
        SaveSettings();
    }

    private void TogglePinLabel() => pin.Content = Topmost ? "取消固定" : "固定窗口";

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        SaveSettings();
        if (quitting || tray.Icon == null) return;
        e.Cancel = true;
        Hide();
    }

    private void SaveSettings()
    {
        settings = settings with { Draft = composer.Text, Workspace = workspace, Session = session };
        settings.Save();
    }

    private void OnThemeChanged(object sender, UserPreferenceChangedEventArgs args) =>
        Dispatcher.InvokeAsync(ApplyTheme);

    private void ApplyTheme()
    {
        dark = settings.Theme == "dark" || settings.Theme == "system" && App.SystemDark;
        var paper = ColorBrush(dark ? "#121821" : "#f7f9fc");
        var raised = ColorBrush(dark ? "#1c2533" : "#ffffff");
        var ink = ColorBrush(dark ? "#e7edf6" : "#182235");
        var hint = ColorBrush(dark ? "#b5c0d3" : "#53617a");
        var rule = ColorBrush(dark ? "#334155" : "#d8e0eb");
        var accent = ColorBrush(dark ? "#86b7ff" : "#1955ce");
        Background = paper;
        Foreground = ink;
        foreach (var panel in panels) { panel.Background = raised; panel.BorderBrush = rule; }
        foreach (var button in buttons)
        {
            button.Background = raised;
            button.Foreground = ink;
            button.BorderBrush = rule;
            var frame = new FrameworkElementFactory(typeof(Border));
            frame.SetValue(Border.CornerRadiusProperty, new CornerRadius(7));
            frame.SetValue(Border.BorderThicknessProperty, new Thickness(1));
            frame.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding(nameof(Button.Background)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
            frame.SetBinding(Border.BorderBrushProperty, new System.Windows.Data.Binding(nameof(Button.BorderBrush)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
            var content = new FrameworkElementFactory(typeof(ContentPresenter));
            content.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            content.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            content.SetBinding(FrameworkElement.MarginProperty, new System.Windows.Data.Binding(nameof(Button.Padding)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
            frame.AppendChild(content);
            var template = new ControlTemplate(typeof(Button)) { VisualTree = frame };
            var disabled = new Trigger { Property = IsEnabledProperty, Value = false };
            disabled.Setters.Add(new Setter(OpacityProperty, 0.45));
            template.Triggers.Add(disabled);
            var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
            hover.Setters.Add(new Setter(BorderBrushProperty, accent));
            template.Triggers.Add(hover);
            button.Template = template;
        }
        foreach (var box in new[] { composer, selectionPreview })
        {
            box.Background = raised; box.Foreground = ink; box.CaretBrush = accent;
            box.BorderBrush = rule;
        }
        send.Background = accent;
        send.Foreground = ColorBrush(dark ? "#121821" : "#ffffff");
        status.Foreground = materialName.Foreground = hint;
        brand.Source = LoadBrandMark(dark);
        ApplyTitleBar();
        _ = transcript.UpdateThemeAsync(dark);
    }

    private static SolidColorBrush ColorBrush(string hex) =>
        new((Color)ColorConverter.ConvertFromString(hex));

    private static BitmapSource? LoadBrandMark(bool inverse)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Transcript", "ResearchCompanionMark.png");
        if (!File.Exists(path)) return null;
        var image = new BitmapImage(new Uri(path));
        if (!inverse) return image;
        var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        var stride = converted.PixelWidth * 4;
        var pixels = new byte[stride * converted.PixelHeight];
        converted.CopyPixels(pixels, stride, 0);
        for (int i = 0; i < pixels.Length; i += 4)
            pixels[i] = pixels[i + 1] = pixels[i + 2] = 238;
        return BitmapSource.Create(converted.PixelWidth, converted.PixelHeight, 96, 96,
            PixelFormats.Bgra32, null, pixels, stride);
    }

    private void ApplyTitleBar()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        int value = dark ? 1 : 0;
        _ = DwmSetWindowAttribute(handle, 20, ref value, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    private void UpdateMaterial()
    {
        materialName.Text = document == null ? "当前无附带文件" :
            document.Title + (document.IsPdf ? " · " + document.PageCount + " 页" : " · 文本");
        removeFile.Visibility = document != null ? Visibility.Visible : Visibility.Collapsed;
        removeSelection.Visibility = selection != null ? Visibility.Visible : Visibility.Collapsed;
        selectionPreview.Visibility = removeSelection.Visibility;
        selectionPreview.Text = selection == null ? "" :
            $"{selection.Application} · {selection.Title ?? "出处未核验"}\n{selection.Text}";
        include.Visibility = (selection != null || document != null) ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task ImportAsync()
    {
        if (busy) return;
        var dialog = new OpenFileDialog { Filter = "科研材料|*.pdf;*.txt;*.md", CheckFileExists = true };
        if (dialog.ShowDialog(this) != true) return;
        status.Text = "正在检查文件…";
        SetBusy(true);
        try
        {
            document = await PdfEvidence.OpenAsync(dialog.FileName, lifetime.Token);
            status.Text = document.IsPdf ? "文件已关联。复杂版式需核对原页。" : "文本已关联。";
            UpdateMaterial();
            await RenderAsync();
        }
        finally { SetBusy(false); }
    }

    private async Task CaptureAsync()
    {
        if (busy) return;
        SetBusy(true);
        try
        {
            manual.Visibility = Visibility.Collapsed;
            selection = null;
            UpdateMaterial();
            status.Text = "正在读取选区…";
            try
            {
                selection = await selectionProvider.CaptureAsync(settings.AllowNativeCopy, lifetime.Token);
            }
            catch (InvalidOperationException e)
            {
                if (!settings.AllowNativeCopy &&
                    MessageBox.Show(this, e.Message + "\n\n是否允许在支持的阅读器中执行一次原生复制？这可能替换通用剪贴板。",
                        "选取文字", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                {
                    settings = settings with { AllowNativeCopy = true };
                    SaveSettings();
                    try { selection = await selectionProvider.CaptureAsync(true, lifetime.Token); }
                    catch (InvalidOperationException failure) { ShowPasteFallback(failure.Message); }
                }
                else ShowPasteFallback(e.Message);
            }
            if (selection != null) status.Text = selection.ProvenanceVerified ? "已读取选区" : "已读取选区 · 出处待核对";
            UpdateMaterial();
            await RenderAsync();
        }
        finally { SetBusy(false); }
    }

    private void ShowPasteFallback(string reason)
    {
        status.Text = reason;
        selection = null;
        manual.Visibility = Visibility.Visible;
    }

    private async Task ManualSelectionAsync()
    {
        if (busy) return;
        var editor = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var panel = new DockPanel { Margin = new Thickness(12) };
        var use = new Button { Content = "带入所粘贴的原文", Height = 30, Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(use, Dock.Bottom);
        panel.Children.Add(use);
        panel.Children.Add(editor);
        var dialog = Dialog("粘贴选区", panel, 485, 320);
        use.Click += (_, _) => { if (!string.IsNullOrWhiteSpace(editor.Text)) dialog.DialogResult = true; };
        if (dialog.ShowDialog() != true) return;
        selection = WindowsSelection.FromManual(editor.Text);
        manual.Visibility = Visibility.Collapsed;
        status.Text = "已带入手动粘贴的原文 · 出处未核验";
        UpdateMaterial();
        await RenderAsync();
    }

    private Window Dialog(string title, object content, double width, double height) => new()
    {
        Title = title, Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner,
        Width = width, Height = height, MinWidth = 320, MinHeight = 220, Content = content,
        Background = Background, Foreground = Foreground, FontFamily = FontFamily
    };

    private sealed record UserSettings(bool Topmost = false, string Theme = "system", bool AllowNativeCopy = false, string Draft = "",
        string? Workspace = null, string? Session = null)
    {
        private static string FilePath => Path.Combine(App.Profile, "window.json");
        internal static UserSettings Load()
        {
            try { return JsonSerializer.Deserialize<UserSettings>(File.ReadAllText(FilePath)) ?? new(); }
            catch (IOException) { return new(); }
            catch (JsonException) { return new(); }
        }
        internal void Save()
        {
            string temporary = FilePath + ".new";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, FilePath, overwrite: true);
        }
    }
}
