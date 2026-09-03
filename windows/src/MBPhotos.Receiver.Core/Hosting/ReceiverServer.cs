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

public sealed record ReceiverPairingState(
    Guid ReceiverRunId,
    string? QrPayload,
    DateTimeOffset? InvitationExpiresAt,
    bool HasActiveSession,
    long Revision = 0);

public sealed record ReceiverTerminalResponseCompletedEventArgs(
    Guid JobId,
    string State,
    CompletionCounts? Counts,
    bool ReceiverIdle = true);

public sealed class ReceiverServer : IAsyncDisposable
{
    public const long MaximumJobManifestBytes = 1024L * 1024 * 1024;
    private const long MaximumOrdinaryRequestBytes = 128L * 1024 * 1024;
    private readonly WebApplication application;
    private readonly PairingSessionManager pairing;
    private readonly EphemeralCertificate certificate;
    private readonly Ledger ledger;
    private readonly DestinationLease destinationLease;
    private readonly ActiveJobTracker activeJobs;
    private readonly bool ownsDiagnostics;

    private ReceiverServer(
        WebApplication application,
        PairingSessionManager pairing,
        EphemeralCertificate certificate,
        Ledger ledger,
        DestinationLease destinationLease,
        ActiveJobTracker activeJobs,
        DestinationContext destination,
        JobCoordinator coordinator,
        RedactingFileLoggerProvider diagnostics,
        bool ownsDiagnostics,
        IPAddress address,
        int port)
    {
        this.application = application;
        this.pairing = pairing;
        this.certificate = certificate;
        this.ledger = ledger;
        this.destinationLease = destinationLease;
        this.activeJobs = activeJobs;
        Destination = destination;
        Coordinator = coordinator;
        Diagnostics = diagnostics;
        this.ownsDiagnostics = ownsDiagnostics;
        Address = address;
        Port = port;
        pairing.StateChanged += Pairing_StateChanged;
    }

    public DestinationContext Destination { get; }

    public JobCoordinator Coordinator { get; }

    public RedactingFileLoggerProvider Diagnostics { get; }

    public IPAddress Address { get; }

    public int Port { get; }

    /// <summary>
    /// Compatibility projection for callers that only support the initial QR.
    /// New callers should observe <see cref="PairingStateChanged"/>.
    /// </summary>
    public string QrPayload => PairingState.QrPayload
        ?? throw new InvalidOperationException("No pairing invitation is currently available.");

    public ReceiverPairingState PairingState => ToReceiverPairingState(pairing.GetSnapshot());

    public event EventHandler<ReceiverPairingState>? PairingStateChanged;

    public event EventHandler<ReceiverTerminalResponseCompletedEventArgs>? TerminalResponseCompleted;

    public Uri BaseUri => new($"https://{Address}:{Port}/");

    public string CertificateFingerprint => certificate.Sha256Fingerprint;

    public ReceiverPairingState RefreshPairingInvitation(TimeSpan? lifetime = null) =>
        ToReceiverPairingState(pairing.RefreshInvitation(lifetime));

    public ReceiverPairingState RefreshExpiredPairingInvitation(
        DateTimeOffset? now = null,
        TimeSpan? lifetime = null) =>
        ToReceiverPairingState(pairing.RefreshExpiredInvitation(now, lifetime));

    /// <summary>
    /// Atomically prevents new jobs from crossing the HTTP admission boundary.
    /// Used before navigating away from the receiver so a transfer cannot begin
    /// between the presentation check and listener shutdown.
    /// </summary>
    public bool TryQuiesceJobAdmissions()
    {
        if (!activeJobs.TryQuiesce())
        {
            return false;
        }

        pairing.RetractInvitation();
        return true;
    }

    public static async Task<ReceiverServer> StartAsync(
        string destinationPath,
        bool allowInitialize,
        IPAddress? listenAddress = null,
        string? diagnosticDirectory = null,
        CancellationToken cancellationToken = default,
        RedactingFileLoggerProvider? diagnosticProvider = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (diagnosticDirectory is not null && diagnosticProvider is not null)
        {
            throw new ArgumentException(
                "Choose either a diagnostic directory or a shared diagnostic provider, not both.",
                nameof(diagnosticProvider));
        }
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
        var ownsDiagnostics = diagnosticProvider is null;
        var diagnostics = diagnosticProvider ?? new RedactingFileLoggerProvider(diagnosticDirectory);

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            ApplicationName = typeof(ReceiverServer).Assembly.FullName,
            Args = Array.Empty<string>(),
        });
        builder.Logging.ClearProviders();
        builder.Logging.AddProvider(ownsDiagnostics
            ? diagnostics
            : new NonDisposingLoggerProvider(diagnostics));
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
        ReceiverServer? startedServer = null;
        var activeJobs = new ActiveJobTracker();
        ConfigurePipeline(
            app,
            pairing,
            destination,
            destinationManager,
            coordinator,
            run.ReceiverRunId,
            jsonOptions,
            activeJobs,
            diagnostics,
            terminal => startedServer?.HandleTerminalResponseCompleted(terminal));
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            await app.StartAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var addresses = app.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()?.Addresses
                ?? throw new InvalidOperationException("Kestrel did not publish its bound address.");
            var bound = addresses.Select(static value => new Uri(value)).Single();
            startedServer = new ReceiverServer(
                app,
                pairing,
                certificate,
                ledger,
                destinationLease,
                activeJobs,
                destination,
                coordinator,
                diagnostics,
                ownsDiagnostics,
                address,
                bound.Port);
            return startedServer;
        }
        catch
        {
            await app.DisposeAsync();
            certificate.Dispose();
            await ledger.DisposeAsync();
            destinationLease.Dispose();
            pairing.EndRun();
            if (ownsDiagnostics)
            {
                diagnostics.Dispose();
            }
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        var failures = new List<Exception>();

        static void ObserveUnobservedExceptions(Task task)
        {
            _ = task.ContinueWith(
                static failed => _ = failed.Exception,
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        void Attempt(Action action)
        {
            try { action(); }
            catch (Exception exception) { failures.Add(exception); }
        }

        async Task AttemptAsync(Func<Task> action, string stage)
        {
            try
            {
                var actionTask = action();
                if (await Task.WhenAny(actionTask, Task.Delay(TimeSpan.FromSeconds(10))).ConfigureAwait(false) != actionTask)
                {
                    ObserveUnobservedExceptions(actionTask);
                    failures.Add(new TimeoutException($"Receiver shutdown timed out during {stage}."));
                    return;
                }

                await actionTask.ConfigureAwait(false);
            }
            catch (Exception exception) { failures.Add(exception); }
        }

        Attempt(() => pairing.StateChanged -= Pairing_StateChanged);
        Attempt(pairing.EndRun);
        await AttemptAsync(() => application.StopAsync(TimeSpan.FromSeconds(5)), "HTTP listener stop");
        await AttemptAsync(() => ledger.PauseActiveJobsAsync(), "running-job pause");
        await AttemptAsync(() => application.DisposeAsync().AsTask(), "HTTP host disposal");
        Attempt(certificate.Dispose);
        await AttemptAsync(() => ledger.DisposeAsync().AsTask(), "ledger disposal");
        Attempt(destinationLease.Dispose);
        await AttemptAsync(
            () => ownsDiagnostics
                ? Diagnostics.DisposeAsync().AsTask()
                : Diagnostics.FlushAsync(),
            "diagnostics flush");

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
        JsonSerializerOptions jsonOptions,
        ActiveJobTracker activeJobs,
        RedactingFileLoggerProvider diagnostics,
        Action<ReceiverTerminalResponseCompletedEventArgs> terminalResponseCompleted)
    {
        async Task FlushDiagnosticsBestEffortAsync(CancellationToken cancellationToken)
        {
            try
            {
                await diagnostics.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            catch
            {
                // Diagnostics must never change receiver protocol behavior.
            }
        }

        app.Use(async (context, next) =>
        {
            var path = context.Request.Path.Value ?? string.Empty;
            var durableBoundary = string.Equals(path, "/v2/pair", StringComparison.Ordinal) ||
                string.Equals(path, "/v2/jobs", StringComparison.Ordinal);
            var startedAt = System.Diagnostics.Stopwatch.GetTimestamp();
            app.Logger.LogInformation(
                "Receiver request started method={Method} path={Path} contentLength={ContentLength}",
                context.Request.Method,
                path,
                context.Request.ContentLength);
            if (durableBoundary)
            {
                await FlushDiagnosticsBestEffortAsync(context.RequestAborted).ConfigureAwait(false);
            }

            try
            {
                await next(context).ConfigureAwait(false);
            }
            finally
            {
                app.Logger.LogInformation(
                    "Receiver request finished method={Method} path={Path} status={StatusCode} elapsedMs={ElapsedMilliseconds:F1}",
                    context.Request.Method,
                    path,
                    context.Response.StatusCode,
                    System.Diagnostics.Stopwatch.GetElapsedTime(startedAt).TotalMilliseconds);
                if (durableBoundary)
                {
                    await FlushDiagnosticsBestEffortAsync(CancellationToken.None).ConfigureAwait(false);
                }
            }
        });

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
            // Count the admission before reading what may be a very large body.
            // Library navigation must not quiesce the listener, and a failed
            // sibling request must not restore the QR, while any manifest is
            // still crossing the HTTP boundary.
            var pendingAdmission = activeJobs.BeginPending();
            // Reserve the displayed invitation before reading what may be a very
            // large manifest. Authentication middleware has already accepted the
            // bearer, but without this reservation a second scan could replace it
            // while the old request body is still arriving.
            pairing.RetractInvitation();
            var authorizationHeader = context.Request.Headers.Authorization.ToString();
            if (!pairing.Authorize(authorizationHeader))
            {
                // Redemption won immediately before the invitation reservation.
                // Reject the superseded bearer before accepting a large body.
                activeJobs.CancelPending(pendingAdmission, _ => { });
                throw new ReceiverApiException(
                    401,
                    ErrorCodes.AuthenticationInvalid,
                    "The receiver session changed while the transfer was starting.");
            }

            ExportJob job;
            try
            {
                job = await ReadRequiredAsync<ExportJob>(context, jsonOptions);
                app.Logger.LogInformation(
                    "Job manifest received jobId={JobId} assets={AssetCount} files={FileCount} selection={SelectionKind}",
                    job.JobId,
                    job.Assets.Count,
                    job.Assets.Sum(static asset => asset.Files.Count),
                    job.Selection.Kind);
                await FlushDiagnosticsBestEffortAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch
            {
                activeJobs.CancelPending(pendingAdmission, receiverIdle =>
                {
                    if (receiverIdle)
                    {
                        TryEnsureInvitation(pairing, authorizationHeader);
                    }
                });
                throw;
            }

            // Keep the reservation valid across a long read in case another
            // presentation action explicitly refreshed pairing state.
            if (!pairing.Authorize(authorizationHeader))
            {
                // A successful newer pairing owns the receiver now. Release this
                // old request's reservation without displaying another code.
                activeJobs.CancelPending(pendingAdmission, _ => { });
                throw new ReceiverApiException(
                    401,
                    ErrorCodes.AuthenticationInvalid,
                    "The receiver session changed while the transfer was starting.");
            }

            JobAdmission admission;
            try
            {
                admission = activeJobs.Promote(pendingAdmission, job.JobId);
            }
            catch
            {
                activeJobs.ObserveIdle(receiverIdle =>
                {
                    if (receiverIdle)
                    {
                        TryEnsureInvitation(pairing, authorizationHeader);
                    }
                });
                throw;
            }
            try
            {
                var plan = await coordinator.CreateJobAsync(job, context.RequestAborted);
                app.Logger.LogInformation(
                    "Job plan created jobId={JobId} state={State} upload={UploadCount} resume={ResumeCount} skip={SkipCount} conflict={ConflictCount}",
                    job.JobId,
                    plan.State,
                    plan.Decisions.Count(static decision => decision.Action == JobFileAction.Upload),
                    plan.Decisions.Count(static decision => decision.Action == JobFileAction.Resume),
                    plan.Decisions.Count(static decision => decision.Action == JobFileAction.Skip),
                    plan.Decisions.Count(static decision => decision.Action == JobFileAction.Conflict));
                await FlushDiagnosticsBestEffortAsync(CancellationToken.None).ConfigureAwait(false);
                if (plan.State is JobState.Completed or JobState.CompletedWithFailures or JobState.Abandoned)
                {
                    var terminalActivity = coordinator.GetTerminalActivity(job.JobId);
                    var terminalState = terminalActivity?.State ?? plan.State switch
                    {
                        JobState.Completed => "completed",
                        JobState.CompletedWithFailures => "completedWithFailures",
                        JobState.Abandoned => "abandoned",
                        _ => throw new InvalidOperationException("The plan is not terminal."),
                    };
                    // A terminal manifest is an idempotent recovery response. Keep
                    // its admission tracked until that response is actually sent.
                    context.Response.OnCompleted(() =>
                    {
                        activeJobs.FinishTerminalPlan(
                            admission,
                            receiverIdle =>
                            {
                                if (receiverIdle)
                                {
                                    TryEnsureInvitation(pairing, authorizationHeader);
                                }
                                terminalResponseCompleted(new ReceiverTerminalResponseCompletedEventArgs(
                                    job.JobId,
                                    terminalState,
                                    terminalActivity?.CompletionCounts,
                                    receiverIdle));
                            });
                        return Task.CompletedTask;
                    });
                }
                else
                {
                    activeJobs.Accept(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }

                return Results.Json(plan, jsonOptions);
            }
            catch
            {
                JobState? durableState = null;
                var durableStateInspected = false;
                try
                {
                    durableState = await coordinator.GetDurableJobStateAsync(job.JobId, CancellationToken.None);
                    durableStateInspected = true;
                }
                catch
                {
                    // Conservatively retain the bearer if durable state cannot be
                    // inspected. A retry can recover it without exposing a code
                    // that might replace the still-valid session.
                }

                if (durableState is JobState.Completed or JobState.CompletedWithFailures or JobState.Abandoned)
                {
                    activeJobs.FailDurableTerminal(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected && durableState is null)
                {
                    activeJobs.ReleaseMissing(
                        admission,
                        true,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected)
                {
                    // Planning may have durably created or resumed the job before
                    // the response failed. Retain it and the current bearer; a
                    // same-job retry can recover without exposing a replacement QR.
                    try
                    {
                        await coordinator.PublishDurableActiveActivityAsync(job.JobId, CancellationToken.None);
                    }
                    catch
                    {
                        // The tracker remains authoritative even if advisory
                        // presentation recovery cannot read progress right now.
                    }
                    activeJobs.Accept(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else
                {
                    activeJobs.RetainProvisional(
                        admission,
                        (receiverIdle, retainedProvisional) =>
                        {
                            if (retainedProvisional)
                            {
                                pairing.RetractInvitation();
                            }
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                throw;
            }
        });

        app.MapGet("/v2/jobs/{jobId:guid}", async (Guid jobId, HttpContext context) =>
        {
            var admission = activeJobs.BeginJobOperation(jobId);
            var authorizationHeader = context.Request.Headers.Authorization.ToString();
            try
            {
                var status = await coordinator.GetStatusAsync(jobId, context.RequestAborted);
                if (!pairing.Authorize(authorizationHeader))
                {
                    throw new ReceiverApiException(
                        401,
                        ErrorCodes.AuthenticationInvalid,
                        "The receiver session changed while status was being recovered.");
                }

                var terminal = status.State is JobState.Completed or JobState.CompletedWithFailures or JobState.Abandoned;
                var terminalActivity = terminal ? coordinator.GetTerminalActivity(jobId) : null;
                context.Response.OnCompleted(() =>
                {
                    if (terminal)
                    {
                        activeJobs.Complete(
                            admission,
                            receiverIdle =>
                            {
                                if (receiverIdle)
                                {
                                    TryEnsureInvitation(pairing, authorizationHeader);
                                }
                                terminalResponseCompleted(new ReceiverTerminalResponseCompletedEventArgs(
                                    jobId,
                                    terminalActivity?.State ?? status.State switch
                                    {
                                        JobState.Completed => "completed",
                                        JobState.CompletedWithFailures => "completedWithFailures",
                                        JobState.Abandoned => "abandoned",
                                        _ => throw new InvalidOperationException("The status is not terminal."),
                                    },
                                    terminalActivity?.CompletionCounts ?? status.Report?.Counts,
                                    receiverIdle));
                            });
                    }
                    else
                    {
                        activeJobs.FinishOperation(
                            admission,
                            receiverIdle =>
                            {
                                if (receiverIdle)
                                {
                                    TryEnsureInvitation(pairing, authorizationHeader);
                                }
                            });
                    }
                    return Task.CompletedTask;
                });
                return Results.Json(status, jsonOptions);
            }
            catch
            {
                JobState? durableState = null;
                var durableStateInspected = false;
                try
                {
                    durableState = await coordinator.GetDurableJobStateAsync(jobId, CancellationToken.None);
                    durableStateInspected = true;
                }
                catch
                {
                }

                if (durableState is JobState.Completed or JobState.CompletedWithFailures or JobState.Abandoned)
                {
                    activeJobs.FailDurableTerminal(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected && durableState is null)
                {
                    activeJobs.ReleaseMissing(
                        admission,
                        false,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected)
                {
                    try
                    {
                        await coordinator.PublishDurableActiveActivityAsync(jobId, CancellationToken.None);
                    }
                    catch
                    {
                    }
                    activeJobs.Accept(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else
                {
                    activeJobs.ReleaseUncertain(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                throw;
            }
        });

        app.MapPut("/v2/jobs/{jobId:guid}/files/{fileId:guid}/chunks/{chunkIndex:int}", async (
            Guid jobId,
            Guid fileId,
            int chunkIndex,
            HttpContext context) =>
        {
            activeJobs.RequireEstablished(jobId);
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
            activeJobs.RequireEstablished(jobId);
            var request = await ReadRequiredAsync<CommitFileRequest>(context, jsonOptions);
            return Results.Json(await coordinator.CommitAsync(jobId, fileId, request, context.RequestAborted), jsonOptions);
        });

        app.MapPost("/v2/jobs/{jobId:guid}/complete", async (Guid jobId, HttpContext context) =>
        {
            var admission = activeJobs.BeginJobOperation(jobId);
            var authorizationHeader = context.Request.Headers.Authorization.ToString();
            try
            {
                var request = await ReadRequiredAsync<CompleteJobRequest>(context, jsonOptions);
                if (!pairing.Authorize(authorizationHeader))
                {
                    throw new ReceiverApiException(
                        401,
                        ErrorCodes.AuthenticationInvalid,
                        "The receiver session changed while completion was being retried.");
                }

                var report = await coordinator.CompleteAsync(jobId, request, context.RequestAborted);
                context.Response.OnCompleted(() =>
                {
                    activeJobs.Complete(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                            terminalResponseCompleted(new ReceiverTerminalResponseCompletedEventArgs(
                                report.JobId,
                                report.State,
                                report.Counts,
                                receiverIdle));
                        });
                    return Task.CompletedTask;
                });
                return Results.Json(report, jsonOptions);
            }
            catch
            {
                JobState? durableState = null;
                var durableStateInspected = false;
                try
                {
                    durableState = await coordinator.GetDurableJobStateAsync(jobId, CancellationToken.None);
                    durableStateInspected = true;
                }
                catch
                {
                }

                if (durableState is JobState.Completed or JobState.CompletedWithFailures or JobState.Abandoned)
                {
                    activeJobs.FailDurableTerminal(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected && durableState is null)
                {
                    activeJobs.ReleaseMissing(
                        admission,
                        false,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected)
                {
                    try
                    {
                        await coordinator.PublishDurableActiveActivityAsync(jobId, CancellationToken.None);
                    }
                    catch
                    {
                    }
                    activeJobs.Accept(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else
                {
                    activeJobs.RetainProvisional(
                        admission,
                        (receiverIdle, retainedProvisional) =>
                        {
                            if (retainedProvisional)
                            {
                                pairing.RetractInvitation();
                            }
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                throw;
            }
        });

        app.MapPost("/v2/jobs/{jobId:guid}/abandon", async (Guid jobId, HttpContext context) =>
        {
            var admission = activeJobs.BeginJobOperation(jobId);
            var authorizationHeader = context.Request.Headers.Authorization.ToString();
            try
            {
                var request = await ReadRequiredAsync<AbandonJobRequest>(context, jsonOptions);
                if (!pairing.Authorize(authorizationHeader))
                {
                    throw new ReceiverApiException(
                        401,
                        ErrorCodes.AuthenticationInvalid,
                        "The receiver session changed while the transfer was being stopped.");
                }

                var response = await coordinator.AbandonAsync(jobId, request, context.RequestAborted);
                var terminalActivity = coordinator.GetTerminalActivity(response.JobId);
                context.Response.OnCompleted(() =>
                {
                    activeJobs.Complete(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                            terminalResponseCompleted(new ReceiverTerminalResponseCompletedEventArgs(
                                response.JobId,
                                response.State,
                                terminalActivity?.CompletionCounts,
                                receiverIdle));
                        });
                    return Task.CompletedTask;
                });
                return Results.Json(response, jsonOptions);
            }
            catch
            {
                JobState? durableState = null;
                var durableStateInspected = false;
                try
                {
                    durableState = await coordinator.GetDurableJobStateAsync(jobId, CancellationToken.None);
                    durableStateInspected = true;
                }
                catch
                {
                }

                if (durableState is JobState.Completed or JobState.CompletedWithFailures or JobState.Abandoned)
                {
                    activeJobs.FailDurableTerminal(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected && durableState is null)
                {
                    activeJobs.ReleaseMissing(
                        admission,
                        false,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else if (durableStateInspected)
                {
                    try
                    {
                        await coordinator.PublishDurableActiveActivityAsync(jobId, CancellationToken.None);
                    }
                    catch
                    {
                    }
                    activeJobs.Accept(
                        admission,
                        receiverIdle =>
                        {
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                else
                {
                    activeJobs.RetainProvisional(
                        admission,
                        (receiverIdle, retainedProvisional) =>
                        {
                            if (retainedProvisional)
                            {
                                pairing.RetractInvitation();
                            }
                            if (receiverIdle)
                            {
                                TryEnsureInvitation(pairing, authorizationHeader);
                            }
                        });
                }
                throw;
            }
        });
    }

    private void Pairing_StateChanged(object? sender, PairingSessionSnapshot snapshot)
    {
        PublishObserverEvent(PairingStateChanged, ToReceiverPairingState(snapshot));
    }

    private void HandleTerminalResponseCompleted(ReceiverTerminalResponseCompletedEventArgs terminal)
    {
        PublishObserverEvent(TerminalResponseCompleted, terminal);
    }

    private static void TryEnsureInvitation(
        PairingSessionManager pairing,
        string authorizationHeader)
    {
        try
        {
            pairing.EnsureInvitationForAuthorizedSession(authorizationHeader);
        }
        catch (InvalidOperationException)
        {
            // Receiver shutdown won the race with the response callback.
        }
    }

    private ReceiverPairingState ToReceiverPairingState(PairingSessionSnapshot snapshot)
    {
        _ = Guid.TryParse(snapshot.ReceiverRunId, out var runId);
        var qrPayload = snapshot.InvitationToken is { } token
            ? PairingSessionManager.CreateQrPayload(
                token,
                Address.ToString(),
                Port,
                certificate.Sha256Fingerprint)
            : null;
        return new ReceiverPairingState(
            runId,
            qrPayload,
            snapshot.InvitationExpiresAt,
            snapshot.HasActiveSession,
            snapshot.Revision);
    }

    private void PublishObserverEvent<T>(EventHandler<T>? handlers, T value)
    {
        if (handlers is null)
        {
            return;
        }

        foreach (EventHandler<T> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, value);
            }
            catch
            {
                // Presentation observers are advisory and cannot change pairing,
                // authentication, or a terminal HTTP response.
            }
        }
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

    private sealed record PendingJobAdmission(long Id);

    private sealed record JobAdmission(Guid JobId);

    /// <summary>
    /// Serializes the small HTTP admission boundary separately from potentially
    /// long coordinator work. Multiple sequential jobs remain supported in one
    /// receiver run, while a second job cannot replace the bearer or overlap the
    /// receiver's single-transfer presentation.
    /// </summary>
    private sealed class ActiveJobTracker
    {
        private readonly object sync = new();
        private readonly Dictionary<Guid, TrackedJob> trackedJobs = [];
        private readonly HashSet<long> pendingAdmissionIds = [];
        private readonly HashSet<Guid> terminalResponsesCompleted = [];
        private readonly HashSet<Guid> suppressedTerminalJobs = [];
        private long nextPendingAdmissionId;
        private bool acceptingJobs = true;

        public PendingJobAdmission BeginPending()
        {
            lock (sync)
            {
                if (!acceptingJobs)
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "The receiver is preparing to open the library. Try again after returning to Receive.",
                        true);
                }

                var admission = new PendingJobAdmission(++nextPendingAdmissionId);
                pendingAdmissionIds.Add(admission.Id);
                return admission;
            }
        }

        public JobAdmission Promote(PendingJobAdmission pendingAdmission, Guid jobId)
        {
            ArgumentNullException.ThrowIfNull(pendingAdmission);
            lock (sync)
            {
                ConsumePending(pendingAdmission);

                if (suppressedTerminalJobs.Count > 0 && !suppressedTerminalJobs.Contains(jobId))
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "Finish recovering the current transfer before starting another.",
                        true);
                }

                if (trackedJobs.Count > 0 && !trackedJobs.ContainsKey(jobId))
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "Finish the current transfer before starting another.",
                        true);
                }

                if (!trackedJobs.TryGetValue(jobId, out var job))
                {
                    job = new TrackedJob();
                    trackedJobs.Add(jobId, job);
                }

                checked
                {
                    job.InFlightAdmissions++;
                }
                return new JobAdmission(jobId);
            }
        }

        public JobAdmission BeginJobOperation(Guid jobId)
        {
            lock (sync)
            {
                if (suppressedTerminalJobs.Count > 0 && !suppressedTerminalJobs.Contains(jobId))
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "Finish recovering the current transfer before updating another job.",
                        true);
                }

                if (!acceptingJobs)
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "The receiver is preparing to open the library. Try again after returning to Receive.",
                        true);
                }

                if (trackedJobs.Count > 0 && !trackedJobs.ContainsKey(jobId))
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "Finish the current transfer before updating another job.",
                        true);
                }

                if (!trackedJobs.TryGetValue(jobId, out var job))
                {
                    job = new TrackedJob();
                    trackedJobs.Add(jobId, job);
                }

                checked
                {
                    job.InFlightAdmissions++;
                }
                return new JobAdmission(jobId);
            }
        }

        public void RequireEstablished(Guid jobId)
        {
            lock (sync)
            {
                if (!acceptingJobs)
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "The receiver is preparing to open the library. Try again after returning to Receive.",
                        true);
                }

                if (!trackedJobs.TryGetValue(jobId, out var job) ||
                    !job.Established ||
                    job.Terminal)
                {
                    throw new ReceiverApiException(
                        409,
                        ErrorCodes.JobConflict,
                        "Send or resume the transfer manifest before uploading files.",
                        true);
                }
            }
        }

        public void Accept(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                var drainsEligibleTerminal = trackedJobs.TryGetValue(admission.JobId, out var job) &&
                    job.Terminal && terminalResponsesCompleted.Contains(admission.JobId);
                ReleaseManifest(admission, establishesJob: true);
                transition(drainsEligibleTerminal && acceptingJobs && IsIdle);
            }
        }

        public void RetainProvisional(JobAdmission admission, Action<bool, bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                var drainsEligibleTerminal = terminalResponsesCompleted.Contains(admission.JobId);
                var retainedProvisional = false;
                if (trackedJobs.TryGetValue(admission.JobId, out var job))
                {
                    if (drainsEligibleTerminal)
                    {
                        // A completed response is process-lifetime knowledge.
                        // A transient retry record cannot regress that job to a
                        // provisional active owner.
                        job.Terminal = true;
                        job.Established = false;
                        job.Provisional = false;
                    }
                    else if (!job.Terminal && !job.Established)
                    {
                        job.Established = true;
                        job.Provisional = true;
                        retainedProvisional = true;
                    }
                    else
                    {
                        retainedProvisional = job.Provisional;
                    }
                }
                ReleaseManifest(admission, establishesJob: false);
                transition(
                    drainsEligibleTerminal && acceptingJobs && IsIdle,
                    retainedProvisional);
            }
        }

        public void ReleaseUncertain(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                var drainsEligibleTerminal = terminalResponsesCompleted.Contains(admission.JobId);
                if (drainsEligibleTerminal && trackedJobs.TryGetValue(admission.JobId, out var job))
                {
                    job.Terminal = true;
                    job.Established = false;
                    job.Provisional = false;
                }
                ReleaseManifest(admission, establishesJob: false);
                transition(drainsEligibleTerminal && acceptingJobs && IsIdle);
            }
        }

        public void ReleaseMissing(
            JobAdmission admission,
            bool restoreInvitationWhenIdle,
            Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                var drainsEligibleTerminal = false;
                if (trackedJobs.TryGetValue(admission.JobId, out var job))
                {
                    drainsEligibleTerminal = job.Terminal &&
                        terminalResponsesCompleted.Contains(admission.JobId);
                    if (job.Provisional)
                    {
                        job.Provisional = false;
                        job.Established = false;
                    }
                }
                ReleaseManifest(admission, establishesJob: false);
                transition(
                    (restoreInvitationWhenIdle || drainsEligibleTerminal) &&
                    acceptingJobs &&
                    IsIdle);
            }
        }

        public void FinishTerminalPlan(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                if (trackedJobs.TryGetValue(admission.JobId, out var job))
                {
                    // A terminal ledger plan is authoritative recovery: the
                    // original terminal response may have been lost after the
                    // durable transition, so this response owns clearing it.
                    job.Terminal = true;
                    job.Established = false;
                }
                terminalResponsesCompleted.Add(admission.JobId);
                suppressedTerminalJobs.Remove(admission.JobId);
                ReleaseManifest(admission, establishesJob: false);
                transition(acceptingJobs && IsIdle);
            }
        }

        public void FinishOperation(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                var drainedTerminal = trackedJobs.TryGetValue(admission.JobId, out var job) &&
                    job.Terminal && terminalResponsesCompleted.Contains(admission.JobId);
                ReleaseManifest(admission, establishesJob: false);
                transition(drainedTerminal && acceptingJobs && IsIdle);
            }
        }

        public void AbortOperation(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                var drainedTerminal = trackedJobs.TryGetValue(admission.JobId, out var job) &&
                    job.Terminal && terminalResponsesCompleted.Contains(admission.JobId);
                ReleaseManifest(admission, establishesJob: false);
                transition(drainedTerminal && acceptingJobs && IsIdle);
            }
        }

        public void CancelPending(PendingJobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                ConsumePending(admission);
                transition(acceptingJobs && IsIdle);
            }
        }

        public void Abort(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                ReleaseManifest(admission, establishesJob: false);
                transition(acceptingJobs && IsIdle);
            }
        }

        public void FailDurableTerminal(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                var invitationEligible = terminalResponsesCompleted.Contains(admission.JobId);
                if (trackedJobs.TryGetValue(admission.JobId, out var job))
                {
                    job.Terminal = true;
                    job.Established = false;
                    // Do not make a newly durable terminal transition eligible
                    // until a terminal HTTP response actually completes. Retain
                    // prior eligibility if an earlier response already crossed
                    // that boundary.
                }
                if (!invitationEligible)
                {
                    // Keep the receiver non-idle even if this job record drains
                    // before a pending manifest reveals its job ID. Only a later
                    // successful terminal response may release this suppression.
                    suppressedTerminalJobs.Add(admission.JobId);
                }
                ReleaseManifest(admission, establishesJob: false);
                transition(invitationEligible && acceptingJobs && IsIdle);
            }
        }

        public void Complete(JobAdmission admission, Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(admission);
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                if (trackedJobs.TryGetValue(admission.JobId, out var job))
                {
                    job.Terminal = true;
                    job.Established = false;
                }
                terminalResponsesCompleted.Add(admission.JobId);
                suppressedTerminalJobs.Remove(admission.JobId);
                ReleaseManifest(admission, establishesJob: false);
                transition(acceptingJobs && IsIdle);
            }
        }

        public void ObserveIdle(Action<bool> transition)
        {
            ArgumentNullException.ThrowIfNull(transition);
            lock (sync)
            {
                transition(acceptingJobs && IsIdle);
            }
        }

        public bool TryQuiesce()
        {
            lock (sync)
            {
                if (!IsIdle)
                {
                    return false;
                }

                acceptingJobs = false;
                return true;
            }
        }

        private bool IsIdle =>
            pendingAdmissionIds.Count == 0 &&
            trackedJobs.Count == 0 &&
            suppressedTerminalJobs.Count == 0;

        private void ConsumePending(PendingJobAdmission admission)
        {
            if (!pendingAdmissionIds.Remove(admission.Id))
            {
                throw new InvalidOperationException("The job admission is no longer pending.");
            }
        }

        private void ReleaseManifest(JobAdmission admission, bool establishesJob)
        {
            if (!trackedJobs.TryGetValue(admission.JobId, out var job) || job.InFlightAdmissions <= 0)
            {
                throw new InvalidOperationException("The job admission is no longer active.");
            }

            job.InFlightAdmissions--;
            if (establishesJob && !job.Terminal)
            {
                job.Established = true;
                job.Provisional = false;
            }
            RemoveIfReleased(admission.JobId, job);
        }

        private void RemoveIfReleased(Guid jobId, TrackedJob job)
        {
            if (!job.Established && job.InFlightAdmissions == 0)
            {
                trackedJobs.Remove(jobId);
            }
        }

        private sealed class TrackedJob
        {
            public int InFlightAdmissions { get; set; }

            public bool Established { get; set; }

            public bool Terminal { get; set; }

            public bool Provisional { get; set; }

        }
    }
}
