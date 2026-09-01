using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace MBPhotos.Receiver.Wpf;

internal static class AppIconFactory
{
    public static Icon CreateTrayIcon(int size = 32)
    {
        using var bitmap = CreateBitmap(size);
        var handle = bitmap.GetHicon();
        try
        {
            using var borrowed = Icon.FromHandle(handle);
            return (Icon)borrowed.Clone();
        }
        finally
        {
            _ = DestroyIcon(handle);
        }
    }

    public static BitmapSource CreateWindowIcon(int size = 64)
    {
        using var icon = CreateTrayIcon(size);
        var source = Imaging.CreateBitmapSourceFromHIcon(
            icon.Handle,
            Int32Rect.Empty,
            BitmapSizeOptions.FromWidthAndHeight(size, size));
        source.Freeze();
        return source;
    }

    private static Bitmap CreateBitmap(int size)
    {
        var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.CompositingQuality = CompositingQuality.HighQuality;
        graphics.Clear(Color.Transparent);

        var scale = size / 32f;
        using var shadow = new SolidBrush(Color.FromArgb(45, 17, 24, 39));
        using var back = RoundedRectangle(5 * scale, 4 * scale, 22 * scale, 22 * scale, 6 * scale);
        graphics.TranslateTransform(0, 2 * scale);
        graphics.FillPath(shadow, back);
        graphics.ResetTransform();

        using var gradient = new LinearGradientBrush(
            new PointF(5 * scale, 4 * scale),
            new PointF(27 * scale, 27 * scale),
            Color.FromArgb(255, 37, 99, 235),
            Color.FromArgb(255, 79, 70, 229));
        graphics.FillPath(gradient, back);

        using var front = RoundedRectangle(9 * scale, 9 * scale, 18 * scale, 18 * scale, 5 * scale);
        using var white = new SolidBrush(Color.FromArgb(242, 255, 255, 255));
        graphics.FillPath(white, front);

        using var sky = new SolidBrush(Color.FromArgb(255, 96, 165, 250));
        graphics.FillEllipse(sky, 12 * scale, 12 * scale, 4 * scale, 4 * scale);

        var points = new[]
        {
            new PointF(11 * scale, 24 * scale),
            new PointF(16 * scale, 18 * scale),
            new PointF(19 * scale, 21 * scale),
            new PointF(22 * scale, 17 * scale),
            new PointF(26 * scale, 22 * scale),
            new PointF(26 * scale, 25 * scale),
            new PointF(11 * scale, 25 * scale),
        };
        using var mountain = new SolidBrush(Color.FromArgb(255, 79, 70, 229));
        graphics.FillPolygon(mountain, points);
        return bitmap;
    }

    private static GraphicsPath RoundedRectangle(float x, float y, float width, float height, float radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(x, y, diameter, diameter, 180, 90);
        path.AddArc(x + width - diameter, y, diameter, diameter, 270, 90);
        path.AddArc(x + width - diameter, y + height - diameter, diameter, diameter, 0, 90);
        path.AddArc(x, y + height - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
