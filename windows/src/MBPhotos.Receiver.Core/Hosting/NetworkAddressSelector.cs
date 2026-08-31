using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace MBPhotos.Receiver.Hosting;

public static class NetworkAddressSelector
{
    public static IReadOnlyList<IPAddress> GetPrivateIpv4Addresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(static network =>
                network.OperationalStatus == OperationalStatus.Up &&
                network.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                network.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
            .SelectMany(static network => network.GetIPProperties().UnicastAddresses
                .Select(address => new
                {
                    Address = address.Address,
                    network.NetworkInterfaceType,
                    HasDefaultGateway = network.GetIPProperties().GatewayAddresses.Any(gateway =>
                        gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                        !gateway.Address.Equals(IPAddress.Any)),
                }))
            .Where(static candidate =>
                candidate.Address.AddressFamily == AddressFamily.InterNetwork && IsPrivate(candidate.Address))
            .GroupBy(static candidate => candidate.Address)
            .Select(static group => group
                .OrderByDescending(static candidate => candidate.HasDefaultGateway)
                .ThenByDescending(static candidate => candidate.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
                .First())
            .OrderByDescending(static candidate => candidate.HasDefaultGateway)
            .ThenByDescending(static candidate => candidate.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
            .ThenBy(static candidate => candidate.Address.ToString(), StringComparer.Ordinal)
            .Select(static candidate => candidate.Address)
            .ToArray();

    public static IPAddress SelectPreferred() => GetPrivateIpv4Addresses().FirstOrDefault()
        ?? throw new InvalidOperationException("No private IPv4 network is available. Connect both devices to the same Wi-Fi network.");

    public static bool IsPrivate(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes.Length == 4 &&
            (bytes[0] == 10 ||
             (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
             (bytes[0] == 192 && bytes[1] == 168));
    }
}
