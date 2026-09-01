using System.Net;
using System.Text.Json;
using MBPhotos.Receiver.Diagnostics;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Pairing;
using MBPhotos.Receiver.Storage;
using MBPhotos.Receiver.Transfer;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http.Json;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Options;

namespace MBPhotos.Receiver.Hosting;

public sealed class ReceiverServer : IAsyncDisposable
{
    public const long MaximumJobManifestBytes = 1024L * 1024 * 1024;
    private const long MaximumOrdinaryRequestBytes = 128L * 1024 * 1024;
    private readonly WebApplication application;
    private readonly PairingSessionManager pairing;
    private readonly EphemeralCertificate certificate;
    private readonly Ledger ledger;
    private readonly DestinationLease destinationLease;

    private ReceiverServer(
        WebApplication application,
        PairingSessionManager pairing,
        EphemeralCertificate certificate,
        Ledger ledger,
        DestinationLease destinationLease,
        DestinationContext destination,
        JobCoordinator coordinator,
        RedactingFileLoggerProvider diagnostics,
        IPAddress address,
        int port,
        string qrPayload)
    {
        this.application = application;
        this.pairing = pairing;
        this.certificate = certificate;
        this.ledger = ledger;
        this.destinationLease = destinationLease;
        Destination = destination;
        Coordinator = coordinator;
        Diagnostics = diagnostics;
        Address = address;
        Port = port;
        QrPayload = qrPayload;
    }

    public DestinationContext Destination { get; }

    public JobCoordinator Coordinator { get; }

    public RedactingFileLoggerProvider Diagnostics { get; }

    public IPAddress Address { get; }

    public int Port { get; }

    public string QrPayload { get; }

    public Uri BaseUri => new($"https://{Address}:{Port}/");

    public string CertificateFingerprint => certificate.Sha256Fingerprint;

    public static async Task<ReceiverServer> StartAsync(
        string destinationPath,
        bool allowInitialize,
        IPAddress? listenAddress = null,
        string? diagnosticDirectory = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var address = listenAddress ?? NetworkAddressSelector.SelectPreferred();
        if (address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
        {
            throw new ArgumentException("The MVP receiver requires an IPv4 listen address.", nameof(listenAddress));
        }
        cancellationToken.ThrowIfCancellationRequested();

        var jsonOptions = JsonDefaults.Create();
        var destinationManager = new DestinationManager(jsonOptions);
        DestinationContext destination;
        DestinationLease destinationLease;
        using (DestinationInitializationLease.Acquire(destinationPath))
        {
            destination = await destinationManager.OpenOrInitializeAsync(destinationPath, allowInitialize, cancellationToken);
            destinationLease = DestinationLease.Acquire(destination);
        }
        var ledger = new Ledger(destination.DatabasePath);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            await ledger.InitializeAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            await ledger.PauseActiveJobsAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
        }
        catch
        {
            await ledger.DisposeAsync();
            destinationLease.Dispose();
            throw;
        }
        var pathPolicy = new WindowsPathPolicy();
        var transfers = new FileTransferService(destination, destinationManager, ledger, pathPolicy);
        try
        {
            foreach (var terminalJobId in await ledger.GetTerminalJobIdsAsync(cancellationToken))
            {
                cancellationToken.ThrowIfCancellationRequested();
                await transfers.RemoveUncommittedPartialsAsync(terminalJobId, cancellationToken);
            }
            cancellationToken.ThrowIfCancellationRequested();
        }
        catch
        {
            await ledger.DisposeAsync();
            destinationLease.Dispose();
            throw;
        }
        var manifestWriter = new ManifestWriter(destination, ledger, pathPolicy, jsonOptions);
        var masterPromotion = new MasterPromotionService(destination, ledger, pathPolicy, jsonOptions);
        await masterPromotion.RecoverInterruptedAsync(cancellationToken);
        var representationReuse = new RepresentationReuseService(destination, ledger, pathPolicy);
        var supersededRepresentations = new SupersededRepresentationService(destination, ledger, pathPolicy);
        var coordinator = new JobCoordinator(
            destination,
            destinationManager,
            ledger,
            pathPolicy,
            transfers,
            manifestWriter,
            masterPromotion,
            representationReuse,
            supersededRepresentations,
            jsonOptions);
        var pairing = new PairingSessionManager();
        var run = pairing.StartRun();
        EphemeralCertificate certificate;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            certificate = EphemeralCertificate.Create(address);
        }
        catch
        {
            pairing.EndRun();
            await ledger.DisposeAsync();
            destinationLease.Dispose();
            throw;
        }
        var diagnostics = new RedactingFileLoggerProvider(diagnosticDirectory);

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            ApplicationName = typeof(ReceiverServer).Assembly.FullName,
            Args = Array.Empty<string>(),
        });
        builder.Logging.ClearProviders();
        builder.Logging.AddProvider(diagnostics);
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.AddServerHeader = false;
            // A frozen 100k-asset manifest can be much larger than one chunk.
            // Chunk endpoints still enforce the negotiated 8 MiB size in code.
            options.Limits.MaxRequestBodySize = MaximumOrdinaryRequestBytes;
            options.Listen(address, 0, listen => listen.UseHttps(certificate.Certificate));
        });
        builder.Services.Configure<JsonOptions>(options =>
        {
            options.SerializerOptions.PropertyNamingPolicy = jsonOptions.PropertyNamingPolicy;
            options.SerializerOptions.PropertyNameCaseInsensitive = jsonOptions.PropertyNameCaseInsensitive;
            foreach (var converter in jsonOptions.Converters)
            {
                options.SerializerOptions.Converters.Add(converter);
            }
        });

        var app = builder.Build();
        ConfigurePipeline(app, pairing, destination, destinationManager, coordinator, run.ReceiverRunId, jsonOptions);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            await app.StartAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var addresses = app.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()?.Addresses
                ?? throw new InvalidOperationException("Kestrel did not publish its bound address.");
            var bound = addresses.Select(static value => new Uri(value)).Single();
            var qrPayload = pairing.CreateQrPayload(address.ToString(), bound.Port, certificate.Sha256Fingerprint);
            return new ReceiverServer(
                app,
                pairing,
                certificate,
                ledger,
                destinationLease,
                destination,
                coordinator,
                diagnostics,
                address,
                bound.Port,
                qrPayload);
        }
        catch
        {
            await app.DisposeAsync();
            certificate.Dispose();
            await ledger.DisposeAsync();
            destinationLease.Dispose();
            pairing.EndRun();
            diagnostics.Dispose();
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        var failures = new List<Exception>();

        void Attempt(Action action)
        {
            try { action(); }
            catch (Exception exception) { failures.Add(exception); }
        }

        async Task AttemptAsync(Func<Task> action)
        {
            try { await action(); }
            catch (Exception exception) { failures.Add(exception); }
        }

        Attempt(pairing.EndRun);
        await AttemptAsync(() => application.StopAsync(TimeSpan.FromSeconds(5)));
        await AttemptAsync(() => ledger.PauseActiveJobsAsync());
        await AttemptAsync(() => application.DisposeAsync().AsTask());
        Attempt(certificate.Dispose);
        await AttemptAsync(() => ledger.DisposeAsync().AsTask());
        Attempt(destinationLease.Dispose);
        await AttemptAsync(() => Diagnostics.DisposeAsync().AsTask());

        if (failures.Count == 1)
        {
            throw failures[0];
        }
        if (failures.Count > 1)
        {
            throw new AggregateException("Receiver shutdown encountered multiple errors.", failures);
        }
    }

    private static void ConfigurePipeline(
        WebApplication app,
        PairingSessionManager pairing,
        DestinationContext destination,
        DestinationManager destinationManager,
        JobCoordinator coordinator,
        string receiverRunId,
        JsonSerializerOptions jsonOptions)
    {
        app.Use(async (context, next) =>
        {
            Guid? requestId = null;
            try
            {
                var requestIdHeader = context.Request.Headers["X-Request-ID"].ToString();
                if (!string.IsNullOrEmpty(requestIdHeader))
                {
                    if (!Guid.TryParse(requestIdHeader, out var parsedRequestId) || parsedRequestId == Guid.Empty)
                    {
                        throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "X-Request-ID must be a non-empty UUID.");
                    }

                    requestId = parsedRequestId;
                }

                await next(context);
            }
            catch (ReceiverApiException exception)
            {
                if (!context.Response.HasStarted)
                {
                    context.Response.StatusCode = exception.StatusCode;
                    await context.Response.WriteAsJsonAsync(exception.Error with { RequestId = requestId }, jsonOptions, context.RequestAborted);
                }
            }
            catch (BadHttpRequestException exception)
            {
                if (!context.Response.HasStarted)
                {
                    context.Response.StatusCode = 400;
                    await context.Response.WriteAsJsonAsync(
                        new ApiError(ErrorCodes.InvalidRequest, "The HTTP request is invalid.", false, requestId),
                        jsonOptions,
                        context.RequestAborted);
                }

                app.Logger.LogWarning(exception, "Rejected malformed HTTP request");
            }
            catch (JsonException exception)
            {
                if (!context.Response.HasStarted)
                {
                    context.Response.StatusCode = 400;
                    await context.Response.WriteAsJsonAsync(
                        new ApiError(ErrorCodes.InvalidRequest, "The JSON request body is invalid.", false, requestId),
                        jsonOptions,
                        context.RequestAborted);
                }

                app.Logger.LogWarning(exception, "Rejected invalid JSON request");
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
            {
                app.Logger.LogInformation("Request disconnected");
            }
            catch (Exception exception)
            {
                app.Logger.LogError(exception, "Unhandled receiver API error");
                if (!context.Response.HasStarted)
                {
                    context.Response.StatusCode = 500;
                    await context.Response.WriteAsJsonAsync(
                        new ApiError(ErrorCodes.InternalError, "The receiver encountered an internal error.", true, requestId),
                        jsonOptions,
                        context.RequestAborted);
                }
            }
        });

        app.Use(async (context, next) =>
        {
            if (context.Request.Path.StartsWithSegments("/v2") &&
                !context.Request.Path.Equals("/v2/pair") &&
                !pairing.Authorize(context.Request.Headers.Authorization.ToString()))
            {
                context.Response.StatusCode = 401;
                context.Response.Headers.CacheControl = "no-store";
                var hasAuthorization = !string.IsNullOrWhiteSpace(context.Request.Headers.Authorization.ToString());
                var requestId = Guid.TryParse(context.Request.Headers["X-Request-ID"].ToString(), out var parsedRequestId)
                    ? parsedRequestId
                    : (Guid?)null;
                await context.Response.WriteAsJsonAsync(
                    new ApiError(
                        hasAuthorization ? ErrorCodes.AuthenticationInvalid : ErrorCodes.AuthenticationRequired,
                        hasAuthorization ? "The receiver session is invalid." : "A receiver session is required.",
                        false,
                        requestId),
                    jsonOptions,
                    context.RequestAborted);
                return;
            }

            await next(context);
        });

        app.MapPost("/v2/pair", async (HttpContext context) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            var request = await ReadRequiredAsync<PairRequest>(context, jsonOptions);
            var session = pairing.Redeem(request);
            var info = destinationManager.RefreshInfo(destination);
            return Results.Json(
                new PairResponse(
                    ProtocolConstants.Version,
                    session,
                    Guid.Parse(receiverRunId),
                    info,
                    new ReceiverCapabilities(
                        ProtocolConstants.ChunkSize,
                        ProtocolConstants.MaximumRelativePathLength,
                        WindowsPathPolicy.Version,
                        2,
                        2,
                        "sha256",
                        true,
                        new[] { "portableLibrary" },
                        new[] { StorageArea.Master, StorageArea.LibraryData })),
                jsonOptions);
        });

        app.MapPost("/v2/jobs", async (HttpContext context) =>
        {
            ConfigureJobManifestRequestLimit(context);
            var job = await ReadRequiredAsync<ExportJob>(context, jsonOptions);
            return Results.Json(await coordinator.CreateJobAsync(job, context.RequestAborted), jsonOptions);
        });

        app.MapGet("/v2/jobs/{jobId:guid}", async (Guid jobId, HttpContext context) =>
            Results.Json(await coordinator.GetStatusAsync(jobId, context.RequestAborted), jsonOptions));

        app.MapPut("/v2/jobs/{jobId:guid}/files/{fileId:guid}/chunks/{chunkIndex:int}", async (
            Guid jobId,
            Guid fileId,
            int chunkIndex,
            HttpContext context) =>
        {
            var (start, end, total) = ModelValidation.ParseContentRange(context.Request.Headers.ContentRange.ToString());
            var sha = context.Request.Headers["X-Chunk-SHA256"].ToString();
            var receipt = await coordinator.PutChunkAsync(
                jobId,
                fileId,
                chunkIndex,
                start,
                end,
                total,
                sha,
                context.Request.Body,
                context.RequestAborted);
            return Results.Json(receipt, jsonOptions);
        });

        app.MapPost("/v2/jobs/{jobId:guid}/files/{fileId:guid}/commit", async (
            Guid jobId,
            Guid fileId,
            HttpContext context) =>
        {
            var request = await ReadRequiredAsync<CommitFileRequest>(context, jsonOptions);
            return Results.Json(await coordinator.CommitAsync(jobId, fileId, request, context.RequestAborted), jsonOptions);
        });

        app.MapPost("/v2/jobs/{jobId:guid}/complete", async (Guid jobId, HttpContext context) =>
        {
            var request = await ReadRequiredAsync<CompleteJobRequest>(context, jsonOptions);
            return Results.Json(await coordinator.CompleteAsync(jobId, request, context.RequestAborted), jsonOptions);
        });

        app.MapPost("/v2/jobs/{jobId:guid}/abandon", async (Guid jobId, HttpContext context) =>
        {
            var request = await ReadRequiredAsync<AbandonJobRequest>(context, jsonOptions);
            return Results.Json(await coordinator.AbandonAsync(jobId, request, context.RequestAborted), jsonOptions);
        });
    }

    private static void ConfigureJobManifestRequestLimit(HttpContext context)
    {
        if (context.Request.ContentLength > MaximumJobManifestBytes)
        {
            throw new ReceiverApiException(413, ErrorCodes.InvalidRequest,
                "The frozen job manifest exceeds the 1 GiB receiver limit.");
        }

        var feature = context.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (feature is { IsReadOnly: false })
        {
            feature.MaxRequestBodySize = MaximumJobManifestBytes;
        }
    }

    private static async Task<T> ReadRequiredAsync<T>(HttpContext context, JsonSerializerOptions jsonOptions)
    {
        var result = await context.Request.ReadFromJsonAsync<T>(jsonOptions, context.RequestAborted);
        return result ?? throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "A JSON request body is required.");
    }
}
