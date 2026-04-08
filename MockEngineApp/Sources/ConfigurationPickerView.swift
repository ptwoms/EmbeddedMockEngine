import SwiftUI
import UniformTypeIdentifiers

/// A view that lets the user import a mock configuration JSON file from the
/// device's file system using the system document picker.
struct ConfigurationPickerView: View {
    @EnvironmentObject var serverManager: ServerManager
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                Text("Import a JSON mock configuration file. The file must conform to the EmbeddedMockEngine configuration format.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("Choose JSON File…", systemImage: "doc.badge.plus")
                }
            }

            if let error = importError {
                Section("Error") {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }

            Section("Format Example") {
                Text(exampleJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Import Config")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Gain security-scoped access to the file
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    defer {
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                    importError = nil
                    await serverManager.loadConfiguration(from: url)
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var exampleJSON: String {
        """
        {
          "settings": {
            "port": 0,
            "logRequests": true,
            "bindAddress": "127.0.0.1"
          },
          "routes": [
            {
              "id": "example",
              "request": {
                "method": "GET",
                "urlPattern": "/api/hello"
              },
              "response": {
                "statusCode": 200,
                "body": "{\\"message\\":\\"Hello!\\"}"
              }
            }
          ]
        }
        """
    }
}
