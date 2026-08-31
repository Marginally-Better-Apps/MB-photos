using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace MBPhotos.Receiver.Pairing;

public sealed class EphemeralCertificate : IDisposable
{
    private EphemeralCertificate(X509Certificate2 certificate, string fingerprint)
    {
        Certificate = certificate;
        Sha256Fingerprint = fingerprint;
    }

    public X509Certificate2 Certificate { get; }

    public string Sha256Fingerprint { get; }

    public static EphemeralCertificate Create(IPAddress address)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest(
            "CN=MB Photos Receiver",
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        var san = new SubjectAlternativeNameBuilder();
        san.AddIpAddress(address);
        san.AddDnsName("localhost");
        request.CertificateExtensions.Add(san.Build());

        var generated = request.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddMinutes(-5),
            DateTimeOffset.UtcNow.AddDays(2));
        var export = generated.Export(X509ContentType.Pfx);
        var certificate = new X509Certificate2(export, (string?)null, X509KeyStorageFlags.EphemeralKeySet);
        var fingerprint = Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();
        return new EphemeralCertificate(certificate, fingerprint);
    }

    public void Dispose() => Certificate.Dispose();
}
