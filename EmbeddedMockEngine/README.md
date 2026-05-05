# EmbeddedMockEngine

A lightweight, embedded HTTP/1.x mock server for iOS and macOS apps — distributed as a Swift Package and xcframework-ready. Can also run as a **standalone app** on iOS or macOS, allowing other apps on the same device to reach it via `localhost`.

## Features

- **Zero third-party dependencies** — built entirely on Foundation and POSIX sockets.
- **Cross-platform** — runs on iOS 14+, macOS 11+, and Linux (CI/CD pipelines).
- **Standalone app** — includes a ready-to-build SwiftUI app that runs the mock server as a first-class iOS/macOS application, reachable by other apps on the same device via `http://localhost:<port>`.
- **JSON config file** — define all routes in a single `MockConfig.json` that ships with your test target or bundle.
- **Flexible request matching** — match on HTTP method, URL pattern (exact, glob wildcard `*`/`**`, path parameters `{id}`, explicit regex), query parameters, headers, and body regex.
- **File or inline responses** — serve `.json`, `.xml`, `.txt`, `.html`, and more from files, or specify the response body inline.
- **Priority routing** — higher-priority routes are evaluated first when multiple routes could match.
- **Configurable delays** — simulate network latency per-route or globally.
- **Configurable bind address** — listen on loopback only (`127.0.0.1`) or all interfaces (`0.0.0.0`).
- **Swift concurrency** — fully async/await API, backed by a dedicated OS thread so the cooperative thread pool is never blocked.
- **Request observer** — attach a callback to receive real-time notifications for every request (method, URL, matched route, status code).

## Quick Start

```swift
import EmbeddedMockEngine

let engine = MockEngine()

// Load from a JSON config file included in your bundle
try await engine.loadConfiguration(bundleResource: "MockConfig", bundle: .module)

// Start – port 0 lets the OS pick a free port
let port = try await engine.start()
print("Mock server running on http://localhost:\(port)")

// Point URLSession at the mock server
let url = URL(string: "http://localhost:\(port)/api/users")!
let (data, _) = try await URLSession.shared.data(from: url)

// … assertions …

await engine.stop()
```

## Programmatic Configuration

```swift
let engine = MockEngine()

engine.addRoute(MockRoute(
    id: "list-users",
    request: MockRequestMatcher(method: .get, urlPattern: "/api/users"),
    response: MockResponseDefinition(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: #"{"users":[]}"#
    )
))

let port = try await engine.start(port: 9090)
```

## Config File Format

```json
{
  "settings": {
    "port": 0,
    "logRequests": true,
    "globalDelay": 0.0,
    "bindAddress": "127.0.0.1"
  },
  "routes": [
    {
      "id": "list-users",
      "priority": 0,
      "request": {
        "method": "GET",
        "urlPattern": "/api/users",
        "queryParameters": { "page": "1" },
        "headers": { "accept": "application/json" }
      },
      "response": {
        "statusCode": 200,
        "headers": { "Content-Type": "application/json" },
        "bodyFile": "Responses/users.json",
        "delay": 0.0
      }
    },
    {
      "id": "get-user",
      "priority": 10,
      "request": {
        "method": "GET",
        "urlPattern": "/api/users/{id}"
      },
      "response": {
        "statusCode": 200,
        "body": "{\"id\":1,\"name\":\"Alice\"}"
      }
    }
  ]
}
```

### URL Pattern Syntax

| Pattern | Description |
|---------|-------------|
| `/api/users` | Exact match |
| `/api/users/*` | One path segment wildcard |
| `/api/**` | Zero-or-more path segments |
| `/api/users/{id}` | Named path parameter (equivalent to `*`) |
| `~/api/users/[0-9]+~` | Explicit regex (delimited by `~`) |

## Architecture

```
Sources/EmbeddedMockEngine/           ← Library (no UIKit/SwiftUI — pure Foundation)
├── MockEngine.swift                  ← Public actor: configure / start / stop
├── Configuration/
│   └── MockConfiguration.swift       ← Codable config models
├── Core/
│   ├── MockServer.swift              ← POSIX-socket TCP server
│   ├── HTTPParser.swift              ← Raw bytes → HTTPRequest
│   ├── HTTPRequest.swift
│   ├── HTTPResponse.swift
│   └── HTTPResponseSerializer.swift  ← HTTPResponse → raw bytes
├── Matching/
│   └── RequestMatcher.swift          ← Route matching logic
└── Providers/
    └── ResponseProvider.swift        ← File / inline body resolution

MockEngineApp/                        ← Standalone iOS/macOS app (separate target)
├── Sources/
│   ├── MockEngineAppApp.swift        ← SwiftUI App entry point
│   ├── ContentView.swift             ← Server status, controls, request log
│   ├── ServerManager.swift           ← ObservableObject wrapping MockEngine
│   └── ConfigurationPickerView.swift ← JSON config file importer
├── Resources/
│   └── DefaultMockConfig.json        ← Bundled default configuration
├── Assets.xcassets/                  ← App icon
├── Info.plist                        ← URL scheme, ATS, background modes
└── project.yml                       ← XcodeGen spec (generates .xcodeproj)
```

## Standalone App

The `MockEngineApp` directory contains a SwiftUI app that runs the mock server as a standalone application on **iOS** or **macOS**. Other apps on the same device/machine can make HTTP requests to `http://localhost:<port>`.

### Building the App

```bash
# Install XcodeGen (one-time)
brew install xcodegen

# Generate the Xcode project
cd MockEngineApp
xcodegen generate

# Open in Xcode
open MockEngineApp.xcodeproj
```

Select the **MockEngineApp-iOS** or **MockEngineApp-macOS** scheme in Xcode, then build and run.

### How It Works

1. The app starts `MockEngine` on a configurable port (default: 8080, or 0 for auto-assign).
2. Other apps on the same device reach it at `http://localhost:<port>/…`.
3. The UI shows server status, loaded routes, and a live request log.
4. Import custom JSON configuration files via the built-in file picker.

### iOS Background Mode

On iOS, the app uses the `audio` background mode with a silent audio session to prevent the system from suspending the process when backgrounded. A `UIBackgroundTask` provides additional grace time as a fallback.

On macOS, no special background handling is needed — the server runs as long as the app is open.

### URL Scheme (Inter-App Communication)

Other apps can control the mock server by opening URLs with the `mockengine` scheme:

| URL | Action |
|-----|--------|
| `mockengine://start` | Start the server |
| `mockengine://start?port=9090` | Start on a specific port |
| `mockengine://stop` | Stop the server |
| `mockengine://status` | Bring the app to the foreground |

Example from another app:

```swift
if let url = URL(string: "mockengine://start?port=8080") {
    UIApplication.shared.open(url)   // iOS
    // NSWorkspace.shared.open(url)  // macOS
}

// Then make requests to http://localhost:8080/api/…
```

### Code Separation

The project enforces clean separation between the three build artifacts:

| Artifact | Location | Dependencies |
|----------|----------|-------------|
| **Library** | `Sources/EmbeddedMockEngine/` | Foundation + POSIX only |
| **XCFramework** | Built by `build_xcframework.sh` | Library sources only |
| **App** | `MockEngineApp/` | Imports library as a local SPM package |

The library contains **no** UIKit, SwiftUI, or AVFoundation imports. All platform-specific UI and background-mode code lives exclusively in the app target.

## Building the XCFramework

```bash
./build_xcframework.sh
```

## Running Tests

```bash
swift test
```


