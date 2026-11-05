# GPS Teleport

An iPhone app that sets your phone's location to any spot on the map. Find My, Maps and other apps all see the new location. It runs on the phone itself: after a one-time setup on a PC, you don't need a computer.

It uses Apple's developer location-simulation service, the same one Xcode uses for testing. It reaches that service through the [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) loopback tunnel, using the MIT-licensed [idevice](https://github.com/jkcoxson/idevice) library.

## What you need

- An iPhone with **Developer Mode** on (Settings → Privacy & Security → Developer Mode)
- **LocalDevVPN** from the App Store
- **[iloader](https://github.com/nab138/iloader)** on a PC, to install the app the first time. With a free Apple ID the app stops opening after 7 days, but it can refresh itself before then (see [Refresh](#refresh))
- A **pairing file** for your iPhone, made once on a Windows PC with `GPSTeleport-Pairing.exe` (needs the free **Apple Devices** app from the Microsoft Store)

## Install

1. Download `GPSTeleport.ipa` from the [latest release](../../releases/tag/latest).
2. Plug in your iPhone and install the `.ipa` with iloader.
3. On your PC, download `GPSTeleport-Pairing.exe` from the same release. Plug in your iPhone, unlock it, and run the tool. It makes the pairing file and copies it straight into GPS Teleport.
4. Open GPS Teleport, go to **Setup** and tap **Test connection**.

## Use

1. Turn on LocalDevVPN.
2. Tap the map or search for a place, then tap **Spoof here**.
3. Tap **Stop** to go back to your real location.

To simulate a drive, switch to **Drive** and pick a destination, then tap **Find route** and **Start driving**. The trip starts from your current location, or from a green flag if you tap **Start from pin**. You can pause it or change speed along the way, and when it finishes the location stays at the destination until you tap **Stop**.

## Use without Wi-Fi

iOS blocks the connection this app needs while cellular data is on, even through LocalDevVPN, but allows it while data is off. Apps can't switch cellular data, so GPS Teleport asks you to do it:

1. Turn on LocalDevVPN, then tap **Spoof here**.
2. When the app asks, turn off **Cellular Data** in Control Center. The app connects by itself.
3. When it says the location is set, turn **Cellular Data** back on.

- You don't need to do this for every move. While the connection stays open, moving to a new spot works with data on.
- If the connection closes, the spoof ends and the app tells you, so you can start again.
- After a restart, the first connection needs Wi-Fi, because installing Apple's Developer Disk Image needs internet.
- [Refresh](#refresh) still needs Wi-Fi.

## Refresh

GPS Teleport can give itself a new 7 days without a PC. Turn on LocalDevVPN, stop any spoofing, tap the **↻** button, sign in with the Apple ID you installed it with, and tap **Refresh now**. The app closes when it finishes.

- **Reminders:** you get a notification 2 days, 1 day and 4 hours before it runs out.
- **Automatic refresh:** turn on **Refresh automatically** before you refresh. This saves your password in the iPhone's Keychain. After that, opening the app with less than 3 days left refreshes it, as long as LocalDevVPN is on and you aren't spoofing. It can't run while the app is closed, so you still have to open it in time. If Apple asks for a 2FA code, refresh by hand.
- **Sign-in:** this uses the `ani.iloader.app` anisette server, the one iloader uses by default, along with Apple's own servers.
- **If it runs out:** the app won't open, so reinstall it with iloader.

## Limits

- The fake location stays on only while the app is running. A blue location pill shows it's active. Swiping the app away or restarting the phone switches back to your real location.
- Drives send a position only. Motion sensors aren't simulated, so apps that use them to detect driving may not treat a simulated drive as a real one.
- After a restart, the first teleport re-installs Apple's Developer Disk Image automatically. This takes a few seconds and needs internet.
- A new pairing file is needed after an iOS update or a phone reset.

## Building

GitHub Actions builds every push to `main`; see `.github/workflows/build.yml`. The workflow compiles idevice for iOS and generates the Xcode project with XcodeGen. It then builds an unsigned `.ipa`, which iloader signs when it installs it. A Windows job builds the pairing tool from `PairingTool/`.
