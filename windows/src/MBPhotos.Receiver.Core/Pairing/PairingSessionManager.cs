using System.Security.Cryptography;
using System.Text;
using MBPhotos.Receiver.Models;

namespace MBPhotos.Receiver.Pairing;

public sealed record PairingRun(
    string ReceiverRunId,
    string Token,
    DateTimeOffset ExpiresAt,
    string? SessionToken);

/// <summary>
/// A safe, immutable view of pairing state. The active bearer is represented only
/// by a boolean; bearer material and digests are never exposed to observers.
/// </summary>
public sealed record PairingSessionSnapshot(
    string ReceiverRunId,
    string? InvitationToken,
    DateTimeOffset? InvitationExpiresAt,
    bool HasActiveSession,
    long Revision = 0);

public sealed class PairingSessionManager
{
    private static readonly TimeSpan DefaultInvitationLifetime = TimeSpan.FromMinutes(5);

    private readonly object sync = new();
    private byte[] invitationDigest = Array.Empty<byte>();
    private byte[] sessionDigest = Array.Empty<byte>();
    private string invitationToken = string.Empty;
    private string receiverRunId = string.Empty;
    private DateTimeOffset? invitationExpiresAt;
    private long stateRevision;

    public event EventHandler<PairingSessionSnapshot>? StateChanged;

    public PairingRun StartRun(TimeSpan? lifetime = null)
    {
        PairingRun run;
        PairingSessionSnapshot snapshot;
        lock (sync)
        {
            ClearSecret(ref invitationDigest);
            ClearSecret(ref sessionDigest);
            receiverRunId = Guid.NewGuid().ToString("D");
            CreateInvitation(lifetime);
            stateRevision++;
            run = new PairingRun(receiverRunId, invitationToken, invitationExpiresAt!.Value, null);
            snapshot = SnapshotUnsafe();
        }

        PublishStateChanged(snapshot);
        return run;
    }

    public PairingRun GetRun()
    {
        lock (sync)
        {
            EnsureStarted();
            return new PairingRun(
                receiverRunId,
                invitationToken,
                invitationExpiresAt ?? DateTimeOffset.MinValue,
                null);
        }
    }

    public PairingSessionSnapshot GetSnapshot()
    {
        lock (sync)
        {
            EnsureStarted();
            return SnapshotUnsafe();
        }
    }

    /// <summary>
    /// Replaces only the short-lived invitation. An authenticated phone keeps its
    /// current bearer until another phone successfully redeems this invitation.
    /// </summary>
    public PairingSessionSnapshot RefreshInvitation(TimeSpan? lifetime = null)
    {
        PairingSessionSnapshot snapshot;
        lock (sync)
        {
            EnsureStarted();
            CreateInvitation(lifetime);
            stateRevision++;
            snapshot = SnapshotUnsafe();
        }

        PublishStateChanged(snapshot);
        return snapshot;
    }

    /// <summary>
    /// Atomically renews an invitation only when that exact invitation is expired.
    /// A concurrent redemption clears the invitation first, so an expiry timer
    /// cannot make a QR code reappear after a phone connects.
    /// </summary>
    public PairingSessionSnapshot RefreshExpiredInvitation(
        DateTimeOffset? now = null,
        TimeSpan? lifetime = null)
    {
        PairingSessionSnapshot snapshot;
        var changed = false;
        lock (sync)
        {
            EnsureStarted();
            var effectiveNow = now ?? DateTimeOffset.UtcNow;
            if (invitationDigest.Length > 0 &&
                invitationExpiresAt is { } expiresAt &&
                effectiveNow >= expiresAt)
            {
                CreateInvitation(lifetime, effectiveNow);
                stateRevision++;
                changed = true;
            }

            snapshot = SnapshotUnsafe();
        }

        if (changed)
        {
            PublishStateChanged(snapshot);
        }

        return snapshot;
    }

    /// <summary>
    /// Creates an invitation only if none is currently available. This is used at
    /// a terminal HTTP boundary so an idempotent retry cannot rotate a displayed QR.
    /// </summary>
    public PairingSessionSnapshot EnsureInvitation(TimeSpan? lifetime = null)
    {
        PairingSessionSnapshot snapshot;
        var changed = false;
        lock (sync)
        {
            EnsureStarted();
            if (invitationDigest.Length == 0)
            {
                CreateInvitation(lifetime);
                stateRevision++;
                changed = true;
            }

            snapshot = SnapshotUnsafe();
        }

        if (changed)
        {
            PublishStateChanged(snapshot);
        }

        return snapshot;
    }

    /// <summary>
    /// Creates an invitation only while the supplied bearer still identifies the
    /// current active session. Authorization and invitation creation share one
    /// lock, so a late response from an older phone cannot resurrect a QR after a
    /// newer phone has paired.
    /// </summary>
    public PairingSessionSnapshot EnsureInvitationForAuthorizedSession(
        string? authorizationHeader,
        TimeSpan? lifetime = null)
    {
        const string prefix = "Bearer ";
        var supplied = !string.IsNullOrWhiteSpace(authorizationHeader) &&
            authorizationHeader.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                ? authorizationHeader[prefix.Length..].Trim()
                : string.Empty;
        var suppliedDigest = SHA256.HashData(Encoding.UTF8.GetBytes(supplied));
        PairingSessionSnapshot snapshot;
        var changed = false;
        try
        {
            lock (sync)
            {
                EnsureStarted();
                var authorized = sessionDigest.Length > 0 &&
                    CryptographicOperations.FixedTimeEquals(suppliedDigest, sessionDigest);
                if (authorized && invitationDigest.Length == 0)
                {
                    CreateInvitation(lifetime);
                    stateRevision++;
                    changed = true;
                }

                snapshot = SnapshotUnsafe();
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(suppliedDigest);
        }

        if (changed)
        {
            PublishStateChanged(snapshot);
        }

        return snapshot;
    }

    /// <summary>
    /// Removes an idle invitation without affecting the active bearer session.
    /// </summary>
    public PairingSessionSnapshot RetractInvitation()
    {
        PairingSessionSnapshot snapshot;
        var changed = false;
        lock (sync)
        {
            EnsureStarted();
            if (invitationDigest.Length > 0)
            {
                ClearInvitation();
                stateRevision++;
                changed = true;
            }

            snapshot = SnapshotUnsafe();
        }

        if (changed)
        {
            PublishStateChanged(snapshot);
        }

        return snapshot;
    }

    public string Redeem(PairRequest request, DateTimeOffset? now = null)
    {
        if (request.ProtocolVersion != ProtocolConstants.Version)
        {
            throw new ReceiverApiException(426, ErrorCodes.ProtocolMismatch, "Only protocol version 2 is supported. Replan the transfer for a fresh portable library.");
        }

        if (request.Client is null ||
            string.IsNullOrWhiteSpace(request.Client.Name) ||
            request.Client.Name.Length > 80 ||
            string.IsNullOrWhiteSpace(request.Client.Version) ||
            request.Client.Version.Length > 40 ||
            !Guid.TryParse(request.Client.InstanceId, out var instanceId) ||
            instanceId == Guid.Empty)
        {
            throw new ReceiverApiException(400, ErrorCodes.InvalidRequest,
                "client name (at most 80 characters), version (at most 40 characters), and a non-empty UUID instanceId are required.");
        }

        string session;
        PairingSessionSnapshot snapshot;
        lock (sync)
        {
            EnsureStarted();
            if (invitationDigest.Length == 0)
            {
                throw new ReceiverApiException(409, ErrorCodes.TokenConsumed, "The pairing code is no longer available.");
            }

            if (invitationExpiresAt is not { } expiresAt ||
                (now ?? DateTimeOffset.UtcNow) >= expiresAt)
            {
                throw new ReceiverApiException(410, ErrorCodes.TokenExpired, "The pairing code expired. Use the receiver's new code.");
            }

            var requestDigest = SHA256.HashData(Encoding.UTF8.GetBytes(request.Token ?? string.Empty));
            if (!CryptographicOperations.FixedTimeEquals(requestDigest, invitationDigest))
            {
                throw new ReceiverApiException(401, ErrorCodes.AuthenticationInvalid, "The pairing token is invalid.");
            }

            session = CreateToken();
            ClearSecret(ref sessionDigest);
            sessionDigest = SHA256.HashData(Encoding.UTF8.GetBytes(session));
            ClearInvitation();
            stateRevision++;
            snapshot = SnapshotUnsafe();
        }

        PublishStateChanged(snapshot);
        return session;
    }

    public bool Authorize(string? authorizationHeader)
    {
        const string prefix = "Bearer ";
        if (string.IsNullOrWhiteSpace(authorizationHeader) ||
            !authorizationHeader.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var supplied = authorizationHeader[prefix.Length..].Trim();
        var suppliedDigest = SHA256.HashData(Encoding.UTF8.GetBytes(supplied));
        lock (sync)
        {
            return sessionDigest.Length > 0 &&
                CryptographicOperations.FixedTimeEquals(suppliedDigest, sessionDigest);
        }
    }

    public string CreateQrPayload(string host, int port, string certificateFingerprint)
    {
        lock (sync)
        {
            EnsureStarted();
            if (invitationDigest.Length == 0)
            {
                throw new InvalidOperationException("No pairing invitation is currently available.");
            }

            return CreateQrPayload(invitationToken, host, port, certificateFingerprint);
        }
    }

    public void EndRun()
    {
        PairingSessionSnapshot? snapshot = null;
        lock (sync)
        {
            if (string.IsNullOrEmpty(receiverRunId))
            {
                return;
            }

            ClearSecret(ref invitationDigest);
            ClearSecret(ref sessionDigest);
            invitationToken = string.Empty;
            invitationExpiresAt = null;
            receiverRunId = string.Empty;
            stateRevision++;
            snapshot = SnapshotUnsafe();
        }

        PublishStateChanged(snapshot);
    }

    internal static string CreateQrPayload(
        string invitationToken,
        string host,
        int port,
        string certificateFingerprint) =>
        "mbphotos://pair" +
        $"?v={ProtocolConstants.Version}" +
        $"&host={Uri.EscapeDataString(host)}" +
        $"&port={port}" +
        $"&token={Uri.EscapeDataString(invitationToken)}" +
        $"&cert={Uri.EscapeDataString(certificateFingerprint)}";

    private void CreateInvitation(TimeSpan? lifetime, DateTimeOffset? now = null)
    {
        ClearSecret(ref invitationDigest);
        invitationToken = CreateToken();
        invitationDigest = SHA256.HashData(Encoding.UTF8.GetBytes(invitationToken));
        invitationExpiresAt = (now ?? DateTimeOffset.UtcNow).Add(lifetime ?? DefaultInvitationLifetime);
    }

    private void ClearInvitation()
    {
        ClearSecret(ref invitationDigest);
        invitationToken = string.Empty;
        invitationExpiresAt = null;
    }

    private PairingSessionSnapshot SnapshotUnsafe() =>
        new(
            receiverRunId,
            invitationDigest.Length == 0 ? null : invitationToken,
            invitationDigest.Length == 0 ? null : invitationExpiresAt,
            sessionDigest.Length > 0,
            stateRevision);

    private void PublishStateChanged(PairingSessionSnapshot snapshot)
    {
        var handlers = StateChanged;
        if (handlers is null)
        {
            return;
        }

        foreach (EventHandler<PairingSessionSnapshot> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, snapshot);
            }
            catch
            {
                // Pairing observers are advisory. They must never change an HTTP
                // authentication result or make a successfully redeemed code fail.
            }
        }
    }

    private void EnsureStarted()
    {
        if (string.IsNullOrEmpty(receiverRunId))
        {
            throw new InvalidOperationException("No receiver pairing run is active.");
        }
    }

    private static void ClearSecret(ref byte[] secret)
    {
        if (secret.Length > 0)
        {
            CryptographicOperations.ZeroMemory(secret);
        }

        secret = Array.Empty<byte>();
    }

    private static string CreateToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}
