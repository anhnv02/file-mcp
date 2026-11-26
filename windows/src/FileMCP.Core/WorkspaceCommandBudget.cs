namespace FileMCP.Core;

/// <summary>
/// Runtime command budget and scoped mutation reservations.
/// Cwd collision checking is cooperative; it is not a shell sandbox.
/// </summary>
internal sealed class WorkspaceCommandBudget
{
    private readonly object _gate = new();
    private readonly int _capacity;
    private readonly Dictionary<CommandSession, string> _long = new();
    private readonly Dictionary<Guid, string> _sync = new();
    private readonly Dictionary<Guid, string[]> _mutations = new();
    public int Capacity => _capacity;

    public WorkspaceCommandBudget(int capacity)
    {
        _capacity = Math.Clamp(capacity, 4, 16);
    }

    private List<string> ActivePaths()
    {
        foreach (var stale in _long.Where(entry => !entry.Key.Active).Select(entry => entry.Key).ToArray())
            _long.Remove(stale);
        return _long.Values.Concat(_sync.Values).ToList();
    }

    private static bool Overlaps(string lhs, string rhs) =>
        string.Equals(lhs, rhs, StringComparison.OrdinalIgnoreCase) ||
        lhs.StartsWith(WithSeparator(rhs),
            StringComparison.OrdinalIgnoreCase) ||
        rhs.StartsWith(WithSeparator(lhs),
            StringComparison.OrdinalIgnoreCase);

    private static string WithSeparator(string path) => Path.EndsInDirectorySeparator(path) ? path : path + Path.DirectorySeparatorChar;

    private void Check(string cwd)
    {
        var paths = ActivePaths();
        if (paths.Count >= _capacity) throw new FileMcpException(
            "Concurrent command limit reached (" + _capacity + ")");
        if (paths.Any(existing => Overlaps(existing, cwd)) ||
            _mutations.Values.SelectMany(paths => paths).Any(existing => Overlaps(existing, cwd))) throw new FileMcpException(
            "Another active command occupies this working directory or a parent/child directory; use an independent worktree");
    }

    public void Admit(CommandSession session, string cwd)
    {
        lock (_gate)
        {
            Check(cwd);
            _long.Add(session, cwd);
        }
    }

    public void Forget(CommandSession session)
    {
        lock (_gate) _long.Remove(session);
    }

    public Guid AcquireSynchronous(string cwd)
    {
        lock (_gate)
        {
            Check(cwd);
            var lease = Guid.NewGuid();
            _sync.Add(lease, cwd);
            return lease;
        }
    }

    public void Release(Guid id)
    {
        lock (_gate) _sync.Remove(id);
    }

    public Guid AcquireMutation(string[] paths)
    {
        lock (_gate)
        {
            var occupied = ActivePaths().Concat(_mutations.Values.SelectMany(value => value)).ToArray();
            if (paths.Any(path => occupied.Any(existing => Overlaps(path, existing))))
                throw new FileMcpException("An active command or mutation occupies the requested path");
            var id = Guid.NewGuid();
            _mutations.Add(id, paths);
            return id;
        }
    }

    public void ReleaseMutation(Guid id)
    {
        lock (_gate) _mutations.Remove(id);
    }

    public System.Text.Json.Nodes.JsonObject Status()
    {
        lock (_gate)
        {
            var paths=ActivePaths();
            return new System.Text.Json.Nodes.JsonObject
            {
                ["max_concurrent_commands"]=_capacity,
                ["active_long_running"]=_long.Count,
                ["active_synchronous"]=_sync.Count,
                ["active_total"]=paths.Count,
                ["available_slots"]=Math.Max(0,_capacity-paths.Count),
                ["accepting_new_commands"]=true,
            };
        }
    }
}
