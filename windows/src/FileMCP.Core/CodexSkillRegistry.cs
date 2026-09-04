using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace FileMCP.Core;

internal sealed class CodexSkillRegistry
{
    private const int MaxSkillBytes = 256 * 1024;
    private static readonly Regex ValidSkillName = new("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private readonly SafePathResolver _resolver;
    private readonly Action<string> _log;
    private readonly object _gate = new();
    private IReadOnlyList<CodexSkillInfo> _skills = [];

    public CodexSkillRegistry(string allowedDirectory, Action<string> log)
    {
        _resolver = new SafePathResolver(allowedDirectory);
        _log = log;
    }

    public JsonArray ToolDefinitions => new()
    {
        Tool(
            "list_codex_skills",
            "List Codex project skills discovered under .agents/skills in the current shared workspace. If the user's message starts with '/<skill-name>', use this list when needed to resolve the requested skill before answering.",
            new JsonObject(),
            []),
        Tool(
            "load_codex_skill",
            "Load a Codex Agent Skill from .agents/skills/<name>/SKILL.md in the current shared workspace. IMPORTANT: when the user's message starts with '/<skill-name>', call this tool with <skill-name> before answering, then follow the returned SKILL.md instructions for the current task. The name is a skill identifier, not a path.",
            new JsonObject { ["name"] = new JsonObject { ["type"] = "string", ["description"] = "Exact skill directory name under .agents/skills, for example speckit-analyze." } },
            ["name"]),
    };

    public bool HasTool(string name) => name is "list_codex_skills" or "load_codex_skill";

    public int Refresh()
    {
        _log("[Skills] Scanning .agents/skills...\n");
        var found = new List<CodexSkillInfo>();
        string root;
        try { root = _resolver.Resolve(Path.Combine(".agents", "skills")); }
        catch (Exception ex)
        {
            _log($"[Skills] Scan failed: {ex.Message}\n");
            lock (_gate) _skills = [];
            return 0;
        }

        if (!Directory.Exists(root))
        {
            lock (_gate) _skills = [];
            _log("[Skills] No Codex skills found in .agents/skills.\n");
            return 0;
        }

        foreach (var directory in new DirectoryInfo(root).EnumerateDirectories().OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase))
        {
            if (!ValidSkillName.IsMatch(directory.Name))
            {
                _log($"[Skills] Ignoring invalid skill directory name: {directory.Name}\n");
                continue;
            }
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0 || !_resolver.Contains(directory.FullName))
            {
                _log($"[Skills] Refused unsafe skill directory: {directory.Name}\n");
                continue;
            }

            var skillRelativePath = Path.Combine(".agents", "skills", directory.Name, "SKILL.md").Replace('\\', '/');
            string skillPath;
            try { skillPath = _resolver.Resolve(skillRelativePath); }
            catch (Exception ex)
            {
                _log($"[Skills] Refused unsafe skill path for {directory.Name}: {ex.Message}\n");
                continue;
            }
            var info = new FileInfo(skillPath);
            if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) continue;
            if (info.Length > MaxSkillBytes)
            {
                _log($"[Skills] Ignoring oversized SKILL.md: {directory.Name} ({info.Length} bytes)\n");
                continue;
            }

            string text;
            try { text = ReadUtf8Strict(skillPath); }
            catch (Exception ex)
            {
                _log($"[Skills] Invalid SKILL.md for {directory.Name}: {ex.Message}\n");
                continue;
            }
            var metadata = ParseFrontmatter(text);
            if (metadata.Name is not null && !string.Equals(metadata.Name, directory.Name, StringComparison.Ordinal))
            {
                _log($"[Skills] Ignoring {directory.Name}: frontmatter name '{metadata.Name}' does not match directory name.\n");
                continue;
            }
            found.Add(new CodexSkillInfo(directory.Name, metadata.Description ?? "", skillRelativePath));
            _log($"[Skills] Found: {directory.Name}\n");
        }

        lock (_gate) _skills = found;
        _log($"[Skills] Loaded {found.Count} Codex skill{(found.Count == 1 ? "" : "s")}.\n");
        return found.Count;
    }

    public ToolCallOutput Call(string name, JsonObject arguments)
    {
        return name switch
        {
            "list_codex_skills" => ObjectOutput(ListSkills()),
            "load_codex_skill" => ObjectOutput(LoadSkill(GetRequiredName(arguments))),
            _ => throw new FileMcpException($"Unknown skill tool: {name}"),
        };
    }

    private JsonObject ListSkills()
    {
        IReadOnlyList<CodexSkillInfo> snapshot;
        lock (_gate) snapshot = _skills;
        var items = new JsonArray(snapshot.Select(skill => (JsonNode?)new JsonObject
        {
            ["name"] = skill.Name,
            ["description"] = skill.Description,
            ["skill_file"] = skill.SkillFile,
        }).ToArray());
        return new JsonObject { ["skills"] = items, ["count"] = snapshot.Count };
    }

    private JsonObject LoadSkill(string skillName)
    {
        if (!ValidSkillName.IsMatch(skillName)) throw new FileMcpException("Invalid Codex skill name");
        IReadOnlyList<CodexSkillInfo> snapshot;
        lock (_gate) snapshot = _skills;
        var skill = snapshot.FirstOrDefault(item => string.Equals(item.Name, skillName, StringComparison.Ordinal));
        if (skill is null)
        {
            Refresh();
            lock (_gate) snapshot = _skills;
            skill = snapshot.FirstOrDefault(item => string.Equals(item.Name, skillName, StringComparison.Ordinal));
        }
        if (skill is null) throw new FileMcpException($"Codex skill not found: {skillName}");

        var path = _resolver.Resolve(skill.SkillFile);
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new FileMcpException($"Codex skill not found: {skillName}");
        if (info.Length > MaxSkillBytes) throw new FileMcpException("SKILL.md is larger than the 256 KB skill limit");
        var instructions = ReadUtf8Strict(path);
        _log($"[Skills] Loading skill: {skillName}\n");
        _log($"[Skills] Loaded: {skill.SkillFile}\n");
        return new JsonObject
        {
            ["name"] = skill.Name,
            ["description"] = skill.Description,
            ["skill_directory"] = Path.GetDirectoryName(skill.SkillFile)?.Replace('\\', '/') ?? $".agents/skills/{skill.Name}",
            ["skill_file"] = skill.SkillFile,
            ["instructions"] = instructions,
        };
    }

    private static string GetRequiredName(JsonObject args)
    {
        if (args.Count != 1 || args["name"] is not JsonValue value || !value.TryGetValue<string>(out var name))
            throw new FileMcpException("Missing or invalid argument: name");
        return name;
    }

    private static string ReadUtf8Strict(string path)
    {
        var data = File.ReadAllBytes(path);
        if (data.Length > MaxSkillBytes) throw new FileMcpException("SKILL.md is larger than the 256 KB skill limit");
        try { return new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException) { throw new FileMcpException("SKILL.md must be valid UTF-8"); }
    }

    private static (string? Name, string? Description) ParseFrontmatter(string text)
    {
        var normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        if (!normalized.StartsWith("---\n", StringComparison.Ordinal)) return (null, null);
        var end = normalized.IndexOf("\n---\n", 4, StringComparison.Ordinal);
        if (end < 0) return (null, null);
        string? name = null; string? description = null;
        foreach (var raw in normalized[4..end].Split('\n'))
        {
            var colon = raw.IndexOf(':'); if (colon <= 0) continue;
            var key = raw[..colon].Trim(); var value = raw[(colon + 1)..].Trim();
            if (value.Length >= 2 && ((value[0] == '"' && value[^1] == '"') || (value[0] == '\'' && value[^1] == '\''))) value = value[1..^1];
            if (key == "name") name = value;
            else if (key == "description") description = value;
        }
        return (name, description);
    }

    private static JsonObject Tool(string name, string description, JsonObject properties, string[] required) => new()
    {
        ["name"] = name,
        ["description"] = description,
        ["inputSchema"] = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = properties,
            ["required"] = new JsonArray(required.Select(item => (JsonNode?)JsonValue.Create(item)).ToArray()),
            ["additionalProperties"] = false,
        },
        ["outputSchema"] = new JsonObject { ["type"] = "object", ["additionalProperties"] = true },
        ["annotations"] = new JsonObject { ["readOnlyHint"] = true, ["destructiveHint"] = false, ["openWorldHint"] = false },
    };

    private static ToolCallOutput ObjectOutput(JsonObject value) => new(
        new JsonArray(new JsonObject { ["type"] = "text", ["text"] = value.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) }),
        value);

    private sealed record CodexSkillInfo(string Name, string Description, string SkillFile);
}
