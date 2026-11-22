import SwiftUI

struct SetupSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var tokenError: String?
    @State private var checking = false
    @State private var search = ""
    @State private var places: [Place] = []
    @State private var searching = false
    @State private var draft = Setup()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Setup").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                Section("Amber API token") {
                    if store.hasToken {
                        HStack {
                            Label("Token saved in your Keychain", systemImage: "key.fill").foregroundStyle(Tint.good)
                            Spacer()
                            Button("Remove", role: .destructive) { store.forgetToken() }
                        }
                        if store.sites.count > 1 {
                            Picker("Site", selection: Binding(get: { draft.siteId ?? store.site?.id ?? "" }, set: { draft.siteId = $0 })) {
                                ForEach(store.sites) { s in Text("\(s.network ?? "Site") · \(s.status ?? "")" + (s.activeFrom.map { " since \($0)" } ?? "")).tag(s.id) }
                            }
                        }
                    } else {
                        Text("Make a token at app.amber.com.au/developers (sign in, then Generate a new token), then paste it here. Gridwise checks it with Amber and keeps it in your Keychain.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Link("Open Amber's developer page", destination: URL(string: "https://app.amber.com.au/developers")!)
                        HStack {
                            SecureField("psk_…", text: $token).textFieldStyle(.roundedBorder)
                            Button("Check and save") { Task { await check() } }.disabled(token.isEmpty || checking)
                            if checking { ProgressView().controlSize(.small) }
                        }
                        if let e = tokenError { Problem(e) }
                    }
                }
                Section("Your area") {
                    LabeledContent("Weather for", value: draft.place ?? "not chosen")
                    HStack {
                        TextField("Suburb or town", text: $search).textFieldStyle(.roundedBorder).onSubmit { Task { await find() } }
                        Button("Find") { Task { await find() } }.disabled(search.count < 2 || searching)
                    }
                    ForEach(places) { p in
                        Button { choose(p) } label: { Text("\(p.name)  ").foregroundStyle(.primary) + Text(p.detail).foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                    Text("The place name you type goes to Open-Meteo to find it. Only its position, rounded to about a kilometre, is kept and sent for forecasts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Wholesale region", selection: Binding(get: { draft.region ?? "" }, set: { draft.region = $0.isEmpty ? nil : $0 })) {
                        Text("From my network (\(Region.from(network: store.site?.network)?.name ?? "unknown"))").tag("")
                        ForEach(Region.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }
                Section("Solar and bill") {
                    numberRow("Solar panels", value: $draft.panelKW, unit: "kW", hint: "e.g. 6.6")
                    numberRow("Daily supply charge", value: $draft.supplyCentsPerDay, unit: "c/day", hint: "on your bill")
                    numberRow("Amber membership", value: Binding(get: { draft.membershipPerMonth }, set: { draft.membershipPerMonth = $0 ?? 0 }), unit: "$/month", hint: "25")
                    Stepper("Billing month starts on day \(draft.billDay)", value: $draft.billDay, in: 1...28)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Nothing here leaves this Mac except as described.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let changedArea = draft.latitude != store.setup.latitude || draft.region != store.setup.region || draft.siteId != store.setup.siteId
                    store.setup = draft
                    dismiss()
                    Task { if changedArea { await store.reloadAll() } else { await store.loadBill() } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .onAppear { draft = store.setup }
    }

    private func numberRow(_ label: String, value: Binding<Double?>, unit: String, hint: String) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("", value: value, format: .number, prompt: Text(hint)).textFieldStyle(.roundedBorder)
                    .frame(width: 150).multilineTextAlignment(.trailing).labelsHidden()
                Text(unit).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    private func check() async {
        checking = true; tokenError = nil
        tokenError = await store.useToken(token)
        if tokenError == nil {
            token = ""
            draft.siteId = store.setup.siteId
        }
        checking = false
    }

    private func find() async {
        searching = true
        places = (try? await WeatherService.places(matching: search)) ?? []
        searching = false
    }

    private func choose(_ p: Place) {
        draft.place = [p.name, p.detail].filter { !$0.isEmpty }.joined(separator: " ")
        draft.latitude = (p.latitude * 100).rounded() / 100
        draft.longitude = (p.longitude * 100).rounded() / 100
        places = []; search = ""
    }
}
