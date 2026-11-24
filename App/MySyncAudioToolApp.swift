import SwiftUI

@main
struct MySyncAudioToolApp: App {
    @StateObject private var session = SyncSession()

    var body: some Scene {
        WindowGroup {
            MainView(session: session)
        }
    }
}

private struct MainView: View {
    @ObservedObject var session: SyncSession
    @State private var choosingRole = false

    private var status: String {
        if session.stage == .failed { return "❌ Sincronización fallida" }
        if session.acousticOK { return "✅ Sincronización confirmada" }
        if session.stage == .linked { return "Enlazados · falta la prueba audible" }
        return "Sincronización de audio"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(status).font(.headline)
                    Text(session.message).foregroundStyle(.secondary)
                    if session.canConnect {
                        Button("Sincronizar") { choosingRole = true }
                    } else if session.isConnected {
                        Button("Cerrar sesión", role: .destructive, action: session.disconnect)
                    }
                }

                if session.role == .host {
                    hostControls
                }

                Section("Canciones") {
                    if session.stage != .loading && session.titles.isEmpty {
                        Text("No hay MP3 en songs. Puedes probar la sincronización sin canciones.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.titles, id: \.self) { title in
                        Text(title)
                    }
                }
            }
            .navigationTitle("Al Unísono")
            .confirmationDialog("Elige el papel de este iPhone", isPresented: $choosingRole,
                                titleVisibility: .visible) {
                Button("Ser anfitrión") { session.connect(.host) }
                Button("Unirme") { session.connect(.guest) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Primero elige anfitrión en un iPhone. Luego elige Unirme en el otro.")
            }
        }
    }

    @ViewBuilder private var hostControls: some View {
        if [.linked, .listening, .verified].contains(session.stage) {
            Section("Prueba de sincronización") {
                Button("Reproducir tres pulsos", action: session.test)
                if session.stage != .verified {
                    Text("Ajuste del invitado: \(session.correction) ms")
                    Button("Adelantar invitado 2 ms") { session.adjust(-2) }
                        .disabled(session.correction <= -120)
                    Button("Retrasar invitado 2 ms") { session.adjust(2) }
                        .disabled(session.correction >= 120)
                }
                if session.stage == .listening {
                    Button("Sonaron al unísono", action: session.verify)
                    Button("No consigo alinearlos", role: .destructive, action: session.reject)
                }
            }
        }
        if session.stage == .verified && !session.titles.isEmpty {
            Section {
                Button("Reproducir lista", action: session.play)
            }
        }
    }
}
