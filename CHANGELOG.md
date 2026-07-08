# Changelog

## 0.1.0 (2026-07-08)


### Features

* add 10-bit decode path with match-the-source negotiation ([2d1c808](https://github.com/claytercek/godot-native-video/commit/2d1c8081d0729d657dde39feb9bd3f0d013efc22))
* add adaptive scrub with keyframe-on-drag and exact-on-settle ([99430ca](https://github.com/claytercek/godot-native-video/commit/99430ca5eff734f55dbfd5e18af0c0c92d478782))
* add audio track enumeration end-to-end ([124c936](https://github.com/claytercek/godot-native-video/commit/124c93674250b8f9fcb3dac7300c85d932106634))
* add audio-scoped track reselect without video disturbance ([58b0476](https://github.com/claytercek/godot-native-video/commit/58b0476b50584c33203dff3095eabfebf1fe5a27))
* add colorimetry metadata end-to-end across backends and shader ([4b241b9](https://github.com/claytercek/godot-native-video/commit/4b241b908f52215b4a9d0da6ce42bec1e4e5a6d9))
* add CPU-copy import path for stock Vulkan playback ([f9b613e](https://github.com/claytercek/godot-native-video/commit/f9b613e45a5a52a761b76f8d5ba094bd23618ab2))
* add D3D12SurfaceImporter for D3D12 RenderingDevice path ([564c2c9](https://github.com/claytercek/godot-native-video/commit/564c2c9659cdbdd3a8fbe1051dda67eb1b95de7d))
* add Engine Core interfaces with headless test harness ([16301e3](https://github.com/claytercek/godot-native-video/commit/16301e3611379b4bee5df3c69601d91276e82c27))
* add HDR output mode with scene-linear RGBA16F ([60634c5](https://github.com/claytercek/godot-native-video/commit/60634c5c24e37730401abb2614012982368a9756))
* add HDR-to-SDR tone map for PQ/HLG on every display ([0624631](https://github.com/claytercek/godot-native-video/commit/06246312c03aa67d791b9f99b3551de66b3a258a))
* add mid-stream track switch with ClockBridge handoff ([2ac7b97](https://github.com/claytercek/godot-native-video/commit/2ac7b974295a68b9c6b4b1b6c716ca35095aacbe))
* add pre-play audio track selection ([1c0e769](https://github.com/claytercek/godot-native-video/commit/1c0e7696b03fd88be8465d29db8b1b9e9909ab89))
* add real-clip format matrix with headless coverage tests ([0cbbb0b](https://github.com/claytercek/godot-native-video/commit/0cbbb0b2438fe4f2a7c7deec160ff9e7a21328e4))
* add real-clip multi-track matrix coverage ([e93ebbf](https://github.com/claytercek/godot-native-video/commit/e93ebbf735267e54c45693daa1dea42cdc994fb6))
* add shared decode-worker pool with surface-lifetime hardening ([0f7bb6c](https://github.com/claytercek/godot-native-video/commit/0f7bb6c46ae3a7ac8fc8b0deaa84b0e45394c17a))
* add zero-copy NV12-to-RGB present pipeline and Godot binding ([debee4e](https://github.com/claytercek/godot-native-video/commit/debee4e8ac1c23de5d094db2eacec5bb483db87e))
* **avf:** add headless AVFoundation decoder backend ([75741a8](https://github.com/claytercek/godot-native-video/commit/75741a88f232ccc5888d97a24734d4f4bb528d5c))
* **core:** add ClockBridge for audio/monotonic mastership handoff ([dff3b54](https://github.com/claytercek/godot-native-video/commit/dff3b54b5e55bb0689f56e7c0bada72a573c9b95))
* **core:** compute canonical mix format at load; add channel mixer ([35c1720](https://github.com/claytercek/godot-native-video/commit/35c1720842e1ac19cd7870467cc92a7b7f5ffc0f))
* **d3d12:** import P010 as 16-bit plane views ([b9b3b60](https://github.com/claytercek/godot-native-video/commit/b9b3b60d98d102e8c8552b9877313a375b7dba47))
* **dxgi:** import P010 as 16-bit plane views ([c5cf762](https://github.com/claytercek/godot-native-video/commit/c5cf762ecfe27f591be53a9e6a5941599842d90e))
* gate D3D12 import path on Godot &gt;=4.5 ([75c9d83](https://github.com/claytercek/godot-native-video/commit/75c9d8378a76262be04e3b321c33c3e02a269e2d))
* **mf:** add Media Foundation decoder backend with D3D-to-Vulkan interop ([55252d4](https://github.com/claytercek/godot-native-video/commit/55252d45df4e5dd2402354b3bc97541474772a02))
* **mf:** negotiate P010 for 10-bit HEVC decode ([e446258](https://github.com/claytercek/godot-native-video/commit/e446258582d1c1ab9f5713f0dd0d56d302b2c044))
* **mf:** report negotiated colorimetry on MF backend ([f966924](https://github.com/claytercek/godot-native-video/commit/f966924290c1c1dfe8c98753f3ec88e841ed4e6a))
* **smoke:** add Sync Ladder frequency assertions via AudioEffectCapture ([abd893f](https://github.com/claytercek/godot-native-video/commit/abd893f0739c378211b974fa9df250b5570d5389))
* **stream:** expose output_mode on PlatformVideoStream resource ([c7b971e](https://github.com/claytercek/godot-native-video/commit/c7b971e48bfcb1280b02123e52923c74fc37b255))
* **tests:** add headless Godot smoke suite ([577b791](https://github.com/claytercek/godot-native-video/commit/577b791c34cde97b995b8fef1931c361cecec805))
* wire audio-master clock with drop-late/hold-early A/V sync ([3b371f4](https://github.com/claytercek/godot-native-video/commit/3b371f4d161ab087b399bca7ac05dfd509962ad0))


### Bug Fixes

* add Windows build support for MSVC core_tests, VULKAN_SDK paths, and DLL names ([9b14439](https://github.com/claytercek/godot-native-video/commit/9b1443956e792ba802c81690868ef99af7fddd69))
* **avf:** pass colorimetry in build_video_reader ([3ef0672](https://github.com/claytercek/godot-native-video/commit/3ef06727ba24c480abca5f5dba2ab4e814c2877f))
* **avf:** rebuild video reader at target position, not 0 ([c9e3bf9](https://github.com/claytercek/godot-native-video/commit/c9e3bf9a4f2efed8e9038f8c1c7b924ebf3a7826))
* **build:** add missing windows targets to gdextension ([ad9f9dd](https://github.com/claytercek/godot-native-video/commit/ad9f9dd1afe18b132c1efef839c3632e8a5b7a5f))
* **build:** link decode_scheduler.cpp into the library ([054b769](https://github.com/claytercek/godot-native-video/commit/054b769ede63bf9857a3ef025016a88528eabf5b))
* **ci:** skip freq groups on Dummy driver, fix Windows Godot.exe rename ([7f5a579](https://github.com/claytercek/godot-native-video/commit/7f5a5792bdbd3b3e6b12140a4d08537c11273023))
* D3D12 plane-split output textures deadlocked D3D11 context ([8a82ca4](https://github.com/claytercek/godot-native-video/commit/8a82ca40fddd3bb78a6a680d94d80570af782ee0))
* declare push constant as explicit 16-byte block ([a7d0415](https://github.com/claytercek/godot-native-video/commit/a7d04152779a2cc5fe9748df8aa523a76df652b2))
* decode-scheduler race — workers could stomp external busy_ claim ([051ec9c](https://github.com/claytercek/godot-native-video/commit/051ec9c61258982ca06cdc0a786322461897705f))
* **demo:** drive the HDR toggle through stream resource ([9ff6b6c](https://github.com/claytercek/godot-native-video/commit/9ff6b6c27adf65b777bcc5ec75fc863df3afeb7a))
* **docs:** correct stale colorimetry and HDR documentation ([be57405](https://github.com/claytercek/godot-native-video/commit/be5740574cf15649066d398f7a6ea53dcda2ee68))
* **docs:** move static method out of invalid methods_static tag ([9e9f526](https://github.com/claytercek/godot-native-video/commit/9e9f5260ff284cf3b6448d3f6b6162d2155c1456))
* drawtext fontconfig crash in test-media generators on Windows ([da21fd5](https://github.com/claytercek/godot-native-video/commit/da21fd5d10872032fbf8a348f56bd5d421627fc1))
* expose one stable Texture2DRD instead of a wrapper per ring slot ([cb9bdad](https://github.com/claytercek/godot-native-video/commit/cb9bdad78634aae75ecd12ce791611acff151e26))
* fix indentation and trailing newline; add audio track tests ([c05b637](https://github.com/claytercek/godot-native-video/commit/c05b6374e140d31325bde084911eb665dc4b06d6))
* hold per-stream busy claim across request_seek flush ([49b04ee](https://github.com/claytercek/godot-native-video/commit/49b04ee1d4e8d49c71d22a11e9618296d92e735c))
* import shared NV12 image non-disjoint with MUTABLE_FORMAT ([7cfab8a](https://github.com/claytercek/godot-native-video/commit/7cfab8a8e21725117de6a89a8524fde28eb7aa9b))
* install scons via brew on macOS CI runners ([2c8649b](https://github.com/claytercek/godot-native-video/commit/2c8649bc560d68d992ee56c5856d602a0932be87))
* **mf:** defer audio track selection to next seek ([f9f3371](https://github.com/claytercek/godot-native-video/commit/f9f3371216326e22a44f62ade663344b7ff43b9a))
* **mf:** report audio tracks in container order with language tags ([be320d0](https://github.com/claytercek/godot-native-video/commit/be320d04d0047e8d6d3b838b292af9b987379bf3))
* **mf:** rework audio reselect via dedicated audio-only reader ([8ff290c](https://github.com/claytercek/godot-native-video/commit/8ff290c7df42f942f2fedeb1eff668c713afb9d9))
* **present:** degrade to present-disabled in headless mode ([760ea28](https://github.com/claytercek/godot-native-video/commit/760ea28c984a2f6bd95dd1519256512884c8706d))
* **present:** pad push constants to 32 bytes ([f155371](https://github.com/claytercek/godot-native-video/commit/f15537127e14691499132382ff2cb603124e74a3))
* read the frame's texture-array slice in MF test luma readback ([0c66a89](https://github.com/claytercek/godot-native-video/commit/0c66a89838ee1bbb977c8012a2849e6c953fdb4f))
* remove unused target variable and misleading comment in MF reselect ([694dbd1](https://github.com/claytercek/godot-native-video/commit/694dbd1631a7c88283aa5ae440a320923d4e0cf7))
* skip MF HEVC coverage when no decoder MFT is registered ([5cfb631](https://github.com/claytercek/godot-native-video/commit/5cfb6310be3213d0d5dc651aa6bfca7fa1a094f8))
* **smoke:** harden headless audio-freq assertions ([5e78fb8](https://github.com/claytercek/godot-native-video/commit/5e78fb8c304d67e2dd053b323c0c3b86deb074f3))
* tag HDR clip generator via -x265-params, not generic ffmpeg flags ([7c339b3](https://github.com/claytercek/godot-native-video/commit/7c339b3ce21db8d0b582525d1f4491259b388006))
* **tests:** pin clip-matrix colorimetry tags across ffmpeg versions ([6bd373c](https://github.com/claytercek/godot-native-video/commit/6bd373c619ba07eaf854e273aa23619b3c618b0d))
* **tools:** remove spurious includes and Nyquist violation in test media generator ([62d40dc](https://github.com/claytercek/godot-native-video/commit/62d40dc9cd0979702d4180194d3a75d18368a1ad))
* **tools:** use portable drawtext font in multi-track clips ([bf82f06](https://github.com/claytercek/godot-native-video/commit/bf82f06272501852e2c8cc71bf6500bed17d5a08))
* unfreeze playback when audio track ends before video ([a22625f](https://github.com/claytercek/godot-native-video/commit/a22625f76dae844c04acca660697b3236ce56d38))
* use ffmpeg-full on macOS CI for drawtext filter support ([b0daeff](https://github.com/claytercek/godot-native-video/commit/b0daeff85fddf3f5949954d72a2c393bf3a4d134))
* wire decoder texture-array slice through surface importer ([713677c](https://github.com/claytercek/godot-native-video/commit/713677cf259036b4fd78c5219b60557b1a60e2ac))


### Performance

* **core:** bounded backoff for exact-resolve spin, not yield hot-loop ([ee55f9e](https://github.com/claytercek/godot-native-video/commit/ee55f9e69182cc8dbcbd959d1e2b22c9fff3c4dd))


### Refactoring

* **avf:** store core::AudioTrackInfo directly ([fb00e74](https://github.com/claytercek/godot-native-video/commit/fb00e74e95341833ba6bd4d64e37fc4d384f8c55))
* **common:** shrink Binding to a PlaybackController adapter ([fc72ac7](https://github.com/claytercek/godot-native-video/commit/fc72ac7a9b5a5ba2466d004a7b779abe7a34b8c7))
* **common:** single Colorimetry pack API ([d57dbd2](https://github.com/claytercek/godot-native-video/commit/d57dbd2c70c568bf1f5a38191eb90534b13459a2))
* **core:** bundle colorimetry into one Colorimetry struct ([0a41190](https://github.com/claytercek/godot-native-video/commit/0a41190a8308c2a5515190aff8f57f38c6eb513b))
* **core:** extract Canonical Mix Format derivation as pure helper ([fef49f6](https://github.com/claytercek/godot-native-video/commit/fef49f6449f3b80855a13ccd99be2fa6baf9b8a0))
* **core:** extract Godot-free PlaybackController ([0f4562e](https://github.com/claytercek/godot-native-video/commit/0f4562e14bb57b8437af756ef3ba21f808cd2f6c))
* **core:** extract one-clock rule into advance_master_clock ([9ac22c1](https://github.com/claytercek/godot-native-video/commit/9ac22c18fe4659d50e0db66974fcc16333fb1a1f))
* **core:** trim what-comments in playback_controller, keep why ([126d3e5](https://github.com/claytercek/godot-native-video/commit/126d3e5cfc9a18d554c68a117b9303d3e5767159))
* **core:** type now_ms contract as WallClockMs ([76496fd](https://github.com/claytercek/godot-native-video/commit/76496fdac61106a1fc60905f2b1fb362e5007ff0))
* extract D3D11SharedSurfacePool from DxgiSurfaceImporter ([e471a48](https://github.com/claytercek/godot-native-video/commit/e471a48c9819e6895145820b2347da743c5b51fd))
* extract push-constant pack and importer selector as pure functions ([1470df7](https://github.com/claytercek/godot-native-video/commit/1470df7a3d0e21559430f86f22226200bda7c61c))
* **hdr:** drop tone_map_pq/tone_map_hlg wrappers ([4e85610](https://github.com/claytercek/godot-native-video/commit/4e8561093099af212128d3916eda0c7424700e47))
* move CPU-copy flag to importer interface ([d542289](https://github.com/claytercek/godot-native-video/commit/d54228950228c86faa3843e4cb80a7707a957d0a))
* name the slice index VideoFrame::plane_slice ([25cf68f](https://github.com/claytercek/godot-native-video/commit/25cf68fba181fdadfe635bef68f13e8ea48d2db2))
* **present:** compile only the active output mode's shader ([829a88e](https://github.com/claytercek/godot-native-video/commit/829a88e644c64ea3fb66c3d04955c814e9183f7d))
* **present:** drop redundant headless-notice bool ([7ff7003](https://github.com/claytercek/godot-native-video/commit/7ff70033f7e94d95f945c9ff8edbaf3cf09b4431))
* **present:** fold lifecycle bools into state enum ([d504607](https://github.com/claytercek/godot-native-video/commit/d504607a4cdb8fea3891f4c20a2b50d7bb689587))
* rename project to Native Video ([b3c1427](https://github.com/claytercek/godot-native-video/commit/b3c1427aa42fc4d18d0f66d949a80c10f2ba78e4))
* reshape D3D11SharedSurfacePool into interop device ([fbf252e](https://github.com/claytercek/godot-native-video/commit/fbf252e4a9f945bcdbc70909bf9bf160040ffd6e))
* **shaders:** single-source the SDR/HDR compute shader ([576fdf7](https://github.com/claytercek/godot-native-video/commit/576fdf7184a900c16bf39af496963513e6fc720e))
* single-source the NV12-to-RGB compute shader ([6d12d20](https://github.com/claytercek/godot-native-video/commit/6d12d20c918eb9d9cd41d5606d57463aa167f5b9))
* **smoke:** rewrite suite as sequential coroutine ([58dd29d](https://github.com/claytercek/godot-native-video/commit/58dd29d1ce12ba41e9e715ba43b7ff5597f89b3c))
* **smoke:** share run/verify + clip staging with CI ([9f48084](https://github.com/claytercek/godot-native-video/commit/9f4808491e8b95cefac4907cf23e51977a0c9ac5))
* **test:** share AVF/MF multi-track suite bodies ([2958d51](https://github.com/claytercek/godot-native-video/commit/2958d51e929075e5ea31af0b51bc76a3b04e752d))
* **tools:** share multi-track filtergraph builder ([2e40c56](https://github.com/claytercek/godot-native-video/commit/2e40c56ec81e47be2925f32b1b629b9663628fc0))
* unify silent and audio-EOS clock rule ([715bad5](https://github.com/claytercek/godot-native-video/commit/715bad50743320098a1e803137f2fbd1a34d2974))


### Chores

* adjust test workflow run ([593372b](https://github.com/claytercek/godot-native-video/commit/593372b705d7795b780445996d9740502875ffb7))
