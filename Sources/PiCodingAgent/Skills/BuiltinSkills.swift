import Foundation

// MARK: - Builtin Skills

/// Default skills that ship with SwiftPi and are auto-deployed to ~/.swiftpi/skills/
public enum BuiltinSkills {

    /// All builtin skills as (filename, content) tuples
    public static let all: [(filename: String, content: String)] = [
        ("applescript-automation.md", appleScriptContent),
        ("swift-playground.md", swiftPlaygroundContent),
        ("ui-builder.md", uiBuilderContent),
    ]

    /// Set of builtin skill names (filename without extension) for tagging
    public static let builtinNames: Set<String> = Set(all.map {
        ($0.filename as NSString).deletingPathExtension
    })

    /// Deploy builtin skills to the given directory if they don't already exist.
    /// Creates the directory if needed.
    public static func deployIfNeeded(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for (filename, content) in all {
            let path = (dir as NSString).appendingPathComponent(filename)
            if !fm.fileExists(atPath: path) {
                try? content.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - applescript-automation.md

    private static let appleScriptContent = """
---
name: applescript-automation
description: Guide for using the AppleScript tool for macOS automation
---

# AppleScript Automation

The `applescript` tool executes AppleScript or JavaScript for Automation (JXA) via `osascript` for macOS system automation.

## Basic Usage

```json
{ "script": "display dialog \\"Hello from SwiftPi\\"" }
```

### JavaScript for Automation (JXA)

```json
{ "script": "Application('Finder').desktop.entireContents().map(f => f.name())", "language": "javascript" }
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `script` | string (required) | AppleScript or JXA code to execute |
| `language` | string | `"applescript"` (default) or `"javascript"` for JXA |
| `timeout` | number | Timeout in seconds (default: 30) |

## Common Patterns

### App Control

```applescript
-- Open/activate an app
tell application "Safari" to activate

-- Quit an app
tell application "Music" to quit

-- Get frontmost app
tell application "System Events" to get name of first process whose frontmost is true
```

### Finder Operations

```applescript
-- Get selected files
tell application "Finder" to get selection as alias list

-- Open a folder
tell application "Finder" to open folder "Documents" of home

-- Get file info
tell application "System Events" to get size of file "/path/to/file"
```

### Dialogs & Notifications

```applescript
-- Simple dialog
display dialog "Message" with title "Title" buttons {"OK", "Cancel"} default button "OK"

-- Notification
display notification "Task complete" with title "SwiftPi" sound name "Glass"

-- Choose from list
choose from list {"Option A", "Option B", "Option C"} with title "Pick one"

-- File picker
choose file with prompt "Select a file"
```

### Safari / Browser

```applescript
-- Get current URL
tell application "Safari" to get URL of current tab of front window

-- Open URL
tell application "Safari" to open location "https://example.com"

-- Get page source
tell application "Safari" to get source of current tab of front window
```

### Terminal

```applescript
-- Run a command in Terminal
tell application "Terminal"
    activate
    do script "ls -la ~/Documents"
end tell
```

### System

```applescript
-- Get clipboard
the clipboard

-- Set clipboard
set the clipboard to "Hello"

-- Volume control
set volume output volume 50

-- Dark mode check
tell application "System Events" to get dark mode of appearance preferences
```

### JXA Examples

```javascript
// List running apps
Application("System Events").processes.whose({backgroundOnly: false}).name()

// Read a file
const app = Application.currentApplication()
app.includeStandardAdditions = true
app.read(Path("/path/to/file.txt"))

// HTTP request (via curl)
app.doShellScript("curl -s https://api.example.com/data")
```

## Tips

- Use AppleScript for app automation, dialogs, and Finder operations
- Use JXA when you need JavaScript syntax or complex data manipulation
- Set a longer timeout for operations that wait for user input (dialogs, file pickers)
- Scripts run with the user's permissions -- they can access anything the user can
- Use `do shell script` within AppleScript to run shell commands when needed
- For long-running automations, consider breaking them into smaller steps
"""

    // MARK: - swift-playground.md

    private static let swiftPlaygroundContent = """
---
name: swift-playground
description: Guide for using the Swift Playground tool with UI preview mode
---

# Swift Playground — UI Preview Mode

The `swift` tool executes Swift code like an Xcode Playground. Set `ui: true` to open an AppKit/SwiftUI preview window.

## Basic Usage

```json
{ "code": "print(\\"Hello\\")", "ui": false }
```

## UI Preview Mode (`ui: true`)

When `ui: true` the code is wrapped in an AppKit host that opens a window. Define one of:

### AppKit (preferred)

```swift
import AppKit

let previewContent: NSView = {
    let label = NSTextField(labelWithString: "Hello from AppKit")
    label.font = .systemFont(ofSize: 24)
    label.alignment = .center
    return label
}()
```

### SwiftUI

```swift
import SwiftUI

let previewView = VStack {
    Text("Hello from SwiftUI")
        .font(.title)
    Button("Click me") { print("clicked") }
}
```

## Key Rules

1. **Always define either `previewContent` (NSView) or `previewView` (SwiftUI View)**
2. AppKit `NSView` is checked first, then SwiftUI `View`
3. The preview window auto-closes after 30 seconds
4. Use `print()` to send output -- it appears in the tool result
5. The code runs as a standalone Swift script -- import any frameworks you need
6. Available frameworks: AppKit, SwiftUI, Foundation, CoreGraphics, etc.

## Examples

### Custom AppKit View

```swift
import AppKit

let previewContent: NSView = {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .centerX

    let title = NSTextField(labelWithString: "Dashboard")
    title.font = .boldSystemFont(ofSize: 20)
    stack.addArrangedSubview(title)

    for i in 1...3 {
        let item = NSTextField(labelWithString: "Item \\(i)")
        item.font = .systemFont(ofSize: 14)
        stack.addArrangedSubview(item)
    }

    return stack
}()
```

### SwiftUI View

```swift
import SwiftUI

let previewView = VStack(spacing: 16) {
    Image(systemName: "star.fill")
        .font(.largeTitle)
        .foregroundColor(.yellow)
    Text("Rating: 4.5")
        .font(.headline)
    ProgressView(value: 0.9)
        .frame(width: 200)
}
.padding()
```
"""

    // MARK: - ui-builder.md

    private static let uiBuilderContent = """
---
name: ui-builder
description: Full DSL reference for the UI Builder tool's JSON view tree
---

# UI Builder -- DSL Reference

The `ui` tool renders a live interactive UI inside the SwiftPi app from a JSON view tree.
The UI opens in its own window and is fully self-contained -- buttons, toggles, and text fields
all work internally through a built-in state system.

## Structure

Every node has:
- `type` (required): the component type
- `props` (optional): dictionary of properties
- `children` (optional): array of child nodes

```json
{
    "type": "vstack",
    "props": { "spacing": 12 },
    "children": [
        { "type": "text", "props": { "content": "Hello" } }
    ]
}
```

## State System

The UI has an internal key-value state store. Buttons trigger actions that mutate state,
and text nodes can bind to state variables to display live values.

### Binding text to state

Use the `bind` prop instead of `content` to show a state variable's live value:

```json
{ "type": "text", "props": { "bind": "display", "font": "title" } }
```

### Action commands

Button `action` strings are commands that mutate state. Multiple commands can be
separated by `;` (semicolon).

| Command | Example | Description |
|---------|---------|-------------|
| `set:var:value` | `set:display:0` | Set variable to value |
| `append:var:value` | `append:display:7` | Append value to variable |
| `clear:var` | `clear:display` | Clear variable to empty string |
| `eval:var` | `eval:display` | Evaluate math expression in variable |
| `increment:var` | `increment:count` | Add 1 to numeric variable |
| `decrement:var` | `decrement:count` | Subtract 1 from numeric variable |
| `toggle:var` | `toggle:dark` | Toggle between "true" and "false" |

The `eval` command supports: `+`, `-`, `*`, `/`, `()`, decimal numbers.

## Universal Modifiers

These props can be added to ANY node to style it:

| Prop | Type | Description |
|------|------|-------------|
| `background` | color name or hex | Background color |
| `cornerRadius` | number | Rounded corners (clips content) |
| `padding` | number | Inner padding on all sides |
| `width` | number | Fixed width |
| `height` | number | Fixed height |
| `minHeight` | number | Minimum height |
| `maxWidth` | number | Maximum width |
| `expand` | boolean | Fill available width (`maxWidth: infinity`) |
| `opacity` | 0.0-1.0 | Transparency |
| `shadowRadius` | number | Drop shadow radius |
| `borderColor` | color name or hex | Border stroke color |
| `borderWidth` | number | Border stroke width (default: 1) |

Example -- styled container:
```json
{ "type": "vstack", "props": { "background": "#F5F5F7", "cornerRadius": 12, "padding": 16, "shadowRadius": 2 }, "children": [...] }
```

## Component Types

### Layout

#### `vstack`
Vertical stack layout.
- `alignment`: "leading" | "trailing" | "center" (default: "center")
- `spacing`: number (default: 8)

#### `hstack`
Horizontal stack layout.
- `alignment`: "top" | "bottom" | "center" (default: "center")
- `spacing`: number (default: 8)

#### `zstack`
Overlay stack (children layered on top of each other). No extra props.

#### `grid`
Grid layout with automatic column arrangement.
- `columns`: number of columns (default: 4)
- `spacing`: gap between items (default: 6)

#### `scroll`
Scrollable container.
- `axis`: "horizontal" | "vertical" (default: "vertical")

#### `list`
Styled list with dividers between items. No extra props -- children are rendered as rows.

#### `section`
Grouped section with optional header text.
- `header`: section title text (displayed in uppercase, small font)

#### `padding`
Adds padding around children.
- `value`: number (default: 12)
- `edges`: "all" | "horizontal" | "vertical" | "top" | "bottom" | "leading" | "trailing" (default: "all")

#### `spacer`
Flexible space.
- `minLength`: minimum size in points (optional)

#### `divider`
Horizontal line separator. No props.

### Content

#### `text`
Display text.
- `content`: static text string
- `bind`: state variable name to display (live-updating, takes priority over content)
- `font`: "largeTitle" | "title" | "title2" | "title3" | "headline" | "subheadline" | "body" | "caption" | "caption2" | "footnote" | "mono" | "rounded"
- `fontSize`: custom font size in points (number)
- `design`: "monospaced" | "rounded" (optional, for custom styling)
- `color`: color name or hex
- `bold`: boolean
- `alignment`: "leading" | "trailing" | "center" (text alignment)
- `wrap`: boolean -- allow multiline (default: single line)

#### `image`
SF Symbol icon.
- `systemName` (required): SF Symbol name (e.g. "star.fill", "gear")
- `font`: same as text font options
- `fontSize`: custom size in points
- `color`: color name or hex
- `size`: explicit width/height in points

#### `label`
SF Symbol + text combination (like SwiftUI Label).
- `content` or `label`: the text
- `systemName`: SF Symbol name
- `font`: font preset
- `fontSize`: custom size
- `color`: color name or hex

#### `rectangle`
Colored rectangle shape.
- `color`: color name or hex (default: accent color)
- `width`: number (optional, fills available width if omitted)
- `height`: number (optional)
- `cornerRadius`: number (default: 0)

### Interactive

#### `button`
Tappable button -- executes action commands that modify internal state.
- `label`: button text (default: "Button")
- `action`: action command string (see Action commands above)
- `style`: "bordered" | "borderedProminent" | "plain" | "custom" (default: "bordered")
- `font`: font preset for label text
- `fontSize`: custom font size in points
- `color`: tint/foreground color (name or hex)
- `background`: background color (for "custom" style)
- `cornerRadius`: corner radius (for "custom" style, default: 8)
- `expand`: boolean -- fill available width (for grid layouts)
- `minHeight`: minimum button height in points
- `systemName`: SF Symbol icon alongside label text

#### `textfield`
Text input field.
- `placeholder`: placeholder text
- `id`: field identifier for state tracking

#### `toggle`
On/off switch.
- `label`: toggle label text (default: "Toggle")
- `id`: toggle identifier for state tracking

#### `progress`
Progress indicator.
- `value`: 0.0-1.0 for determinate progress; omit for indeterminate spinner

## Colors

### Named colors
red, blue, green, orange, purple, yellow, pink, white, gray, grey, secondary, primary, accent, teal, mint, indigo, cyan, brown, clear

### System colors
controlBackground, windowBackground, textBackground, separator

### Hex colors
Use `#RRGGBB` or `#RRGGBBAA` format: `"#FF6B35"`, `"#2196F380"`

## Design Guidelines

- NEVER use black or dark backgrounds -- always follow macOS system appearance
- Use system colors like `controlBackground` for subtle container backgrounds
- Use hex colors for precise brand-style tinting
- Use `padding` on containers for breathing room (12-20 is typical)
- Use `expand: true` on buttons in a row so they size equally
- Use `cornerRadius` 8-12 on containers for a polished macOS look
- Use `grid` with `columns: 4` for calculator-style button layouts
- Use `"style": "custom"` buttons with `background` and `cornerRadius` for styled keypads
- Use `minHeight` on buttons for comfortable tap targets (28-36 points)
- Use `shadowRadius` 1-3 for subtle depth on cards
- Prefer `borderedProminent` for primary actions, `bordered` for secondary
- Use `section` to group related controls with a header

## Examples

### Calculator

```json
{
    "type": "vstack",
    "props": { "spacing": 10, "padding": 16, "expand": true },
    "children": [
        { "type": "text", "props": { "bind": "display", "fontSize": 36, "bold": true, "alignment": "trailing", "padding": 16, "expand": true, "background": "controlBackground", "cornerRadius": 10, "minHeight": 60 } },
        { "type": "grid", "props": { "columns": 4, "spacing": 6 }, "children": [
            { "type": "button", "props": { "label": "AC", "action": "clear:display", "style": "custom", "color": "red", "background": "#FF3B3020", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "(", "action": "append:display:(", "style": "bordered", "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": ")", "action": "append:display:)", "style": "bordered", "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "\\u00f7", "action": "append:display:/", "style": "borderedProminent", "color": "orange", "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "7", "action": "append:display:7", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "8", "action": "append:display:8", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "9", "action": "append:display:9", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "\\u00d7", "action": "append:display:*", "style": "borderedProminent", "color": "orange", "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "4", "action": "append:display:4", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "5", "action": "append:display:5", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "6", "action": "append:display:6", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "\\u2212", "action": "append:display:-", "style": "borderedProminent", "color": "orange", "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "1", "action": "append:display:1", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "2", "action": "append:display:2", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "3", "action": "append:display:3", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "+", "action": "append:display:+", "style": "borderedProminent", "color": "orange", "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": "0", "action": "append:display:0", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "button", "props": { "label": ".", "action": "append:display:.", "style": "custom", "background": "controlBackground", "cornerRadius": 10, "expand": true, "minHeight": 44 } },
            { "type": "spacer" },
            { "type": "button", "props": { "label": "=", "action": "eval:display", "style": "borderedProminent", "color": "accent", "expand": true, "minHeight": 44 } }
        ]}
    ]
}
```

### Counter

```json
{
    "type": "vstack",
    "props": { "spacing": 20, "padding": 28 },
    "children": [
        { "type": "text", "props": { "content": "Counter", "font": "title2", "bold": true } },
        { "type": "text", "props": { "bind": "count", "fontSize": 48, "bold": true, "color": "accent", "design": "rounded" } },
        { "type": "hstack", "props": { "spacing": 12 }, "children": [
            { "type": "button", "props": { "label": "\\u2212", "action": "decrement:count", "style": "borderedProminent", "expand": true, "fontSize": 20, "minHeight": 36 } },
            { "type": "button", "props": { "label": "Reset", "action": "set:count:0", "style": "bordered", "expand": true, "minHeight": 36 } },
            { "type": "button", "props": { "label": "+", "action": "increment:count", "style": "borderedProminent", "expand": true, "fontSize": 20, "minHeight": 36 } }
        ]}
    ]
}
```

### Simple form

```json
{
    "type": "vstack",
    "props": { "spacing": 14, "alignment": "leading", "padding": 20 },
    "children": [
        { "type": "label", "props": { "content": "New Task", "systemName": "plus.circle.fill", "font": "title2", "color": "accent" } },
        { "type": "textfield", "props": { "placeholder": "Task name", "id": "name" } },
        { "type": "textfield", "props": { "placeholder": "Description", "id": "desc" } },
        { "type": "hstack", "props": { "spacing": 12 }, "children": [
            { "type": "button", "props": { "label": "Cancel", "action": "clear:name;clear:desc", "style": "bordered", "expand": true, "minHeight": 32 } },
            { "type": "button", "props": { "label": "Save", "action": "set:status:Saved!", "style": "borderedProminent", "expand": true, "systemName": "checkmark", "minHeight": 32 } }
        ]},
        { "type": "text", "props": { "bind": "status", "color": "green", "font": "headline" } }
    ]
}
```

### Task Runner

```json
{
    "type": "vstack",
    "props": { "spacing": 12, "padding": 20, "alignment": "leading", "expand": true },
    "children": [
        { "type": "label", "props": { "content": "Task Runner", "systemName": "terminal.fill", "font": "title2", "bold": true } },
        { "type": "divider" },
        { "type": "section", "props": { "header": "Quick Actions" }, "children": [
            { "type": "hstack", "props": { "spacing": 8 }, "children": [
                { "type": "button", "props": { "label": "Build", "systemName": "hammer.fill", "action": "set:status:Building...", "style": "borderedProminent", "expand": true, "minHeight": 32 } },
                { "type": "button", "props": { "label": "Test", "systemName": "checkmark.diamond", "action": "set:status:Testing...", "style": "borderedProminent", "color": "green", "expand": true, "minHeight": 32 } },
                { "type": "button", "props": { "label": "Clean", "systemName": "trash", "action": "set:status:Cleaning...", "style": "bordered", "color": "red", "expand": true, "minHeight": 32 } }
            ]}
        ]},
        { "type": "section", "props": { "header": "Status" }, "children": [
            { "type": "text", "props": { "bind": "status", "font": "mono", "color": "secondary" } }
        ]}
    ]
}
```
"""
}
