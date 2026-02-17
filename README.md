# SwiftPi

A native macOS AI agent toolkit written in Swift. Built to understand how AI coding agents work by reimplementing one from the ground up.

Zero external dependencies. Just Foundation and SwiftUI.

![SwiftPi](screenshot.png)

## Modules

```
┌─────────────────────────────────────────────┐
│             TestSwiftPi (App)               │
│          SwiftUI macOS Demo App             │
├─────────────────────────────────────────────┤
│           TestSwiftPiLib (UI)               │
│   ChatView · ConfigPanel · SkillBrowser     │
├─────────────────────────────────────────────┤
│          PiCodingAgent (Tools)              │
│ Bash · Read · Write · Edit · Grep · Find    │
│ Sessions · Skills · Extensions · Compaction │
├─────────────────────────────────────────────┤
│            PiAgent (Runtime)                │
│    Agent Loop · Tool Execution · Events     │
├─────────────────────────────────────────────┤
│              PiAI (LLM API)                 │
│  Providers · Streaming · SSE · API Keys     │
└─────────────────────────────────────────────┘
```

| Module | What it does |
|---|---|
| **PiAI** | Multi-provider LLM API with streaming |
| **PiAgent** | Agent loop, tool calling, event system |
| **PiCodingAgent** | 7 coding tools, sessions, skills, extensions, compaction |
| **TestSwiftPiLib** | SwiftUI views for the demo app |
| **TestSwiftPi** | macOS demo app |

## Features

- **Multi-provider LLM support** — pluggable provider registry, bring any API
- **Streaming responses** — SSE parsing, `AsyncSequence` event streams
- **Extended thinking** — reasoning mode with configurable token budgets
- **7 built-in tools** — Bash, Read, Write, Edit, Grep, Find, Ls
- **Safety checks** — blocks dangerous commands, warns on risky operations
- **Sessions** — JSONL append-only conversation storage
- **Skills** — single-file (.md) or directory-style (SKILL.md + resources), auto-loaded
- **Extensions** — plug in custom tools
- **Compaction** — auto-summarizes long conversations to stay in context
- **Settings** — global + project-local config with deep merge

## Requirements

- macOS 14+
- Swift 5.9+
- Xcode 15+ (for building)

## Build & Run

```bash
swift build
swift test
swift run TestSwiftPi
```

Or open `Package.swift` in Xcode and hit Run.

## API Keys

Set via environment variables or the app's config panel:

```bash
export OPENAI_API_KEY="your-key"
# or any provider key — see the app's config panel
```

Keys are stored locally at `~/.swiftpi/api-keys.json` and never leave your machine.

## Skills

SwiftPi supports the Agent Skills standard. Skills are loaded from:

- `~/.swiftpi/skills/` (user-level)
- `.swiftpi/skills/` (project-level)

Two formats:

**Single file** — `skill-name.md` with YAML frontmatter:
```markdown
---
name: skill-name
description: What this skill does and when to use it
---
# Instructions here
```

**Directory** — `skill-name/SKILL.md` + bundled resources:
```
skill-name/
├── SKILL.md
├── reference.md
└── scripts/
    └── helper.py
```

Three skills ship by default:

- **Swift Playground** — execute Swift code with optional AppKit/SwiftUI preview windows
- **UI Builder** — render live interactive UIs from JSON view trees
- **AppleScript Automation** — AppleScript and JXA for macOS system control

## Project Layout

```
SwiftPi/
├── Package.swift
├── Sources/
│   ├── PiAI/                    # LLM abstraction layer
│   ├── PiAgent/                 # Agent runtime
│   ├── PiCodingAgent/           # Coding agent + tools
│   │   ├── Tools/               # Bash, Read, Write, Edit, etc.
│   │   ├── Session/             # Conversation persistence
│   │   ├── Settings/            # Config management
│   │   ├── Skills/              # Skill loader
│   │   ├── Prompts/             # System prompts & templates
│   │   ├── Extensions/          # Plugin system
│   │   └── Compaction/          # Context summarization
│   └── TestSwiftPiLib/          # Demo app UI
├── TestSwiftPi/                 # App entry point
└── Tests/                       # Unit tests
```

## Use as a Library

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/vcup-date/SwiftPi.git", branch: "main")
]
```

```swift
import PiAI
import PiAgent
import PiCodingAgent
```

## Credit

Inspired by [pi-mono](https://github.com/badlogic/pi-mono) by [Mario Zechner](https://github.com/badlogic).

## License

[MIT](LICENSE)
