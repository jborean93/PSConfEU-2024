using System;
using System.Collections.Generic;
using System.IO;
using RemoteForge;

namespace PythonForge;

public sealed class PythonInfo : IRemoteForge
{
    public static string ForgeName => "Python";
    public static string ForgeDescription => "Forge for Python targets";

    private readonly string? _logPath;
    private readonly string? _logLevel;

    private PythonInfo(string? logPath, string? logLevel)
    {
        _logPath = logPath;
        _logLevel = logLevel;
    }

    public string GetTransportString() => "Python:";

    public static IRemoteForge Create(string info)
    {
        string? logPath = null;
        string? logLevel = null;
        if (!string.IsNullOrWhiteSpace(info))
        {
            string[] parts = info.Split(';', StringSplitOptions.RemoveEmptyEntries);
            foreach (string part in parts)
            {
                string[] kv = part.Split('=', 2, StringSplitOptions.RemoveEmptyEntries);
                if (kv.Length != 2)
                {
                    throw new ArgumentException($"Invalid key-value pair: {part}");
                }

                string key = kv[0].Trim();
                string value = kv[1].Trim();
                if (key.Equals("log-path", StringComparison.OrdinalIgnoreCase))
                {
                    logPath = value;
                }
                else if (key.Equals("log-level", StringComparison.OrdinalIgnoreCase))
                {
                    logLevel = value;
                }
                else
                {
                    throw new ArgumentException($"Unknown key: {key}");
                }
            }
        }
        return new PythonInfo(logPath, logLevel);
    }

    public RemoteTransport CreateTransport()
    {
        string assemblyPath = typeof(PythonInfo).Assembly.Location ?? "";
        string baseDir = Path.Combine(assemblyPath, "..", "..", "..", "..", "..");
        Dictionary<string, string> envVars = new()
        {
            { "PYTHONPATH", Path.GetFullPath(baseDir) }
        };

        List<string> args = new()
        {
            "-m", "psrp_server"
        };
        if (!string.IsNullOrWhiteSpace(_logPath))
        {
            args.AddRange(new[] { "--log-file", _logPath });
            if (!string.IsNullOrWhiteSpace(_logLevel))
            {
                args.AddRange(new[] { "--log-level", _logLevel });
            }
        }

        return new ProcessTransport("python", args, envVars);
    }
}
