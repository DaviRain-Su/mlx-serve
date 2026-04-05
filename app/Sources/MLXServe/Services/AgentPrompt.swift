import Foundation

enum AgentPrompt {

    static let skillManager = SkillManager()

    static let systemPrompt = "You are a helpful macOS assistant. Use tools for tasks. Answer directly when no tools needed. For web search use webSearch tool."

    /// OpenAI-format tool definitions — kept minimal to reduce prompt tokens for small models.
    static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "shell",
                "description": "Run a command",
                "parameters": [
                    "type": "object",
                    "properties": ["command": ["type": "string"]],
                    "required": ["command"]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "writeFile",
                "description": "Write a file",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"]
                    ],
                    "required": ["path", "content"]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "readFile",
                "description": "Read a file",
                "parameters": [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "editFile",
                "description": "Find and replace in file",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "find": ["type": "string"],
                        "replace": ["type": "string"]
                    ],
                    "required": ["path", "find", "replace"]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "searchFiles",
                "description": "Grep for pattern",
                "parameters": [
                    "type": "object",
                    "properties": ["pattern": ["type": "string"]],
                    "required": ["pattern"]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "browse",
                "description": "Browse a URL",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string"],
                        "url": ["type": "string"]
                    ],
                    "required": ["action"]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "webSearch",
                "description": "Search the web",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string"]],
                    "required": ["query"]
                ]
            ] as [String: Any]
        ],
    ]
}

// MARK: - Prompt-based Skills

struct Skill {
    let name: String
    let description: String
    let triggers: [String]
    let body: String
}

class SkillManager {
    private let skillsDir: String
    private var skills: [Skill] = []
    private var lastModDate: Date?

    init() {
        skillsDir = NSString(string: "~/.mlx-serve/skills").expandingTildeInPath
        reload()
    }

    /// Returns skill index (always) + matching skill bodies (when triggered).
    func matchingSkills(for userMessage: String) -> String {
        reloadIfNeeded()
        guard !skills.isEmpty else { return "" }

        let lower = userMessage.lowercased()
        var result = "\nAvailable skills: " + skills.map { "\($0.name) (\($0.description))" }.joined(separator: ", ")

        let matched = skills.filter { skill in
            skill.triggers.contains { lower.contains($0) }
        }
        for skill in matched {
            result += "\n\n## Skill: \(skill.name)\n\(skill.body)"
        }

        return result
    }

    // MARK: - Private

    private func reloadIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: skillsDir),
              let modDate = attrs[.modificationDate] as? Date else {
            if !skills.isEmpty { skills = [] }
            return
        }
        if lastModDate != modDate { reload() }
    }

    private func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: skillsDir) else {
            skills = []
            lastModDate = nil
            return
        }
        lastModDate = (try? fm.attributesOfItem(atPath: skillsDir))?[.modificationDate] as? Date
        skills = files.filter { $0.hasSuffix(".md") }.compactMap { file in
            let path = (skillsDir as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return parseSkill(content)
        }
    }

    private func parseSkill(_ content: String) -> Skill? {
        guard content.hasPrefix("---") else { return nil }
        let afterOpener = content.index(content.startIndex, offsetBy: 3)
        guard let closeRange = content.range(of: "\n---", range: afterOpener..<content.endIndex) else { return nil }

        let frontmatter = String(content[afterOpener..<closeRange.lowerBound])
        let body = String(content[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        var name = ""
        var description = ""
        var triggers: [String] = []

        for line in frontmatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[trimmed.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "name": name = value
            case "description": description = value
            case "trigger":
                triggers = value.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            default: break
            }
        }

        guard !name.isEmpty, !triggers.isEmpty else { return nil }
        return Skill(name: name, description: description, triggers: triggers, body: body)
    }
}
