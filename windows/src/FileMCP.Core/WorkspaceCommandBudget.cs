namespace FileMCP.Core;

/// <summary>
/// One process-wide budget shared by all user-approved workspace roots.
/// Cwd collision checking is cooperative; it is not a shell sandbox.
/// </summary>
internal sealed class WorkspaceCommandBudget
{
    private readonly object _gate = new();
    private readonly int _capacity;
    private readonly Dictionary<CommandSession, string> _long = new();
    private readonly Dictionary<Guid, string> _sync = new();

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
        lhs.StartsWith(Path.TrimEndingDirectorySeparator(rhs) + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase) ||
        rhs.StartsWith(Path.TrimEndingDirectorySeparator(lhs) + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase);

    private void Check(string cwd)
    {
        var paths = ActivePaths();
        if (paths.Count >= _capacity) throw new FileMcpException(
            "Concurrent command limit reached (" + _capacity + ")");
        if (paths.Any(existing => Overlaps(existing, cwd))) throw new FileMcpException(
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

    public bool HasActivityUnderRoot(string root)
    {
        lock (_gate) return ActivePaths().Any(path =>
            string.Equals(path, root, StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase));
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
