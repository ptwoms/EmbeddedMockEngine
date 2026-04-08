# EmbeddedMockEngine

A lightweight, embedded HTTP/1.x mock server for iOS and macOS apps — distributed as a Swift Package and xcframework-ready.

## Features

- **Zero third-party dependencies** — built entirely on Foundation and POSIX sockets.
- **Cross-platform** — runs on iOS 14+, macOS 11+, and Linux (CI/CD pipelines).
- **JSON config file** — define all routes in a single `MockConfig.json` that ships with your test target or bundle.
- **Flexible request matching** — match on HTTP method, URL pattern (exact, glob wildcard `*`/`**`, path parameters `{id}`, explicit regex), query parameters, headers, and body regex.
- **File or inline responses** — serve `.json`, `.xml`, `.txt`, `.html`, and more from files, or specify the response body inline.
- **Priority routing** — higher-priority routes are evaluated first when multiple routes could match.
- **Configurable delays** — simulate network latency per-route or globally.
- **Swift concurrency** — fully async/await API, backed by a dedicated OS thread so the cooperative thread pool is never blocked.

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
    "globalDelay": 0.0
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
Sources/EmbeddedMockEngine/
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
```

## Running Tests

```bash
swift test
```

