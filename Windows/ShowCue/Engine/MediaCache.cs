using System.IO;
using System.Windows.Media.Imaging;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace ShowCue.Engine;

/// <summary>
/// Laster og cacher bilder og PDF-sider så GO blir umiddelbar.
/// PDF rendres med Windows' innebygde PDF-motor (Windows.Data.Pdf).
/// </summary>
public static class MediaCache
{
    private static readonly Dictionary<string, BitmapSource> Images = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, Task<BitmapSource>> Pdfs = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Bredde PDF-sider rendres i (piksler).</summary>
    public static uint PdfRenderWidth { get; set; } = 1920;

    public static BitmapSource GetImage(string path)
    {
        if (Images.TryGetValue(path, out var bmp)) return bmp;
        var img = new BitmapImage();
        img.BeginInit();
        img.CacheOption = BitmapCacheOption.OnLoad;
        img.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
        img.UriSource = new Uri(path);
        img.EndInit();
        img.Freeze();
        Images[path] = img;
        return img;
    }

    public static Task<BitmapSource> GetPdfPage(string path, int page)
    {
        var key = $"{path}|{page}|{PdfRenderWidth}";
        if (Pdfs.TryGetValue(key, out var t) && !t.IsFaulted) return t;
        t = RenderPdfPage(path, page);
        Pdfs[key] = t;
        return t;
    }

    private static async Task<BitmapSource> RenderPdfPage(string path, int page)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        var doc = await PdfDocument.LoadFromFileAsync(file);
        if (page < 1 || page > doc.PageCount)
            throw new ArgumentOutOfRangeException(nameof(page), $"PDF-en har {doc.PageCount} sider.");
        using var pdfPage = doc.GetPage((uint)(page - 1));
        using var stream = new InMemoryRandomAccessStream();
        await pdfPage.RenderToStreamAsync(stream, new PdfPageRenderOptions
        {
            DestinationWidth = PdfRenderWidth,
        });
        stream.Seek(0);
        var img = new BitmapImage();
        using (var net = stream.AsStream())
        {
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.StreamSource = net;
            img.EndInit();
        }
        img.Freeze();
        return img;
    }

    public static async Task<int> GetPdfPageCount(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        var doc = await PdfDocument.LoadFromFileAsync(file);
        return (int)doc.PageCount;
    }

    /// <summary>Forhåndslast alle bilder/PDF-sider i showet i bakgrunnen.</summary>
    public static void Preload(IEnumerable<Models.Cue> cues)
    {
        foreach (var c in cues)
        {
            try
            {
                if (c is Models.ImageCue ic && File.Exists(ic.FilePath)) GetImage(ic.FilePath);
                else if (c is Models.PdfCue pc && File.Exists(pc.FilePath)) _ = GetPdfPage(pc.FilePath, pc.Page);
            }
            catch { /* feil vises når cuen kjøres */ }
        }
    }

    public static void Clear()
    {
        Images.Clear();
        Pdfs.Clear();
    }
}
