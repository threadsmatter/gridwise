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
- **Your inverter:** a read-only look for inverters on your home network, and whether Amber's own solar curtailment is switched on.

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

- **Your password** is used once, in memory, to compute a sign-in proof (the SRP method Amazon Cognito uses). It is never stored and never sent anywhere.
- **Secrets** (the API token and the SmartShift renewal token) are kept in the macOS Keychain and readable only on this Mac, and only while you are logged in.
- **Signing out** of SmartShift revokes the renewal token with Amazon and deletes it from the Keychain.
- **Override log:** a list of the overrides you send is kept at `~/Library/Application Support/Gridwise/smartshift_overrides.log`. It holds no tokens or account details.
- **Network scan:** the inverter scan only asks devices on your own network who they are. It never changes a setting. macOS may ask you to allow Gridwise to find devices on your local network.

## Planned

- **Inverter control:** curtailing solar on inverters Gridwise can find on the network, starting with GoodWe. It will be off by default and need the owner to confirm.
- **Inverter cloud keys:** step-by-step guides for getting an API key or connection from each inverter maker's cloud (SolarEdge, Enphase, Sungrow, Huawei, GoodWe and others), for systems with no network cable.

## Building from source

Swift Package, no dependencies. `swift build` compiles it, and `./build.sh` wraps the result in an app bundle with an icon.

## Licence

MIT. See [LICENSE](LICENSE).
