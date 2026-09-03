# App Mixer

App Mixer is a lightweight, native macOS menu-bar app for controlling the volume of individual applications. It shows every open app, gives each one its own volume and mute control, and visualizes live audio directly inside the slider track.

The current output device is always available as a sticky master-volume row at the bottom.

## Features

- Per-application volume sliders and mute controls
- Live audio-level meters integrated into each slider
- Automatic discovery of open macOS applications
- App icons and remembered volume settings
- Search by application name
- Sticky system-output volume control
- Automatically follows default output changes, including switches between built-in speakers and Bluetooth earbuds
- Native SwiftUI interface with no third-party dependencies
- System background services are hidden from the application list

## Requirements

- macOS 15 or newer
- Apple Command Line Tools or Xcode with Swift 6
- System Audio Recording permission

## Build and run

Clone the repository and run the build script:

```sh
git clone https://github.com/ValenCassa/App-Mixer.git
cd App-Mixer
./scripts/build-app.sh
open "dist/App Mixer.app"
```

The script creates an ad-hoc-signed application bundle at `dist/App Mixer.app`. A full Xcode installation is not required when the Apple Command Line Tools are available.

## Audio permission

The first time an application starts an audio route, macOS asks App Mixer for access to record system audio. This is required for Core Audio process taps.

1. Grant the System Audio Recording request.
2. If necessary, open **System Settings → Privacy & Security → System Audio Recording** and enable App Mixer.
3. Quit and reopen App Mixer after changing the permission.

App Mixer processes audio locally. It does not save, transmit, or record audio to a file.

## How it works

App Mixer uses public Core Audio APIs rather than a kernel extension or third-party virtual audio driver.

For every application connected to Core Audio, App Mixer:

1. Creates a private process tap for that application's audio processes.
2. Adds the tap and the physical output device to a private aggregate device.
3. Suppresses the application's direct output only while App Mixer is reading it.
4. Calculates the live peak level for the meter.
5. Applies the selected gain and writes the adjusted samples to the real output device.

Open applications appear immediately, even before they play sound. Their audio route and meter become active automatically when they connect to Core Audio.

## Project structure

```text
Sources/AppMixer/
├── AppMixerApp.swift       Menu-bar and window scenes
├── MixerModel.swift        App discovery, preferences, and master volume
├── MixerView.swift         Search, app rows, meters, and output-device UI
└── ProcessAudioRoute.swift Core Audio tap and sample routing
```

## Current limitations

- Some HDMI, digital, and professional audio devices do not expose software master-volume control.
- Unusual multichannel or encoded output formats may not support per-app gain routing yet.
- This is an early build and has not yet been prepared for App Store distribution.
