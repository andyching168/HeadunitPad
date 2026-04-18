# HeadunitPad

**Transform your iPad into an Android Auto display screen.**

> This project enables iPads (especially iPad mini 6) to act as a Headunit display/host for Android Auto, connecting wirelessly to your Android phone.

## Features

### Core Functionality
- **Wireless Connection** - Connects to Android Auto Server via WiFi (TCP port 5277)
- **Video Streaming** - Receives and renders H.264 video frames from Android Auto
- **Audio Playback** - PCM audio output via AVAudioEngine
- **Touch Input** - Sends touch events back to Android Auto
- **Microphone Support** - Captures and streams microphone input
- **GPS Location** - Shares iPad or phone GPS location with Android Auto

### Settings
- **Orientation** - Landscape or Portrait mode (Portrait has known issues)
- **Resolution** - Configurable video resolution
- **FPS** - 30 or 60 fps options
- **DPI** - Custom DPI adjustment
- **GPS Source** - Use iPad GPS or phone GPS

## How It Works

### Connection Flow

```
┌─────────────┐         WiFi          ┌─────────────────┐
│   iPad      │ ◄──────────────────► │ Android Phone   │
│  (Client)   │                     │  (Server)       │
│             │   Port 5277/TCP      │                 │
└──────┬──────┘                     └────────┬────────┘
       │                                       │
       │  1. TCP Connection                    │
       │  2. Version Request/Response          │
       │  3. TLS Handshake (wrapped in AAP)    │
       │  4. Status OK                         │
       │  5. BINDING_RESPONSE                  │
       │  6. Running (encrypted AAP messages)  │
       ▼                                       ▼
┌─────────────────────────────────────────────────────┐
│                   iPad Display                       │
│  • Renders H.264 video frames                        │
│  • Sends touch events to phone                      │
│  • Plays audio from phone                           │
│  • Provides microphone and GPS data                  │
└─────────────────────────────────────────────────────┘
```

### Protocol Details

The Android Auto Protocol (AAP) uses:
- **Channel 0** - Control messages (handshake, binding)
- **Channel 1** - Sensor data
- **Channel 2** - Video stream (H.264)
- **Channel 3** - Input (touch, key events)
- **Channel 4/5** - Audio streams
- **Channel 6** - Primary audio
- **Channel 7** - Microphone

TLS is encapsulated inside AAP messages (Channel 0, Type 3), not at the socket layer.

## Known Issues

### Portrait Mode
Portrait orientation mode does not currently work correctly. The video display and touch input mapping have issues in portrait mode. **Landscape mode is recommended for best results.**

## Requirements

- **iPad** (iPad mini 6 recommended for best performance)
- **iOS/iPadOS 16.6+**
- **Android phone** running [Headunit Reloaded](https://github.com/andreknieriem/headunit-revived)
- **WiFi network** (both devices on same network)

## Installation

### Sideloading (Recommended for Personal Use)

1. Clone this repository
2. Open `iPadOS/HeadunitPad/HeadunitPad.xcworkspace` in Xcode
3. Configure your development team in Signing & Capabilities
4. Build and run on your iPad

### Dependencies

- [OpenSSL-Universal](https://github.com/krzyzanowskim/OpenSSL) via CocoaPods
- [Socket.io](https://github.com/mikezellers/SocketIO-Android-Swift) (not currently used, for future WiFi Direct)
- [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) (not currently used)

## Architecture

```
iPadOS/HeadunitPad/HeadunitPad/
├── Core/
│   ├── AAP/
│   │   ├── AapTransport.swift      # Main transport layer with TLS
│   │   ├── AapMessage.swift        # Message framing
│   │   └── Protocol/Channel.swift   # Channel definitions
│   ├── Network/
│   │   ├── TcpHandler.swift        # TCP connection management
│   │   ├── OpenSslTlsHandler.swift # OpenSSL TLS implementation
│   │   ├── Discovery.swift          # Network device discovery
│   │   └── ConnectionManager.swift  # Connection lifecycle
│   ├── Audio/
│   │   ├── PCMAudioPlayer.swift     # PCM audio playback
│   │   └── MicrophoneCapture.swift  # Microphone input
│   ├── Video/
│   │   └── H264VideoRendererView.swift # Video rendering
│   └── Location/
│       └── LocationCapture.swift     # GPS location
└── Resources/Raw/
    ├── cert                          # Client certificate
    └── privkey                       # Private key
```

## Disclaimer

This project is for educational and personal use only. Android Auto is a trademark of Google LLC. This project is not affiliated with or endorsed by Google.

## Acknowledgments

### Special Thanks

- **Andre Knieriem** - Developer of [Headunit Revived](https://github.com/andreknieriem/headunit-revived), the Android Auto Server application that makes this project possible

### Inspiration

- **Mike Reid** - Original [Headunit](https://github.com/mikereidis/headunit) developer. His pioneering work on the Android Auto protocol laid the foundation for all subsequent projects in this space. Mike passed away; his contributions to the open-source community will be remembered.

### Open Source Libraries

- [OpenSSL](https://www.openssl.org/) - Cryptography toolkit
- [VideoToolbox](https://developer.apple.com/documentation/videotoolbox) - Apple's hardware-accelerated video decoding

## License

AGPL-v3 - See LICENSE file for details.

---

**If you find this project useful, consider supporting the developers of Headunit Revived who make this ecosystem possible.**
