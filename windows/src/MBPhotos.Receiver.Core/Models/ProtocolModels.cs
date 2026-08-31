using System.Text.Json.Serialization;

namespace MBPhotos.Receiver.Models;

public static class ProtocolConstants
{
    public const int Version = 1;
    public const int ChunkSize = 8 * 1024 * 1024;
    public const int MaximumRelativePathLength = 239;
}

public sealed record ClientDescriptor(string Name, string Version, string InstanceId);

public sealed record PairRequest(int ProtocolVersion, string Token, ClientDescriptor Client);

public sealed record PairResponse(
    int ProtocolVersion,
    string SessionToken,
    Guid ReceiverRunId,
    DestinationInfo Destination,
    ReceiverCapabilities Capabilities);

public sealed record ReceiverCapabilities(
    int ChunkSizeBytes,
    int MaxRelativePathUtf16Units,
    int PathPolicyVersion,
    string HashAlgorithm,
    bool SequentialChunksRequired,
    IReadOnlyList<string> SupportedProfiles);

public sealed record DestinationInfo(
    Guid DestinationId,
    string DisplayName,
    DateTimeOffset CreatedAt,
    long FreeBytes,
    int PathPolicyVersion);

public enum ExportProfileKind
{
    PreserveOriginals,
    OriginalsAndCurrentJpegs,
}

public sealed record ExportProfile(
    ExportProfileKind Kind,
    int ProfileVersion,
    bool PreserveLocation,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? JpegRendererVersion = null);

public enum SelectionKind
{
    AllAccessible,
    NewOrChanged,
    DateRange,
    Albums,
    Manual,
}

public sealed record DateRange(DateTimeOffset Start, DateTimeOffset End);

public sealed record SelectionSnapshot(
    SelectionKind Kind,
    int AssetCount,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] DateRange? DateRange = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? SourceAlbumIdentifiers = null);

public sealed record RecoveryFingerprint(
    DateTimeOffset? CaptureDate,
    int PixelWidth,
    int PixelHeight,
    long? DurationMilliseconds,
    string MediaType,
    IReadOnlyList<string> OriginalFilenames,
    IReadOnlyList<long?> ResourceByteCounts);

public sealed record AssetLocation(
    double Latitude,
    double Longitude,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] double? AltitudeMeters = null);

public enum ExportFileKind
{
    OriginalResource,
    CurrentJpeg,
}

public enum ResourceType
{
    Photo,
    Video,
    AlternatePhoto,
    PairedVideo,
    Audio,
}

public sealed record ExportFile(
    Guid FileId,
    Guid AssetId,
    ExportFileKind Kind,
    ResourceType ResourceType,
    string OriginalFilename,
    string ProposedRelativePath,
    long? ByteCount,
    string? Sha256,
    string SourceRevision,
    DateTimeOffset? CaptureDate,
    string? ContentType);

public sealed record ExportAsset(
    Guid AssetId,
    string SourceLocalIdentifier,
    string SourceRevision,
    string MediaType,
    IReadOnlyList<string> MediaSubtypes,
    DateTimeOffset? CreationDate,
    DateTimeOffset? ModificationDate,
    bool IsEdited,
    RecoveryFingerprint RecoveryFingerprint,
    IReadOnlyList<ExportFile> Files,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] AssetLocation? Location = null);

public sealed record AlbumMembership(
    Guid AlbumId,
    string SourceAlbumIdentifier,
    string AlbumTitle,
    Guid? ParentAlbumId,
    Guid AssetId);

public sealed record ExportJob(
    int ProtocolVersion,
    Guid JobId,
    DateTimeOffset CreatedAt,
    string SourceTimeZone,
    ExportProfile Profile,
    SelectionSnapshot Selection,
    IReadOnlyList<ExportAsset> Assets,
    IReadOnlyList<AlbumMembership> AlbumMemberships);

public enum JobFileAction
{
    Upload,
    Skip,
    Resume,
    Conflict,
}

public sealed record FileDecision(
    Guid FileId,
    JobFileAction Action,
    string? AcceptedRelativePath,
    int NextChunkIndex,
    IReadOnlyList<ChunkRange> AcknowledgedChunks,
    string Reason);

public sealed record ChunkRange(int FirstIndex, int LastIndexInclusive);

public sealed record JobPlan(
    int ProtocolVersion,
    Guid JobId,
    DestinationInfo Destination,
    JobState State,
    IReadOnlyList<FileDecision> Decisions,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

public enum JobState
{
    Planned,
    Transferring,
    Paused,
    Completed,
    CompletedWithFailures,
    Abandoned,
}

public sealed record JobStatus(
    int ProtocolVersion,
    Guid JobId,
    DestinationInfo Destination,
    JobState State,
    IReadOnlyList<FileDecision> Decisions,
    IReadOnlyList<CommittedFile> CommittedFiles,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    CompletionReport? Report);

public sealed record ChunkReceipt(
    Guid JobId,
    Guid FileId,
    int ChunkIndex,
    long StartOffset,
    long EndOffsetExclusive,
    long ByteCount,
    string ChunkSha256,
    int NextChunkIndex,
    DateTimeOffset ReceivedAt);

public sealed record CommitFileRequest(long ByteCount, string Sha256);

public sealed record CommittedFile(
    Guid FileId,
    string State,
    string RelativePath,
    long ByteCount,
    string Sha256,
    DateTimeOffset CommittedAt);

public sealed record CompleteJobRequest(
    DateTimeOffset CompletedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<CompletionFailure>? Failures = null);

public sealed record CompletionFailure(Guid FileId, string Code, string Message, bool Retryable);

public sealed record CompletionCounts(
    int AssetsPlanned,
    int FilesPlanned,
    int FilesCommitted,
    int FilesSkipped,
    int FilesFailed,
    long BytesTransferred,
    long BytesCommitted,
    int VerifiedOriginalFiles);

public sealed record CompletionReport(
    int ProtocolVersion,
    Guid JobId,
    Guid DestinationId,
    string State,
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt,
    CompletionCounts Counts,
    IReadOnlyList<CompletionFailure> Failures,
    string ReportRelativePath,
    IReadOnlyList<string> ManifestRelativePaths);

public sealed record AbandonJobRequest(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Reason);

public sealed record AbandonJobResponse(Guid JobId, string State, int RemovedPartialFiles, DateTimeOffset AbandonedAt);

public sealed record ApiError(
    string Code,
    string Message,
    bool Retryable,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] Guid? RequestId = null);

public sealed class ReceiverApiException : Exception
{
    public ReceiverApiException(int statusCode, string code, string message, bool retryable = false)
        : base(message)
    {
        StatusCode = statusCode;
        Error = new ApiError(code, message, retryable);
    }

    public int StatusCode { get; }

    public ApiError Error { get; }
}

public static class ErrorCodes
{
    public const string AuthenticationRequired = "authentication_required";
    public const string AuthenticationInvalid = "authentication_invalid";
    public const string TokenExpired = "token_expired";
    public const string TokenConsumed = "token_consumed";
    public const string ProtocolMismatch = "protocol_mismatch";
    public const string DiskFull = "disk_full";
    public const string PathConflict = "path_conflict";
    public const string HashMismatch = "hash_mismatch";
    public const string UnavailableSource = "unavailable_source";
    public const string NetworkLoss = "network_loss";
    public const string ChangedDestination = "changed_destination";
    public const string InvalidRequest = "invalid_request";
    public const string UnsafePath = "unsafe_path";
    public const string JobNotFound = "job_not_found";
    public const string FileNotFound = "file_not_found";
    public const string JobConflict = "job_conflict";
    public const string FileConflict = "file_conflict";
    public const string ChunkConflict = "chunk_conflict";
    public const string ChunkOutOfOrder = "chunk_out_of_order";
    public const string InternalError = "internal_error";
}
