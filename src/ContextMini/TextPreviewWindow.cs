using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ContextMini;

internal sealed class TextPreviewWindow : Window
{
    public TextPreviewWindow(Window owner, string title, string introduction, string preview)
    {
        Owner = owner;
        Title = title;
        Width = 820;
        Height = 620;
        MinWidth = 560;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SetResourceReference(BackgroundProperty, "WindowBackgroundBrush");
        SetResourceReference(ForegroundProperty, "PrimaryTextBrush");

        var grid = new Grid { Margin = new Thickness(20) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var message = new TextBlock
        {
            Text = introduction,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        };
        message.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryTextBrush");
        grid.Children.Add(message);

        var text = new TextBox
        {
            Text = preview,
            IsReadOnly = true,
            AcceptsReturn = true,
            AcceptsTab = true,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Padding = new Thickness(12),
        };
        text.SetResourceReference(Control.BackgroundProperty, "AlternateSurfaceBrush");
        text.SetResourceReference(Control.ForegroundProperty, "PrimaryTextBrush");
        text.SetResourceReference(Control.BorderBrushProperty, "ControlBorderBrush");
        Grid.SetRow(text, 1);
        grid.Children.Add(text);

        var close = new Button
        {
            Content = "关闭",
            MinWidth = 96,
            Padding = new Thickness(16, 8, 16, 8),
            Margin = new Thickness(0, 14, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            IsDefault = true,
            IsCancel = true,
        };
        close.Click += (_, _) => Close();
        Grid.SetRow(close, 2);
        grid.Children.Add(close);
        Content = grid;
    }
}
