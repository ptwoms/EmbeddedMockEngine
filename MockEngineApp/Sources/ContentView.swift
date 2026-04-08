import SwiftUI

/// The root view of the MockEngine standalone app.
///
/// Shows server status, start/stop controls, configuration info, and a live
/// request log — everything needed to operate the mock server from the device.
/// Works on both iOS and macOS.
struct ContentView: View {
    @EnvironmentObject var serverManager: ServerManager

    var body: some View {
        NavigationView {
            List {
                serverStatusSection
                configurationSection
                logSection
            }
            .navigationTitle("MockEngine")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(serverManager.isRunning ? "Stop" : "Start") {
                        Task {
                            if serverManager.isRunning {
                                await serverManager.stopServer()
                            } else {
                                await serverManager.startServer()
                            }
                        }
                    }
                    .foregroundColor(serverManager.isRunning ? .red : .green)
                }
            }
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }

    // MARK: - Server Status Section

    private var serverStatusSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(serverManager.isRunning ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(serverManager.statusMessage)
                    .font(.subheadline)
            }

            if let assignedPort = serverManager.assignedPort {
                HStack {
                    Text("URL")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("http://localhost:\(assignedPort)")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            HStack {
                Text("Port")
                    .foregroundColor(.secondary)
                Spacer()
                if serverManager.isRunning {
                    Text("\(serverManager.assignedPort ?? 0)")
                        .font(.system(.body, design: .monospaced))
                } else {
                    TextField("Port", value: $serverManager.port, format: .number)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 100)
                }
            }

            HStack {
                Text("Routes loaded")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(serverManager.routeCount)")
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("Server")
        } footer: {
            #if os(iOS)
            Text("Other apps on this device can reach the server at http://localhost:<port>. Use the URL scheme mockengine://start or mockengine://stop to control the server from other apps.")
            #else
            Text("Other apps on this machine can reach the server at http://localhost:<port>.")
            #endif
        }
    }

    // MARK: - Configuration Section

    private var configurationSection: some View {
        Section("Configuration") {
            HStack {
                Text("Active config")
                    .foregroundColor(.secondary)
                Spacer()
                Text(serverManager.configurationName)
                    .lineLimit(1)
            }

            NavigationLink("Import Configuration…") {
                ConfigurationPickerView()
                    .environmentObject(serverManager)
            }

            Button("Reload Default") {
                Task {
                    await serverManager.loadDefaultConfiguration()
                }
            }
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        Section {
            if serverManager.logEntries.isEmpty {
                Text("No requests yet")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(serverManager.logEntries) { entry in
                    RequestLogRow(entry: entry)
                }
            }
        } header: {
            HStack {
                Text("Request Log")
                Spacer()
                if !serverManager.logEntries.isEmpty {
                    Button("Clear") {
                        serverManager.clearLog()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Request Log Row

/// A single row in the request log list.
struct RequestLogRow: View {
    let entry: RequestLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.method)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(methodColor)
                Text(entry.url)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(entry.statusCode)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(statusColor)
            }
            HStack {
                if let routeID = entry.routeID {
                    Text("→ \(routeID)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("→ no match")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var methodColor: Color {
        switch entry.method {
        case "GET":    return .blue
        case "POST":   return .green
        case "PUT":    return .orange
        case "DELETE": return .red
        case "PATCH":  return .purple
        default:       return .primary
        }
    }

    private var statusColor: Color {
        switch entry.statusCode {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500...:    return .red
        default:        return .primary
        }
    }
}

