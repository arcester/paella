# Paella

A menu bar thermostat for fanless MacBook Air (Apple silicon, macOS 14+).

Paella reads the chip temperature and, when it goes above your target, slows down the apps
using the most CPU/GPU: it moves them to the efficiency cores and pauses them in short
bursts (SIGSTOP/SIGCONT), easing off again as the chip cools. As a last resort it can turn on
Low Power Mode. The menu shows temperature, system power, history charts and the busiest apps.

## Install

```sh
brew install --cask arcester/tap/paella
```

Or download the notarized `Paella-<version>.zip` from
[Releases](https://github.com/arcester/paella/releases) and move `Paella.app` to Applications.

## Permissions

- **Low Power Mode (optional).** Switching it needs root. From Settings, Paella can install
  `/etc/sudoers.d/paella`, a rule that allows only `pmset -a lowpowermode 0` and
  `pmset -a lowpowermode 1`. Installing or removing it asks for the admin password once.
- **Watchdog (optional).** A LaunchAgent in `~/Library/LaunchAgents` restarts Paella if it is
  killed, so no app is ever left paused. Paused apps are also resumed on the next launch.

Paella uses private IOKit HID APIs to read the temperature sensors, so it can't be sandboxed
or distributed through the Mac App Store.

## Command line

```sh
Paella.app/Contents/MacOS/Paella --dump-sensors          # list thermal sensors
Paella.app/Contents/MacOS/Paella --log-csv temps.csv     # log them every 2 s
```

## Build

```sh
swift build                     # debug
scripts/bundle.sh               # dist/Paella.app, ad-hoc signed
SIGN_ID=<cert SHA-1> VERSION=x.y.z scripts/release.sh   # Developer ID + notarization
```

## License

[MIT](LICENSE)
