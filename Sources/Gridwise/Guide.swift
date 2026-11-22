import SwiftUI

// How an owner gets read access to their own inverter or battery data from the maker's cloud, for systems
// with no network cable to the home network. Researched from the makers' developer pages and, where those
// would not load, from integration projects' documentation, on 22 Nov 2026. Makers change these often:
// each entry says how sure it is.

struct CloudGuide: Identifiable {
    let brand: String
    let access: Access
    let steps: String
    let youGet: String
    let freshness: String
    let source: String
    let confirmed: Bool                  // read on the maker's own page
    var id: String { brand }
    enum Access: String { case selfServe = "Free, do it yourself", request = "On request", business = "Not for owners" }
    var usableInGridwise: Bool { brand.hasPrefix("AlphaESS") }

    static let all: [CloudGuide] = [
        CloudGuide(brand: "AlphaESS, Bytewatt, Neovolt", access: .selfServe,
                   steps: "Register a free developer account at open.alphaess.com. Add your system with its serial number (SN) and check code, both on the label or in the manual.",
                   youGet: "An AppID and AppSecret. Paste them into Gridwise's Setup to follow your house load from the battery's meter.",
                   freshness: "Near live: about every 10 seconds.", source: "open.alphaess.com", confirmed: false),
        CloudGuide(brand: "Fox ESS", access: .selfServe,
                   steps: "At foxesscloud.com, open your profile (top right) → API Management → Private Token → Generate API key. Generating a new key turns off the old one.",
                   youGet: "An API key.", freshness: "About every 5 minutes (not stated by Fox ESS).",
                   source: "foxesscloud.com/public/i18n/en/OpenApiDocument.html", confirmed: true),
        CloudGuide(brand: "Growatt", access: .selfServe,
                   steps: "In the ShinePhone app: My Account → tap your username → API Token, and make sure Use Status is on. Australian systems use openapi-au.growatt.com.",
                   youGet: "An API token.", freshness: "About every 5 minutes. Polling too often can lock the account.",
                   source: "Integration projects' documentation", confirmed: false),
        CloudGuide(brand: "Sungrow", access: .request,
                   steps: "Log in to developer-api.isolarcloud.com with your iSolarCloud account → Applications → Create Application and describe your use. Approval has taken from minutes to over a week.",
                   youGet: "An app key and secret key, used with your iSolarCloud login.", freshness: "Often said to be 5 minutes.",
                   source: "Integration projects' documentation", confirmed: false),
        CloudGuide(brand: "Solis", access: .request,
                   steps: "Open a SolisCloud Service Centre ticket of type \"API Access Request\". Once it's done, on a computer: SolisCloud → Basic Settings → API Management → Activate now → View Key.",
                   youGet: "A KeyID, KeySecret and API address.", freshness: "Often said to be 5 minutes.",
                   source: "solis-service.solisinverters.com (API access article)", confirmed: true),
        CloudGuide(brand: "Sigenergy", access: .request,
                   steps: "Registration at developer.sigencloud.com needs an invitation code from Sigenergy; approval takes a few days. Your system ID is in mySigen → Settings → ⋯ → Basic Info.",
                   youGet: "An AppKey and AppSecret.", freshness: "About once every 5 minutes.",
                   source: "Shelly's integration guides", confirmed: false),
        CloudGuide(brand: "SolarEdge", access: .selfServe,
                   steps: "The old \"Admin → Site Access → API Access\" key was retired in November 2026. Use the new developer platform: sign in at developer.solaredge.com, create a Site Access app, and approve your site.",
                   youGet: "An OAuth client ID and secret, and your site ID.", freshness: "15-minute averages on the free tier.",
                   source: "Integration projects' documentation", confirmed: false),
        CloudGuide(brand: "Enphase", access: .selfServe,
                   steps: "Create a free account at developer-v4.enphase.com, make an app on the free Watt plan, then approve it with your Enlighten login.",
                   youGet: "An API key, client ID and secret.", freshness: "15-minute intervals on the free plan; live data is a paid plan (USD 249 a month).",
                   source: "developer-v4.enphase.com", confirmed: true),
        CloudGuide(brand: "Tesla Powerwall", access: .selfServe,
                   steps: "Create an app at developer.tesla.com, which needs a website domain you control to host a key file, then approve it with your Tesla account.",
                   youGet: "An OAuth client ID and secret, and your energy site ID.", freshness: "Live.",
                   source: "developer.tesla.com", confirmed: true),
        CloudGuide(brand: "GoodWe (SEMS)", access: .request,
                   steps: "There's no public developer page. Ask GoodWe or your installer for SEMS API access; GoodWe asks for an NDA first. Most GoodWe inverters can be read and controlled on the home network instead (Gridwise's Curtailment tile).",
                   youGet: "API use with your SEMS login.", freshness: "Not stated.", source: "Third-party documentation", confirmed: false),
        CloudGuide(brand: "Huawei (FusionSolar)", access: .business,
                   steps: "A company administrator, normally your installer, creates a Northbound API account under System → Company Management → Northbound Management.",
                   youGet: "A separate API username and password.", freshness: "Often said to be 5 minutes.",
                   source: "Third-party documentation", confirmed: false),
        CloudGuide(brand: "Fronius (Solar.web)", access: .business,
                   steps: "Fronius's Solar.web API is for business customers on a paid contract. Fronius inverters can be read and controlled on the home network instead: switch on Modbus TCP in the inverter's settings and use Gridwise's Curtailment tile.",
                   youGet: "–", freshness: "–", source: "fronius.com/en/solarweb-query-api", confirmed: true),
        CloudGuide(brand: "SMA (Sunny Portal)", access: .business,
                   steps: "SMA's API is a business contract; owners can only approve access for a company. SMA inverters can be read and controlled on the home network with SunSpec Modbus switched on.",
                   youGet: "–", freshness: "–", source: "developer.sma.de", confirmed: true),
    ]
}

struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Getting your inverter's or battery's data").font(.title3.weight(.semibold))
            Text("For systems with no network cable to your router, the maker's cloud is often the only way to read live power. Here is how each maker gives owners access, as of November 2026. Makers change these often, so check their own page too.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(CloudGuide.all) { g in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(g.brand).font(.headline)
                                Text(g.access.rawValue).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background((g.access == .selfServe ? Tint.good : g.access == .request ? Color.orange : Color.secondary).opacity(0.2), in: Capsule())
                                if g.usableInGridwise { Text("Works with Gridwise").font(.caption.weight(.semibold)).foregroundStyle(Tint.good) }
                            }
                            Text(g.steps).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text("You get: \(g.youGet)  ·  Updates: \(g.freshness)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("Source: \(g.source)\(g.confirmed ? "" : " (not confirmed on the maker's own page)")").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Divider()
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 600, height: 640)
    }
}
