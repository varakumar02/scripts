## Nov 12

**Levion Kernel:**
- Built with **PGO (Profile-Guided Optimization)** using a committed kernel profile (**3-12% increase in kernel speed**)
- Added newer **MPTCP Next**
- Included **modules inside the kernel itself**, which might result in **fewer small bugs**
- Dozens of **Qualcomm Wi-Fi fixes** for NULL pointer, out-of-bounds, uninitialized variable and race issues
- Fixed **Tristate slider bar** issue
- **Max brightness level lowered to 2047**
- Faster **LZ4 decompression**: upgraded to **LZ4 v1.10.0** with **ARM64 v8 assembly**, also used by incfs and crypto
- **schedutil** now updates the target frequency when cpufreq limits change
- **Scheduler, memory and filesystem tweaks**: faster mbcache, kernfs, dcache and cpumask paths, fewer needless RT push attempts, better shared block tag performance
- **Binder allocator** backported from android13-5.15, with an **OOM mitigation**
- Many **Adreno (KGSL)** fixes: GPU boot and slumber handling, spinlock recursion, page pool and shrinker accounting, wait-timestamp timeouts
- **Haptics** now use non-OOS vmax, level and gain; **lower vibration latency**
- Added **host-less 24-bit audio formats**
- Fixed **TDM group ID, AMR-WB ioctl** and **ASF packet length** checks
- **Video decode batching** disabled
- **UVC webcam gadget** updated from android16-6.12, replacing the legacy g_webcam
- **FM radio reference node** disabled on lemonade
- **Download mode** armed by default for RAM dumps
- **ramoops** re-setup, plus a dump of the **XBL/UEFI boot log**

**Bluetooth**
- Added LE Audio support
- A2DP offload now runs on the Qualcomm Bluetooth audio HAL
- Added aptX Adaptive (offload only) with a low latency switch, ranked above LDAC
- Offloaded LDAC adaptive bit rate capped at Standard quality (660 kbps)
- Added OxygenOS AAC and AAC VBR interop entries for better headset compatibility
- Fixed audio glitching when an A2DP device disconnects mid-stream

**Audio Sharing**
- Reworked the screen with a single switch and a sharing codec choice
- Shares the best codec both headsets support instead of falling back to SBC
- Better quality on a shared stream: AAC and LDAC adaptive bit rate, high quality SBC bitpool
- Lip sync adjustment with Off / Auto / Manual modes and a per-headset slider
- Swap roles between headsets by switching the active device
- Reconnects all headsets after switching and stops sharing when no headset is active

**Audio**
- Updated Dolby engine with spatializer support
- Raise to reduce ringtone now triggers on a 50° tilt

**Camera**
- Added the Grand Tour beach and glazed tile filters
- Fixed the high-contrast B&W filters

**Privacy**
- Advanced protection is now searchable from Settings
- New Tracking section: copied-link cleaning and advertising ID
- Tracking parameters are stripped from copied links
- Advertising ID permissions are never granted to apps

**Security**
- Enabled verified boot with a new AVB signing key
- Added OEM unlock support, allowed by default after an FRP format

**System**
- Boot now uses drivers built into the kernel, with vendor_dlkm on ext4
- Qualcomm config service now reads its presets from /vendor/etc
- Fixed SELinux denials for system_app and the Bluetooth HAL

**Credits**
- @SuperJammy: Good Audio Sharing features
- @Madara273: For MPTCP, including kernel modules in the kernel, and more
- @Deadpool-2003: For testing and providing PGO profiles for the OnePlus 9 Pro
---

## Nov 3

- Reverted display colors to normal
- Setting wallpaper from Oplus Gallery still fails
- Will update Dolby Audio to be sweeter (less treble / bass)
- This is a CORE build + Google Wizard Setup

---

## Oct 28

- Fixed 10-bit color photo
- Removed Breeno Scan from OplusCamera (uses ColorOS Translate, security concerns)
- Fixed display refresh rate select
- Added Good Audio Sharing features
- Fixed wallpaper select in Oplus Gallery
- Updated KernelSU-Next to 3.4.2
- Monitor mode + AP can now be used at the same time
- Enabled raise to lower call volume (sensitive: triggers on a ~20° lift)
- Dolby Atmos retuned: Dynamic 98 → 42, Music 64 → 42, Bass Enhancer turned off on every profile
- Updated GhostWire app
- Updated a few internals in Band Locking
- Fixed a few Bluetooth vulnerabilities
- Better battery saving

**Credits**
- @SuperJammy: Good Audio Sharing features
- @MrR0b0X: Monitor mode + AP at the same time

---

## Oct 23

- Reverted display colors to normal

---

## Oct 21

**General**
- Fixed Google Setup Wizard by removing the AI assistant request during setup
- Removed screenshot detection by default
- Fixed 5G signal preview to match OxygenOS Settings
- Fixed Bluetooth audio issues with Spatial Audio disabled
- Fixed volume slider issues
- Added a Refresh Rate toggle
- Updated the Video Codec2 library

**Oplus Gallery**
- Fixed share icon issues
- Enabled Dolby support for all supported codecs
- Enabled Gallery blur effects

**Oplus Camera**
- Enabled 48MP Hi-Res mode
- Enabled Ultra Night Video
- Added 18 new camera filters
- Updated Dolby color profiles to match Find X9 Ultra for improved Dolby Vision video playback
- Fixed a few bugs when taking photos while recording
- Fixed 10-bit, HEIF and HEVC button combinations
- Fixed noise in HDR mode

---

## Oct 20

- Fixed volume slider issue
- Enabled Ultra Night video
- Fixed audio on Bluetooth 5.1 with Spatial off
- Fixed lockscreen charging stats
- Fixed set wallpaper / lockscreen in Oplus Gallery
- Fixed share option in Oplus Gallery
- Fixed Google Setup hang issue

---

## Oct 18

- Fixed MEMC
- Better battery performance
- Better heat management than before
- Faster RAM compression
- Added OnePlus Gallery

---

## Oct 9

- Newer OOSCam v5.045.451
- Migrated to pure 64-bit architecture (faster and lighter ROM)
- Updated Adreno GPU drivers to v676.76.1 (1-2% faster and cooler)
- Fine-tuned Dolby Atmos
- Added Spatial Audio support
- Added eSIM support (physical eSIM)
- Added Vibrant Color Effect and Ultra-high Video Resolution toggle

---

## Oct 7

- Newer OOSCam v5.045.451
- Added MEMC and SDR2HDR

---

## Oct 5

**OOSCam (stock OnePlus camera): fully functional**

*Video*
- 4K at 30 / 60 fps; 1080p / 720p at a true 120 fps
- 4K 120 fps: upscaled from the 2000x1128 sensor mode on the OP9; native on the 9 Pro (measured 113-119 fps there)
- 4K60 no longer crashes the camera firmware, including 4K30 ↔ 4K60 switching
- 4K60 no longer dips to ~46 fps while pinching below 1.07x (now ~60 fps)
- 0.6x ultrawide now works at 60 fps
- Slow-motion (240 fps) and 120 fps clips now save video (nothing was saved before)
- Video Night: crash fixed
- Video background blur: crash fixed, slider works and records

*Photo*
- Night mode and Super Night work (DSP init crash fixed, full night processing switched back on)
- Photo filters are now applied to the saved photo
- Pro mode: RAW processing library now loads
- Long exposure: its libraries are now included
- AI Scene: colour enhancement now runs on saved photos
- Portrait blur, Red-eye, Tilt-shift, XPan and Dual-view libraries added or fixed
- Super Text (document scanner) fixed, libraries added
- Frame drop while zooming fixed and stabilized

*System*
- Camera firmware: kernel changes so a bad read no longer takes the firmware down
- Camera HAL can now reach the thermal service, so long recordings throttle properly
- OIS on the 9 Pro: verified working
- In progress: Hardware JPEG

**Levion Kernel**
- KernelSU-Next v3.4.0 + SUSFS v2.3.0
- CASS + WALT + Bore 5.1.0
- Memory reclaim: MGLRU (backported from upstream v6.1)
- BBRv3 + FQ-CoDel
- Camera stability: ICP fault handling, ISP anchor-config support, request-manager overrun guard, OIS diagnostics
- Panic handling: no RAM-dump mode after a panic, power-key forced panic
- Scheduler / memory: RCU boost, ZRAM writeback, cheaper CFS group updates
- NetHunter: Realtek 8812AU / 8814AU / 8188EUS, RTW88, RTL8xxxu, ath9k / ath10k, mac80211 with radiotap + injection flags, Bluetooth, SDR (airspy, hackrf), CAN / ISO-TP, RNDIS
- Qualcomm WLAN monitor mode + packet injection (hybrid Direct-DP / WMI)
- On-device `/dev/diag` (QCOM diagchar) for the modem

**Advanced protection (new)**
- PrivacySettings app: Duress PIN (wipes on duress credential), USB data protection, auto-reboot, radio timeout
- Datura firewall (ported to Android 16): block-all-network, block-new-apps

**Other**
- Fixed many bugs and SELinux policy issues
- GhostWire app temporarily added

**Credits**
- @SuperJammy555: original OnePlus 9 / 9 Pro device, vendor, hardware and OOSCam trees this build is based on, plus OOSCam packaging
- @Varakumar: OOSCam fixes and enhancements (4K60 crash fix, real 120 fps, slow-motion, Night mode, Video Night, video background blur, filters, 0.6x at 60 fps, camera firmware stability)
- @Madara273: backported kernel patches (Sakura.MTX)
- OnePlusOSS: open-source kernel and device tree used as reference for camera fixes
- dodge-camera-port (pjgowtham, ghostrider-reborn, kras)
- @Flashedfiber: sponsored the Pixeldrain download server
- @meowcat902: testing on OnePlus 9
- @greenlogoguy: testing on OnePlus 9 Pro (ongoing)

---

## Initial Release

**Levion Kernel**
- Multi-Gen LRU (MGLRU) backported and enabled by default, with a runtime on/off switch at `/sys/kernel/mm/lru_gen/enabled` for A/B testing
- CASS (Capacity Aware Superset Scheduler) running alongside WALT
- KernelSU-Next v3.2.0 + SUSFS v2.2.0 built in
- UFS Host Performance Booster (UFSHPB) enabled (upstream reports sequential writes improving 490 MB/s → 515 MB/s)
- Default cpufreq governor switched from `performance` to `schedutil`
- Faster thermal (LMH) and devfreq polling, moved to high-priority / non-deferrable work so throttling reacts quicker under load
- Energy model re-tuned for the lahaina DTS from real freqbench data
- Westwood / H-TCP / Vegas TCP congestion control, mq-deadline + Kyber I/O schedulers built in
- 250 Hz timer, `noatime` by default
- Fixed AMOLED (`amb655x`) ESD detection (panel damage / burn-in recovery was silently broken)
- Fixed a composer service crash (SIGSEGV) on boot from a bad panel node
- Fixed the charger driver leaking a resource on every poll cycle

**Included OnePlus Camera (OOSCam)**
- The full stock OxygenOS camera app, shipped alongside Aperture

**DeviceSettings app**
- Kernel Manager: governor-driven Performance profile picker
- Selective Band Lock: pick exact LTE / 5G bands per SIM
- Powertools: KProfiles integration, sysfs IO tuning, TCP congestion control switch

**Camera / Media**
- 8K video recording on the main camera (HEVC, raised bitrate ceilings)
- Fixed CamcorderProfiles for the mono / telephoto camera

**Other**
- Advanced Reboot menu enabled by default
- Self-hosted OTA updater (no more relying on third-party mirrors)
- Switched to Sony Dolby Atmos audio
- VoLTE / VoWiFi unlocked for more carriers

**Bug fixes**
- Fixed a display break-loop caused by a broken SDM PictureAdjustment path
- Fixed PowerHAL crashing on boot from a duplicate `powerhint.json` entry
- Fixed the Updater app crashing or getting stuck on a null / stale download
- Fixed battery design-capacity reporting (was silently reading the wrong type)
- Fixed WiFi tombstone / crash-report access
- Fixed mic issues in apps like WhatsApp
- Fixed a dozen+ SELinux denials blocking system_app, rild, zygote, vendor_init and other core services

**Credits**
- Jammy555: the bulk of the device-tree, vendor and hardware work this ROM is built on, plus the stock OOSCam packaging
- crDroid (crdroidandroid): the Levion kernel's OnePlus 9 (lemonade) base
- @meowcat902: testing on OnePlus 9