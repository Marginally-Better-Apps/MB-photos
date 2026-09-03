using System.IO;
using System.Text.Json;
using System.Xml.Linq;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using MBPhotos.Receiver.Library;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Transfer;

namespace MBPhotos.Receiver.Wpf.Tests;

internal static class Program
{
    private static int passed;
    private static int failed;

    [STAThread]
    public static int Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("presentation state copy and preview fencing", TestPresentationStateAndPreviewFencingAsync),
            ("transfer progress bindings remain one-way", TestTransferProgressBindingsAsync),
            ("window pages resize without page scrollbars", TestAdaptivePageLayoutAsync),
            ("library dates sort and filter", TestLibraryDateSortAndFilterAsync),
            ("thumbnail copy is full-quality and image-only", TestThumbnailCopySelectionAsync),
            ("library saves to the chosen filename", TestLibrarySaveAsAsync),
            ("duplicate library versions collapse", TestDuplicateLibraryVersionsCollapseAsync),
            ("missing settings are treated as first launch", TestMissingSettingsAsync),
            ("corrupt settings are ignored", TestCorruptSettingsAsync),
            ("valid versioned settings load", TestValidSettingsAsync),
            ("settings replacement is atomic", TestAtomicSettingsReplacementAsync),
            ("failed settings save preserves the prior value", TestFailedSettingsSavePreservesPriorValueAsync),
            ("preview paths remain inside the active library", TestPreviewSafePathAsync),
            ("malformed JPEG previews fall back cleanly", TestMalformedPreviewAsync),
            ("loaded previews release their source file", TestPreviewFileHandleReleaseAsync),
        };

        foreach (var test in tests)
        {
            try
            {
                test.Run().GetAwaiter().GetResult();
                passed++;
                Console.WriteLine($"PASS {test.Name}");
            }
            catch (Exception exception)
            {
                failed++;
                Console.Error.WriteLine($"FAIL {test.Name}: {exception}");
            }
        }

        Console.WriteLine($"{passed} passed; {failed} failed");
        return failed == 0 ? 0 : 1;
    }

    private static Task TestPresentationStateAndPreviewFencingAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Family Library");
        Directory.CreateDirectory(libraryRoot);
        var model = new ReceiverWindowPresentationModel();

        var stateExpectations = new[]
        {
            (ReceiverPresentationState.Setup, "Choose where photos are saved", "Set up", false, false),
            (ReceiverPresentationState.Starting, "Getting ready", "Starting", true, false),
            (ReceiverPresentationState.Ready, "Scan with MB Photos on your iPhone", "Ready", true, false),
            (ReceiverPresentationState.Connected, "iPhone connected", "Connected", true, false),
            (ReceiverPresentationState.Transferring, "Receiving photos", "Receiving", true, false),
            (ReceiverPresentationState.Finalizing, "Finishing up", "Finalizing", true, false),
            (ReceiverPresentationState.Paused, "Receiving is paused", "Paused", false, true),
            (ReceiverPresentationState.Error, "Receiver needs attention", "Needs attention", false, true),
        };

        foreach (var expectation in stateExpectations)
        {
            model.Apply(Snapshot(expectation.Item1, generation: 41, libraryRoot));
            Equal(expectation.Item2, model.Heading, $"heading for {expectation.Item1}");
            Equal(expectation.Item3, model.StatusText, $"status for {expectation.Item1}");
            Equal(expectation.Item4, model.CanStop, $"stop availability for {expectation.Item1}");
            Equal(expectation.Item5, model.CanRetry, $"retry availability for {expectation.Item1}");
        }

        var activity = new ReceiverActivity(
            Guid.NewGuid(),
            "transferring",
            CompletedFiles: 3,
            TotalFiles: 7,
            TransferredBytes: 1024,
            CurrentRelativePath: "Master/private-name.jpg",
            FreeBytes: 2048,
            LatestThumbnailRelativePath: "MB Photos Data/Thumbnails/current.jpg");
        var counts = new CompletionCounts(4, 4, 0, 7, 7, 0, 0, 1024, 1024);
        model.Apply(new ReceiverOrchestrationSnapshot(
            ReceiverPresentationState.Transferring,
            41,
            libraryRoot,
            null,
            null,
            activity,
            new LastTransferPresentation("completed", counts, activity.LatestThumbnailRelativePath),
            null,
            null));
        Equal("3 of 7 files", model.ProgressText, "simple transfer progress");
        Equal("Transfer complete", model.CompletionHeading, "completion copy");
        Equal("4 items saved to Family Library.", model.CompletionMessage, "completion count copy");

        var preview = new DrawingImage();
        preview.Freeze();
        const string requestedPath = "MB Photos Data/Thumbnails/current.jpg";
        model.BeginPreviewRequest(41, requestedPath);
        False(model.TrySetPreview(40, requestedPath, preview, completion: false), "stale generation was accepted");
        False(model.TrySetPreview(41, "MB Photos Data/Thumbnails/other.jpg", preview, completion: false), "stale path was accepted");
        True(model.TrySetPreview(41, requestedPath, preview, completion: true), "current preview was rejected");
        True(model.HasTransferPreview, "current preview was not retained");
        Same(preview, model.CompletionPreviewImage, "completion preview");

        model.BeginPreviewRequest(41, "MB Photos Data/Thumbnails/new.jpg");
        False(model.TrySetPreview(41, requestedPath, preview, completion: false), "superseded preview request was accepted");
        model.Apply(Snapshot(ReceiverPresentationState.Ready, generation: 42, libraryRoot));
        True(model.HasTransferPreview, "same-library restart discarded the last verified preview");
        Same(preview, model.CompletionPreviewImage, "same-library restart discarded the completion preview");
        False(
            model.TrySetPreview(41, "MB Photos Data/Thumbnails/new.jpg", preview, completion: false),
            "generation change did not fence pending preview work");

        model.Apply(Snapshot(
            ReceiverPresentationState.Ready,
            generation: 43,
            Path.Combine(Path.GetTempPath(), "Another MB Photos Library")));
        False(model.HasTransferPreview, "library change retained a preview from another root");
        Equal<ImageSource?>(null, model.CompletionPreviewImage, "library change retained a completion preview");

        model.Apply(Snapshot(ReceiverPresentationState.Library, generation: 43, libraryRoot));
        True(model.IsLibraryPage, "library state did not select the library page");
        model.Apply(Snapshot(ReceiverPresentationState.Ready, generation: 44, libraryRoot));
        True(model.IsReceiverPage, "leaving library did not restore the receiver page");

        return Task.CompletedTask;
    }

    private static Task TestTransferProgressBindingsAsync()
    {
        var document = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "Fixtures", "MainWindow.xaml"));
        XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var template = document
            .Descendants(presentation + "DataTemplate")
            .Single(element => string.Equals(
                (string?)element.Attribute(xaml + "Key"),
                "TransferringTemplate",
                StringComparison.Ordinal));
        var progress = template
            .Descendants(presentation + "ProgressBar")
            .Single(element => ((string?)element.Attribute("Value"))?.Contains(
                "ProgressValue",
                StringComparison.Ordinal) == true);

        Equal(
            "{Binding ProgressMaximum, Mode=OneWay}",
            (string?)progress.Attribute("Maximum"),
            "transfer progress maximum binding");
        Equal(
            "{Binding ProgressValue, Mode=OneWay}",
            (string?)progress.Attribute("Value"),
            "transfer progress value binding");
        Equal(
            "{Binding IsProgressIndeterminate, Mode=OneWay}",
            (string?)progress.Attribute("IsIndeterminate"),
            "transfer indeterminate binding");
        return Task.CompletedTask;
    }

    private static Task TestAdaptivePageLayoutAsync()
    {
        var document = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "Fixtures", "MainWindow.xaml"));
        XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";

        XElement NamedElement(string name) => document
            .Descendants()
            .Single(element => string.Equals(
                (string?)element.Attribute(xaml + "Name"),
                name,
                StringComparison.Ordinal));

        foreach (var pageName in new[] { "ReceiverPage", "LibraryPage", "SettingsPage" })
        {
            var page = NamedElement(pageName);
            Equal(presentation + "Grid", page.Name, $"{pageName} layout root");
            False(
                page.Descendants(presentation + "ScrollViewer").Any(),
                $"{pageName} contains a page-level scroll viewer");
        }

        foreach (var pageName in new[] { "ReceiverPage", "SettingsPage" })
        {
            var viewbox = NamedElement(pageName).Descendants(presentation + "Viewbox").Single();
            Equal("Uniform", (string?)viewbox.Attribute("Stretch"), $"{pageName} resize mode");
            Equal("DownOnly", (string?)viewbox.Attribute("StretchDirection"), $"{pageName} resize direction");
        }
        False(
            NamedElement("LibraryPage").Descendants(presentation + "Viewbox").Any(),
            "library details are still capped by a viewbox");

        var preview = NamedElement("LibraryPreviewImage");
        Equal("Uniform", (string?)preview.Attribute("Stretch"), "library preview resize mode");
        Equal("Both", (string?)preview.Attribute("StretchDirection"), "library preview resize direction");
        var previewContainer = NamedElement("LibraryPreviewContainer");
        var detailsLayout = NamedElement("LibraryDetailsLayout");
        Same(detailsLayout, previewContainer.Parent, "preview is outside the flexible details layout");
        Equal<string?>(null, (string?)previewContainer.Attribute("Height"), "library preview still has a fixed height");
        Equal<string?>(null, (string?)previewContainer.Attribute("MaxWidth"), "library preview still has a maximum width");
        Equal<string?>(null, (string?)previewContainer.Attribute("MaxHeight"), "library preview still has a maximum height");
        var firstDetailsRow = detailsLayout
            .Element(presentation + "Grid.RowDefinitions")?
            .Elements(presentation + "RowDefinition")
            .FirstOrDefault();
        NotNull(firstDetailsRow, "library details rows");
        Equal("*", (string?)firstDetailsRow!.Attribute("Height"), "preview does not receive remaining height");

        var variantStyle = document
            .Descendants(presentation + "Style")
            .Single(element => string.Equals(
                (string?)element.Attribute(xaml + "Key"),
                "LibraryVariantButtonStyle",
                StringComparison.Ordinal));
        var disabledTrigger = variantStyle
            .Descendants(presentation + "Trigger")
            .Single(element =>
                string.Equals((string?)element.Attribute("Property"), "IsEnabled", StringComparison.Ordinal) &&
                string.Equals((string?)element.Attribute("Value"), "False", StringComparison.Ordinal));
        True(
            disabledTrigger.Descendants(presentation + "Setter").Any(element =>
                string.Equals((string?)element.Attribute("Property"), "Visibility", StringComparison.Ordinal) &&
                string.Equals((string?)element.Attribute("Value"), "Collapsed", StringComparison.Ordinal)),
            "disabled library versions remain visible");

        foreach (var (name, tag) in new[]
                 {
                     ("CurrentVersionButton", "CurrentMaster"),
                     ("OriginalVersionButton", "RootOriginal"),
                     ("CurrentMotionVersionButton", "CurrentLiveMotion"),
                     ("OriginalMotionVersionButton", "OriginalLiveMotion"),
                 })
        {
            var button = NamedElement(name);
            Equal(presentation + "RadioButton", button.Name, $"{name} control type");
            Equal(tag, (string?)button.Attribute("Tag"), $"{name} variant tag");
            Equal("PreviewVariant_Click", (string?)button.Attribute("Click"), $"{name} selection action");
            Equal(presentation + "UniformGrid", button.Parent?.Name, $"{name} alignment container");
        }

        var previewPanel = preview.Parent!;
        var saveButton = NamedElement("SaveLibraryPreviewButton");
        False(
            document.Descendants().Any(element =>
                string.Equals(
                    (string?)element.Attribute(xaml + "Name"),
                    "LibraryPreviewSelectionBadge",
                    StringComparison.Ordinal)),
            "preview selection label remains visible");
        False(ReferenceEquals(previewPanel, saveButton.Parent), "preview save button still overlays the media");
        var previewActionPanel = saveButton.Parent;
        NotNull(previewActionPanel, "preview action panel");
        Equal(presentation + "StackPanel", previewActionPanel!.Name, "preview action layout");
        Equal("Horizontal", (string?)previewActionPanel.Attribute("Orientation"), "preview action orientation");
        Equal("Center", (string?)previewActionPanel.Attribute("HorizontalAlignment"), "preview action alignment");
        Equal("1", (string?)previewActionPanel.Parent?.Attribute("Grid.Row"), "preview action row");
        Equal("SaveLibraryPreview_Click", (string?)saveButton.Attribute("Click"), "preview save action");
        var copyButton = NamedElement("CopyLibraryPreviewButton");
        Equal("Copy", (string?)copyButton.Attribute("Content"), "preview copy button label");
        Equal("CopyLibraryPreview_Click", (string?)copyButton.Attribute("Click"), "preview copy action");
        Same(previewActionPanel, copyButton.Parent, "preview copy button is not next to save");
        _ = NamedElement("LibraryPreviewVideo");

        var timeFilterPanel = NamedElement("LibraryTimeFilterPanel");
        Equal(presentation + "WrapPanel", timeFilterPanel.Name, "library time filter layout");
        var overflowMenu = NamedElement("OverflowMenu");
        Equal(
            "Segoe UI Variable Text, Segoe UI",
            (string?)overflowMenu.Attribute("FontFamily"),
            "overflow menu inherited the icon font");
        var thumbnail = document
            .Descendants(presentation + "Border")
            .Single(element => string.Equals(
                (string?)element.Attribute("ContextMenuOpening"),
                "LibraryThumbnail_ContextMenuOpening",
                StringComparison.Ordinal));
        var copyImageItem = thumbnail
            .Descendants(presentation + "MenuItem")
            .Single();
        Equal("Copy Full-Quality Image", (string?)copyImageItem.Attribute("Header"), "thumbnail copy label");
        Equal("CopyFullQualityImage_Click", (string?)copyImageItem.Attribute("Click"), "thumbnail copy action");
        var openLibraryFolderButton = NamedElement("OpenLibraryFolderButton");
        Equal("Open Photos Folder", (string?)openLibraryFolderButton.Attribute("Content"), "library folder button label");
        Equal("OpenMasterFolder_Click", (string?)openLibraryFolderButton.Attribute("Click"), "library folder button action");
        foreach (var (name, tag) in new[]
                 {
                     ("AllDatesFilterButton", "All"),
                     ("TodayFilterButton", "Today"),
                     ("ThisWeekFilterButton", "ThisWeek"),
                     ("ThisMonthFilterButton", "ThisMonth"),
                     ("ThisYearFilterButton", "ThisYear"),
                     ("EarlierFilterButton", "Earlier"),
                 })
        {
            var button = NamedElement(name);
            Equal(presentation + "RadioButton", button.Name, $"{name} control type");
            Equal(tag, (string?)button.Attribute("Tag"), $"{name} time filter tag");
            Equal("LibraryTimeFilter_Click", (string?)button.Attribute("Click"), $"{name} filter action");
            Same(timeFilterPanel, button.Parent, $"{name} wrapping container");
        }
        return Task.CompletedTask;
    }

    private static Task TestLibraryDateSortAndFilterAsync()
    {
        var now = new DateTimeOffset(new DateTime(2026, 9, 2, 12, 0, 0, DateTimeKind.Local));
        var today = now.AddHours(-2);
        var thisWeek = now.AddDays(-1);
        var thisYear = new DateTimeOffset(new DateTime(2026, 2, 10, 12, 0, 0, DateTimeKind.Local));
        var earlier = new DateTimeOffset(new DateTime(2025, 12, 31, 12, 0, 0, DateTimeKind.Local));

        True(MainWindow.LibraryTimeFilterIncludes(today, LibraryTimeFilter.Today, now), "today filter");
        False(MainWindow.LibraryTimeFilterIncludes(thisWeek, LibraryTimeFilter.Today, now), "today included yesterday");
        True(MainWindow.LibraryTimeFilterIncludes(thisWeek, LibraryTimeFilter.ThisWeek, now), "week filter");
        True(MainWindow.LibraryTimeFilterIncludes(today, LibraryTimeFilter.ThisMonth, now), "month filter");
        True(MainWindow.LibraryTimeFilterIncludes(thisYear, LibraryTimeFilter.ThisYear, now), "year filter");
        False(MainWindow.LibraryTimeFilterIncludes(earlier, LibraryTimeFilter.ThisYear, now), "year included older photo");
        True(MainWindow.LibraryTimeFilterIncludes(earlier, LibraryTimeFilter.Earlier, now), "earlier filter");
        True(MainWindow.LibraryTimeFilterIncludes(null, LibraryTimeFilter.All, now), "all dates omitted undated photo");
        False(MainWindow.LibraryTimeFilterIncludes(null, LibraryTimeFilter.Earlier, now), "earlier included undated photo");

        var sorted = MainWindow.SortLibraryItems(
        [
            Item("earlier", earlier),
            Item("undated", null),
            Item("today", today),
            Item("this-week", thisWeek),
        ]);
        Equal("today,this-week,earlier,undated", string.Join(',', sorted.Select(item => item.Filename)),
            "library was not sorted newest first with undated items last");
        return Task.CompletedTask;

        static LibraryAssetListItem Item(string filename, DateTimeOffset? captureDate)
        {
            var assetId = Guid.NewGuid();
            var catalog = new CatalogAsset(
                2,
                assetId,
                assetId.ToString("D"),
                "revision",
                "photo",
                Array.Empty<string>(),
                captureDate,
                captureDate,
                null,
                false,
                null,
                null,
                ArchiveState.Complete,
                Array.Empty<CatalogFile>());
            return new LibraryAssetListItem(
                new PortableLibraryAsset(catalog, Array.Empty<PortableLibraryFile>()),
                filename,
                captureDate?.ToString("g") ?? "Date unavailable",
                "Photo",
                null,
                captureDate);
        }
    }

    private static async Task TestThumbnailCopySelectionAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        Directory.CreateDirectory(libraryRoot);

        var current = await File(
            "Master/current.heic",
            RepresentationRole.MasterCurrent,
            StorageArea.Master,
            "current.heic");
        var original = await File(
            "MB Photos Data/Resources/original.heic",
            RepresentationRole.RootOriginal,
            StorageArea.LibraryData,
            "original.heic");
        var motion = await File(
            "MB Photos Data/Resources/motion.mov",
            RepresentationRole.CurrentLiveMotion,
            StorageArea.LibraryData,
            "motion.mov");
        var photo = Asset("photo", current, original);
        Same(current, MainWindow.FindCopyableImageFile(photo), "thumbnail copy did not prefer the current full-quality image");
        True(MainWindow.IsCopyableStillImage(current), "current photo was not copyable");

        var livePhoto = new PortableLibraryAsset(
            photo.Catalog with
            {
                MediaSubtypes = new[] { "livePhoto" },
                LivePhotoRelationships = new LivePhotoRelationships(
                    current.FileId,
                    motion.FileId,
                    original.FileId,
                    null),
            },
            photo.Files.Append(motion).ToArray());
        Same(current, MainWindow.FindCopyableImageFile(livePhoto), "Live Photo still image was not copyable");
        False(MainWindow.IsCopyableStillImage(motion), "Live Photo motion was exposed as an image copy");

        var originalOnlyPhoto = Asset("photo", original);
        Same(original, MainWindow.FindCopyableImageFile(originalOnlyPhoto), "thumbnail copy did not fall back to the original image");
        Equal<PortableLibraryFile?>(null, MainWindow.FindCopyableImageFile(Asset("video", current)), "video exposed image copy");

        var compatibleSource = Path.Combine(temporaryDirectory.Path, "compatible-source.jpg");
        WriteJpeg(compatibleSource, width: 3, height: 2);
        var clipboardImage = MainWindow.CreatePlatformClipboardImage(compatibleSource);
        NotNull(clipboardImage, "compatible clipboard image was not created");
        Equal(3, clipboardImage!.Bitmap.PixelWidth, "clipboard image lost horizontal resolution");
        Equal(2, clipboardImage.Bitmap.PixelHeight, "clipboard image lost vertical resolution");
        True(
            clipboardImage.PngBytes.Take(8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }),
            "clipboard image was not encoded as PNG");

        return;

        PortableLibraryAsset Asset(string mediaType, params PortableLibraryFile[] files)
        {
            var assetId = files[0].AssetId;
            var catalog = new CatalogAsset(
                2,
                assetId,
                assetId.ToString("D"),
                "revision",
                mediaType,
                Array.Empty<string>(),
                null,
                null,
                null,
                false,
                files.FirstOrDefault(file => file.Catalog.Roles.Contains(RepresentationRole.MasterCurrent))?.FileId,
                null,
                ArchiveState.Complete,
                files.Select(file => file.Catalog).ToArray());
            return new PortableLibraryAsset(catalog, files);
        }

        async Task<PortableLibraryFile> File(
            string relativePath,
            RepresentationRole role,
            StorageArea storageArea,
            string filename)
        {
            var assetId = Guid.Parse("4C671CB5-32FD-4971-AC82-A7C70955C3A0");
            var path = Path.Combine(libraryRoot, relativePath.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var bytes = System.Text.Encoding.UTF8.GetBytes(relativePath);
            await System.IO.File.WriteAllBytesAsync(path, bytes);
            var isMotion = role is RepresentationRole.CurrentLiveMotion or RepresentationRole.OriginalLiveMotion;
            var catalog = new CatalogFile(
                Guid.NewGuid(),
                "revision",
                storageArea,
                new[] { role },
                role == RepresentationRole.MasterCurrent ? Criticality.MasterRequired : Criticality.ArchiveRequired,
                Provenance.ExactPhotoKitResource,
                isMotion ? "pairedVideo" : "photo",
                1,
                filename,
                isMotion ? "com.apple.quicktime-movie" : "public.heic",
                isMotion ? "video/quicktime" : "image/heic",
                isMotion ? null : 100,
                isMotion ? null : 100,
                isMotion ? 1_000 : null,
                bytes.Length,
                await Hashing.Sha256FileAsync(path),
                null,
                relativePath,
                Availability.Available);
            return new PortableLibraryFile(assetId, catalog, libraryRoot);
        }
    }

    private static async Task TestLibrarySaveAsAsync()
    {
        Equal(
            "IMG_0042.heic",
            MainWindow.SuggestedLibraryExportFilename("IMG_0042.HEIC", "FullSizeRender.heic", Guid.NewGuid()),
            "edited photo save name");
        Equal(
            "IMG_0042.MOV",
            MainWindow.SuggestedLibraryExportFilename("IMG_0042.HEIC", "pairedVideo.MOV", Guid.NewGuid()),
            "Live Photo video save name");

        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        var sourceRelativePath = "MB Photos Data/media/source.heic";
        var sourcePath = Path.Combine(libraryRoot, sourceRelativePath.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(sourcePath)!);
        var bytes = new byte[] { 1, 3, 3, 7, 9, 2, 4, 8 };
        await File.WriteAllBytesAsync(sourcePath, bytes);
        var assetId = Guid.NewGuid();
        var fileId = Guid.NewGuid();
        var catalog = new CatalogFile(
            fileId,
            "revision",
            StorageArea.Master,
            new[] { RepresentationRole.MasterCurrent },
            Criticality.MasterRequired,
            Provenance.ExactPhotoKitResource,
            "fullSizePhoto",
            null,
            "FullSizeRender.heic",
            "public.heic",
            "image/heic",
            100,
            100,
            null,
            bytes.Length,
            await Hashing.Sha256FileAsync(sourcePath),
            null,
            sourceRelativePath,
            Availability.Available);
        var file = new PortableLibraryFile(assetId, catalog, libraryRoot);
        var destinationDirectory = Path.Combine(temporaryDirectory.Path, "Saved");
        Directory.CreateDirectory(destinationDirectory);
        var chosenPath = Path.Combine(destinationDirectory, "Vacation portrait.heic");
        var exporter = new VariantExportService();

        var first = await exporter.ExportToPathAsync(file, chosenPath);
        Equal(Path.GetFullPath(chosenPath), first.ExportedPath, "chosen export filename");
        var firstContents = await File.ReadAllBytesAsync(chosenPath);
        True(bytes.SequenceEqual(firstContents), "chosen export contents");

        await File.WriteAllTextAsync(chosenPath, "replace me");
        var replacement = await exporter.ExportToPathAsync(file, chosenPath);
        False(replacement.ExistingVerified, "different chosen file was not replaced");
        var replacementContents = await File.ReadAllBytesAsync(chosenPath);
        True(bytes.SequenceEqual(replacementContents), "replacement export contents");
    }

    private static Task TestDuplicateLibraryVersionsCollapseAsync()
    {
        var uneditedMedia = Guid.NewGuid();
        var liveMotion = Guid.NewGuid();
        var choices = MainWindow.DistinctVariantKinds(
        [
            (VariantKind.CurrentMaster, uneditedMedia),
            (VariantKind.RootOriginal, uneditedMedia),
            (VariantKind.CurrentLiveMotion, liveMotion),
            (VariantKind.OriginalLiveMotion, liveMotion),
        ]);

        Equal(
            "CurrentMaster,CurrentLiveMotion",
            string.Join(',', choices),
            "duplicate file roles were exposed as separate choices");
        False(MainWindow.ShouldShowVariantSelection(0, 0), "empty version selector is visible");
        False(MainWindow.ShouldShowVariantSelection(1, 0), "single version selector is visible");
        True(MainWindow.ShouldShowVariantSelection(2, 0), "distinct version selector is hidden");
        True(MainWindow.ShouldShowVariantSelection(1, 1), "additional original selector is hidden");
        return Task.CompletedTask;
    }

    private static async Task TestMissingSettingsAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        Equal<ReceiverSettings?>(null, await store.LoadAsync(), "missing settings result");
    }

    private static async Task TestCorruptSettingsAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        await File.WriteAllTextAsync(store.FilePath, "{ definitely-not-json");
        Equal<ReceiverSettings?>(null, await store.LoadAsync(), "corrupt settings result");

        await File.WriteAllTextAsync(store.FilePath, "{\"version\":999,\"libraryRoot\":\"C:\\\\Photos\"}");
        Equal<ReceiverSettings?>(null, await store.LoadAsync(), "unknown settings version result");
    }

    private static async Task TestValidSettingsAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Photo Library") + Path.DirectorySeparatorChar;
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        var json = JsonSerializer.Serialize(new
        {
            version = ReceiverSettings.CurrentVersion,
            libraryRoot,
        });
        await File.WriteAllTextAsync(store.FilePath, json);

        var settings = await store.LoadAsync();
        NotNull(settings, "valid settings were ignored");
        Equal(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(libraryRoot)),
            settings!.LibraryRoot,
            "normalized library root");
        Equal(ReceiverSettings.CurrentVersion, settings.Version, "settings version");
    }

    private static async Task TestAtomicSettingsReplacementAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        var original = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Original"));
        var replacement = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Replacement"));

        await store.SaveAsync(original);
        await store.SaveAsync(replacement);

        var loaded = await store.LoadAsync();
        NotNull(loaded, "replacement settings were not readable");
        Equal(replacement.LibraryRoot, loaded!.LibraryRoot, "replacement library root");
        var settingsDirectory = Path.GetDirectoryName(store.FilePath)!;
        Equal(0, Directory.GetFiles(settingsDirectory, ".settings.json.*.tmp").Length, "temporary settings files");
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(store.FilePath));
        Equal(ReceiverSettings.CurrentVersion, document.RootElement.GetProperty("version").GetInt32(), "persisted version");
        Equal(replacement.LibraryRoot, document.RootElement.GetProperty("libraryRoot").GetString(), "persisted root");
    }

    private static async Task TestFailedSettingsSavePreservesPriorValueAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        var original = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Original"));
        var replacement = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Replacement"));
        await store.SaveAsync(original);

        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => store.SaveAsync(replacement, cancellation.Token));

        var loaded = await store.LoadAsync();
        NotNull(loaded, "prior settings disappeared after failed save");
        Equal(original.LibraryRoot, loaded!.LibraryRoot, "prior settings after failed save");
        var settingsDirectory = Path.GetDirectoryName(store.FilePath)!;
        Equal(0, Directory.GetFiles(settingsDirectory, ".settings.json.*.tmp").Length, "failed-save temporary files");
    }

    private static async Task TestPreviewSafePathAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        Directory.CreateDirectory(libraryRoot);
        var outsidePath = Path.Combine(temporaryDirectory.Path, "outside.jpg");
        WriteJpeg(outsidePath);

        var loader = new TransferPreviewLoader();
        var preview = await loader.TryLoadAsync(libraryRoot, "../outside.jpg");
        Equal<BitmapSource?>(null, preview, "escaping preview path");
    }

    private static async Task TestMalformedPreviewAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        var previewDirectory = Path.Combine(libraryRoot, "MB Photos Data", "Thumbnails");
        Directory.CreateDirectory(previewDirectory);
        var malformedPath = Path.Combine(previewDirectory, "malformed.jpg");
        await File.WriteAllBytesAsync(malformedPath, [0x00, 0x01, 0x02, 0x03]);

        var loader = new TransferPreviewLoader();
        var preview = await loader.TryLoadAsync(libraryRoot, "MB Photos Data/Thumbnails/malformed.jpg");
        Equal<BitmapSource?>(null, preview, "malformed JPEG preview");
    }

    private static async Task TestPreviewFileHandleReleaseAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        var previewDirectory = Path.Combine(libraryRoot, "MB Photos Data", "Thumbnails");
        Directory.CreateDirectory(previewDirectory);
        var previewPath = Path.Combine(previewDirectory, "verified.jpg");
        WriteJpeg(previewPath);

        var loader = new TransferPreviewLoader();
        var preview = await loader.TryLoadAsync(libraryRoot, "MB Photos Data/Thumbnails/verified.jpg");
        NotNull(preview, "valid JPEG preview was not decoded");
        True(preview!.IsFrozen, "decoded preview was not frozen");
        True(preview.PixelWidth > 0 && preview.PixelHeight > 0, "decoded preview has no pixels");

        using (new FileStream(previewPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            // Exclusive access proves the decoder no longer owns the source stream.
        }

        File.Delete(previewPath);
        False(File.Exists(previewPath), "preview source could not be removed after decoding");
    }

    private static ReceiverOrchestrationSnapshot Snapshot(
        ReceiverPresentationState state,
        long generation,
        string? libraryRoot,
        Exception? error = null) => new(
            state,
            generation,
            libraryRoot,
            null,
            null,
            null,
            null,
            error,
            null,
            state == ReceiverPresentationState.Paused);

    private static ReceiverSettingsStore StoreIn(string root) => new(
        Path.Combine(root, "Settings", "settings.json"));

    private static void WriteJpeg(string path, int width = 1, int height = 1)
    {
        var pixels = Enumerable
            .Repeat(new byte[] { 0x20, 0x80, 0xE0, 0xFF }, width * height)
            .SelectMany(pixel => pixel)
            .ToArray();
        var bitmap = BitmapSource.Create(
            width,
            height,
            96,
            96,
            PixelFormats.Bgra32,
            null,
            pixels,
            stride: width * 4);
        var encoder = new JpegBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        encoder.Save(stream);
    }

    private static async Task<TException> ThrowsAsync<TException>(Func<Task> action)
        where TException : Exception
    {
        try
        {
            await action();
        }
        catch (TException exception)
        {
            return exception;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private static void NotNull<T>(T? value, string message)
        where T : class
    {
        if (value is null)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void Same(object expected, object? actual, string message)
    {
        if (!ReferenceEquals(expected, actual))
        {
            throw new InvalidOperationException($"{message}: references differ");
        }
    }

    private static void True(bool value, string message)
    {
        if (!value)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void False(bool value, string message) => True(!value, message);

    private static void Equal<T>(T expected, T actual, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"{message}: expected <{expected}>, actual <{actual}>");
        }
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "MBPhotos.Receiver.Wpf.Tests",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, recursive: true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
