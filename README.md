# Homesplash apps

Companion apps for the Homesplash TV dashboard: an **iPhone app** that pushes Apple Health data, and an **Android TV app** that shows the dashboard full-screen.

## iPhone (Apple Health sync)

A small companion app for the Homesplash TV dashboard. It reads Apple Health on your iPhone and pushes a summary to your Homesplash server over your home network.

It sends:
- **Steps and active energy:** hourly totals for the last 7 days. These are HealthKit statistics, so iPhone and Apple Watch steps aren't counted twice.
- **Heart rate:** hourly min/avg/max for today and yesterday.
- **Resting heart rate, HRV and blood oxygen.**
- **Sleep stages:** last night's Core, Deep, REM and Awake, taken from a single source so overlapping trackers don't double up.

The payload uses Health Auto Export's JSON v2 format, so the server's `apple_health` module reads it as-is. Nothing is written to Health, and nothing leaves your network except to the server address you enter.

## Get the app

Every push to `main` builds an **unsigned** IPA with GitHub Actions:

- **Download:** the [`latest` release](../../releases/tag/latest) has `Homesplash-unsigned.ipa`, which is also attached to each run as an artifact.
- **Sign it:** use a signing service such as Signulous, then install. The IPA carries the HealthKit entitlements (`healthkit` and `healthkit.background-delivery`). Your signing certificate's provisioning profile must allow HealthKit, or iOS will refuse Health access.

## Set up

1. Open the app and enter your server address, e.g. `http://192.168.1.20:8080`.
2. Enter the push token (`HEALTH_PUSH_TOKEN` in the server's `.env`).
3. Tap **Allow Health access** and turn every category on.
4. Tap **Sync now**. You should see "✓ Sent N readings", and the dashboard's Health card updates within seconds.

After that, it syncs when you open the app, when Health gets new steps, heart rate or sleep, and in the background roughly every 30–60 minutes. iOS decides the exact timing. Health data can't be read while the phone is locked, so background syncs catch up after you unlock.

## Build locally (macOS)

```bash
brew install xcodegen
```
```bash
xcodegen generate && open Homesplash.xcodeproj
```

## Android TV (dashboard viewer)

`android/` is a full-screen kiosk browser for the dashboard. It's a plain WebView with no other dependencies, and it:
- keeps the screen awake;
- shows a "can't reach the server" notice and retries every 15 s when the connection drops;
- reloads itself when the dashboard updates;
- can open by itself when the TV turns on.

**Get it:** every push to `android/` builds a signed APK on the [`android-latest` release](../../releases/tag/android-latest) (`Homesplash-TV.apk`).

**Install on the TV**, either way:
- **Downloader app:** install *Downloader* (by AFTVnews) from the Play Store, allow it to install unknown apps, and enter the APK's release URL.
- **adb:** turn on Developer options → USB/Network debugging on the TV, then:
  ```bash
  adb connect <tv-ip>
  ```
  ```bash
  adb install -r Homesplash-TV.apk
  ```

**Use it:**
- **Setup:** on first launch, enter the server address, e.g. `http://192.168.1.20:8080`.
- **Change the server:** press **MENU**, or hold **OK** for about 1 s.
- **Reload:** press **green** (or rewind).
- **Theme:** press **yellow** to cycle Dark → Light → Auto (light by day, dark at night), or pick one in the setup dialog. "Theme from server config" uses `display.theme`.
- **Exit:** press **BACK** twice.

**Opening on power-on:** on Android 10+ the TV only lets an app open itself at boot with the "Display over other apps" permission. Sony TVs hide that setting, so grant it once over adb:

```bash
adb shell appops set com.abdullahhumayun.homesplash.tv SYSTEM_ALERT_WINDOW allow
```

**Signing:** CI signs with the key in the `ANDROID_KEYSTORE_B64` / `ANDROID_KEYSTORE_PASSWORD` repo secrets, so every build installs over the last one. Without those secrets it falls back to a throwaway debug key. You then have to uninstall before each update.
