# Gridwise

A Mac dashboard for Amber Electric customers. It shows your Amber prices and forecast, your bill so far, the wholesale market in your region and the weather. If you have SmartShift, it also shows your battery and can send SmartShift overrides.

Gridwise is an independent hobby project. It is not made, endorsed or supported by Amber Electric.

## What it shows

- **Prices now:** Amber's buy and feed-in prices for this half hour, plus the cheapest and dearest half hours in Amber's 12-hour forecast.
- **Price chart:** the last 12 hours and Amber's forecast for the next 12.
- **Billing month so far:** what you bought and sold, and the fixed charges, from your metered usage. Amber receives meter data a day or so late, so the newest day or two may be missing.
- **Wholesale market:** AEMO's price and forecast for your region, and what is generating right now.
- **Weather and solar outlook:** seven days for your suburb, with rough expected solar if you enter your panel size.
- **SmartShift** (optional): solar, house, battery and grid power, the battery level, any active override, and buttons to send one.
- **Charge advice:** a suggestion when charging from the grid now looks worth it ahead of a dear evening. It is advice only and sends nothing.
- **Curtailment** (optional): while Amber charges you to export, Gridwise holds your inverter's output down so the solar goes to the house and battery, then puts the inverter's own limit back. See below.

## Install

You need a Mac with macOS 14 (Sonoma) or later.

1. Install Apple's command line tools, if you don't have Xcode:
   ```bash
   xcode-select --install
   ```
2. Download this repository (green **Code** button → **Download ZIP**, then unzip), or clone it:
   ```bash
   git clone https://github.com/threadsmatter/gridwise.git
   ```
3. In Terminal, go into the folder and build:
   ```bash
   cd gridwise
   ./build.sh install
   ```
   This builds `Gridwise.app`, copies it to `~/Applications` and opens it.

If someone gives you a ready-built `Gridwise.app` instead, macOS will block it the first time because it isn't from an identified developer. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Gridwise. Only do this if you trust where the app came from.

## Keychain prompt after building

Gridwise keeps your token in the Keychain. Each time you build the app, macOS sees a new app and asks whether it may use the item Gridwise saved: "Gridwise wants to use your confidential information stored in "Gridwise" in your keychain." Enter your Mac login password and choose **Always Allow**. It asks once per build; a downloaded copy asks once. If you have Xcode with an Apple Development certificate, `build.sh` signs with it and the prompt stops after the first time.

## First run

1. **Amber API token.** Sign in at [app.amber.com.au/developers](https://app.amber.com.au/developers), generate a token, and paste it into Setup. Gridwise checks it with Amber and keeps it in your Keychain.
2. **Your area.** Search for your suburb so Gridwise can show the weather. Your wholesale region is worked out from your electricity network, and you can change it.
3. **Solar and bill** (optional): your panel size in kW, the daily supply charge on your Amber bill, your membership fee, and the day your billing month starts.
4. **SmartShift** (optional): press **Sign in to SmartShift** and use the email and password you use in Amber's app.

## Sending SmartShift overrides

The SmartShift tile can send the same manual override as Amber's app: **charge**, **discharge**, **preserve** or **self-consume**, for 30 minutes to 3 hours. Every send asks you to confirm and says what will happen. When the time is up, SmartShift takes over again. You can cancel an override at any time.

Gridwise only sends overrides. It never turns SmartShift on or off, and it never changes Amber's solar curtailment setting.

This uses the private interface behind Amber's app, which Amber does not publish. Amber could change it or block it at any time. If that happens, the tile shows an error and sends nothing.

## Curtailment

When Amber's feed-in price goes above zero, exporting costs you money. Gridwise can then lower your inverter's power limit just enough for the house and the battery, and put your own limit back when exports pay again.

**Supported inverters**

- **GoodWe** grid-tied inverters (MS, DT, D-NS, XS) with the Wi-Fi or LAN stick on your home network. GW…K-MS models are tested. Other GoodWe models run as a trial: every change is read back, and Gridwise stops if the inverter doesn't keep it.
- **SunSpec inverters** over Modbus TCP: Fronius, SMA, SolarEdge and others. Modbus TCP control must be switched on in the inverter's own settings (on a Fronius: Communication → Modbus → "Inverter control via Modbus"). These inverters undo the limit by themselves if Gridwise stops renewing it for 10 minutes. SunSpec support has been tested against a simulated inverter but not yet on a real one, so it runs as a trial.

**How much it holds back**

Gridwise reads grid import and export from your battery system's own meter, so it doesn't matter whether Amber has onboarded your solar inverter:

1. **AlphaESS cloud** (also Bytewatt and Neovolt), if you add a free AlphaESS key in Setup. Updated about every 10 seconds.
2. **SmartShift**, if you're signed in. Updated about once a minute.
3. **Otherwise, a fixed limit** you choose, such as 30%.

**Safety**

- Off until you set it up, then in **dry run** (shows what it would do, changes nothing) until you choose **Go live**.
- It never raises the limit above your inverter's own setting.
- It puts your limit back when exports pay again, when you stop it, when Gridwise quits, and when the Mac goes to sleep. If the Mac loses power, it puts it back the next time Gridwise opens. Gridwise keeps running in the menu bar when you close its window.
- If someone changes the limit elsewhere (SolarGo, the inverter's own page), Gridwise stops, treats the new value as yours, and goes back to dry run.
- It stands aside while Amber's own solar curtailment is switched on.
- Don't run it alongside another program that controls the same inverter.
- Every action is logged at `~/Library/Application Support/Gridwise/curtailment.log`.

**Getting your inverter's or battery's data from the cloud**

If your system has no network cable to your router, the maker's cloud may be the only way to read it. **Setup → How to get a key for your inverter or battery** explains, maker by maker, how owners get access. Some makers offer free keys (AlphaESS, Fox ESS, Growatt, Enphase, SolarEdge, Tesla), some only on request (Sungrow, Solis, Sigenergy, GoodWe SEMS), and some not to owners at all (Fronius Solar.web, SMA, Huawei). For now Gridwise reads AlphaESS directly.

## Privacy and security

Gridwise has no server of its own and collects nothing. It talks only to these services:

| Service | What it sends | Why |
|---|---|---|
| Amber's API (`api.amber.com.au`) | your API token | prices and usage |
| Amazon Cognito (`cognito-idp.ap-southeast-2.amazonaws.com`) | your email, and a proof made from your password | SmartShift sign-in, the same service Amber's app uses |
| Amber's backend (`backend.amber.com.au`) | the SmartShift sign-in token | SmartShift status and overrides |
| AEMO (`dashboards.public.aemo.com.au`) | your region code | wholesale prices |
| Open Electricity (`data.openelectricity.org.au`) | your region code | generation mix |
| Open-Meteo (`api.open-meteo.com`, `geocoding-api.open-meteo.com`) | the suburb you search for, then a position rounded to about 1 km | weather |
| AlphaESS (`openapi.alphaess.com`), only if you add a key | your AppID, a signature made with your AppSecret, your system's serial number | battery meter readings |
| Your inverter, on your home network only | power-limit commands, only while curtailment is on | curtailment |

- **Your password** is used once, in memory, to compute a sign-in proof (the SRP method Amazon Cognito uses). It is never stored and never sent anywhere.
- **Secrets** (the API token, the SmartShift renewal token and any AlphaESS key) are kept in the macOS Keychain and readable only on this Mac, and only while you are logged in.
- **Signing out** of SmartShift revokes the renewal token with Amazon and deletes it from the Keychain.
- **Override log:** a list of the overrides you send is kept at `~/Library/Application Support/Gridwise/smartshift_overrides.log`. It holds no tokens or account details.
- **Network scan:** the inverter scan only asks devices on your own network who they are. It never changes a setting. macOS may ask you to allow Gridwise to find devices on your local network.

## Planned

- Reading more makers' clouds directly (Fox ESS and Growatt first), for systems without AlphaESS or SmartShift.
- Confirming SunSpec curtailment on real Fronius and SMA inverters. Reports from owners are welcome.

## Building from source

Swift Package, no dependencies. `swift build` compiles it, and `./build.sh` wraps the result in an app bundle with an icon.

## Licence

MIT. See [LICENSE](LICENSE).
