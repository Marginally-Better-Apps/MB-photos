using System.Security.Cryptography;
using System.Text;
using MBPhotos.Receiver.Models;

namespace MBPhotos.Receiver.Pairing;

public sealed record PairingRun(
    string ReceiverRunId,
    string Token,
    DateTimeOffset ExpiresAt,
    string? SessionToken);

public sealed class PairingSessionManager
{
    private readonly object sync = new();
    private byte[] tokenDigest = Array.Empty<byte>();
    private byte[] sessionDigest = Array.Empty<byte>();
    private string token = string.Empty;
    private string receiverRunId = string.Empty;
    private DateTimeOffset expiresAt;
    private bool redeemed;

    public PairingRun StartRun(TimeSpan? lifetime = null)
    {
        lock (sync)
        {
            token = CreateToken();
            tokenDigest = SHA256.HashData(Encoding.UTF8.GetBytes(token));
            sessionDigest = Array.Empty<byte>();
            receiverRunId = Guid.NewGuid().ToString("D");
            expiresAt = DateTimeOffset.UtcNow.Add(lifetime ?? TimeSpan.FromMinutes(5));
            redeemed = false;
            return new PairingRun(receiverRunId, token, expiresAt, null);
        }
    }

    public PairingRun GetRun()
    {
        lock (sync)
        {
            EnsureStarted();
            return new PairingRun(receiverRunId, token, expiresAt, null);
        }
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

        lock (sync)
        {
            EnsureStarted();
            if ((now ?? DateTimeOffset.UtcNow) > expiresAt)
            {
                throw new ReceiverApiException(410, ErrorCodes.TokenExpired, "The pairing code expired. Restart the receiver to create a new code.");
            }

            if (redeemed)
            {
                throw new ReceiverApiException(409, ErrorCodes.TokenConsumed, "The pairing code was already used.");
            }

            var requestDigest = SHA256.HashData(Encoding.UTF8.GetBytes(request.Token ?? string.Empty));
            if (!CryptographicOperations.FixedTimeEquals(requestDigest, tokenDigest))
            {
                throw new ReceiverApiException(401, ErrorCodes.AuthenticationInvalid, "The pairing token is invalid.");
            }

            var session = CreateToken();
            sessionDigest = SHA256.HashData(Encoding.UTF8.GetBytes(session));
            redeemed = true;
            token = string.Empty;
            CryptographicOperations.ZeroMemory(tokenDigest);
            tokenDigest = Array.Empty<byte>();
            return session;
        }
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
            return redeemed && sessionDigest.Length > 0 &&
                CryptographicOperations.FixedTimeEquals(suppliedDigest, sessionDigest);
        }
    }

    public string CreateQrPayload(string host, int port, string certificateFingerprint)
    {
        lock (sync)
        {
            EnsureStarted();
            if (redeemed)
            {
                throw new InvalidOperationException("The pairing token has already been redeemed.");
            }

            return "mbphotos://pair" +
                $"?v={ProtocolConstants.Version}" +
                $"&host={Uri.EscapeDataString(host)}" +
                $"&port={port}" +
                $"&token={Uri.EscapeDataString(token)}" +
                $"&cert={Uri.EscapeDataString(certificateFingerprint)}";
        }
    }

    public void EndRun()
    {
        lock (sync)
        {
            if (tokenDigest.Length > 0)
            {
                CryptographicOperations.ZeroMemory(tokenDigest);
            }

            if (sessionDigest.Length > 0)
            {
                CryptographicOperations.ZeroMemory(sessionDigest);
            }

            tokenDigest = Array.Empty<byte>();
            sessionDigest = Array.Empty<byte>();
            token = string.Empty;
            receiverRunId = string.Empty;
            redeemed = false;
        }
    }

    private void EnsureStarted()
    {
        if (string.IsNullOrEmpty(receiverRunId))
        {
            throw new InvalidOperationException("No receiver pairing run is active.");
        }
    }

    private static string CreateToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}
