# MockEngineApp

A standalone iOS/macOS app that runs [EmbeddedMockEngine](../README.md) as an HTTP server on your device or simulator. Other apps on the same device can make requests to `http://localhost:<port>`.

## Setup

```bash
# Install XcodeGen (one-time)
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open MockEngineApp.xcodeproj
```

Select either **MockEngineApp-iOS** or **MockEngineApp-macOS** scheme, then build and run.

## Features

- **Start/Stop** the mock server with a single tap
- **Configurable port** (default 8080, or 0 for auto-assign)
- **Live request log** showing method, URL, matched route, and status code
- **Import custom JSON configs** via the built-in file picker
- **Default configuration** bundled with the app (5 example routes)
- **URL scheme** (`mockengine://`) for control from other apps
- **iOS background mode** — silent audio session keeps the server alive when backgrounded

## URL Scheme

| URL | Action |
|-----|--------|
| `mockengine://start` | Start the server |
| `mockengine://start?port=9090` | Start on a specific port |
| `mockengine://stop` | Stop the server |
| `mockengine://status` | Bring the app to the foreground |

## Code Separation

This app is **completely separate** from the EmbeddedMockEngine library and XCFramework:

- The library (`Sources/EmbeddedMockEngine/`) has zero UIKit/SwiftUI/AVFoundation imports
- The app imports the library as a **local Swift Package dependency** via `project.yml`
- The XCFramework build (`build_xcframework.sh`) only processes the library
