using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using RemoteForge;

namespace LoggingForge;

public sealed class LoggingInfo : IRemoteForge
{
    public static string ForgeName => "Logging";
    public static string ForgeDescription => "Forge to log the PSRemoting payloads";

    private readonly string _logPath;

    private LoggingInfo(string logPath)
    {
        _logPath = logPath;
    }

    public string GetTransportString() => $"Logging:{_logPath}";

    public static IRemoteForge Create(string info)
    {
        if (string.IsNullOrWhiteSpace(info))
        {
            throw new ArgumentException("Logging forge requires a path to log to");
        }

        return new LoggingInfo(info);
    }

    public RemoteTransport CreateTransport()
        => new PwshTransport(_logPath);
}


public sealed class PwshTransport : ProcessTransport
{
    private readonly StreamWriter _logWriter;

    public PwshTransport(string logPath) : base("pwsh", new string[] { "-NoLogo", "-ServerMode" })
    {
        _logWriter = new StreamWriter(File.Open(logPath, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read));
    }

    protected override async Task WriteInput(string line, CancellationToken cancellationToken)
    {
        await _logWriter.WriteLineAsync(line.AsMemory(), cancellationToken);
        await _logWriter.FlushAsync();
        await base.WriteInput(line, cancellationToken);
    }

    protected override async Task<string?> ReadOutput(CancellationToken cancellationToken)
    {
        string? line = await base.ReadOutput(cancellationToken);
        if (!string.IsNullOrWhiteSpace(line))
        {
            await _logWriter.WriteLineAsync(line.AsMemory(), cancellationToken);
            await _logWriter.FlushAsync();
        }

        return line;
    }

    protected override void Dispose(bool isDisposing)
    {
        if (isDisposing)
        {
            _logWriter?.Dispose();
        }
        base.Dispose(isDisposing);
    }
}
