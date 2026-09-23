# Changelog

## [0.2.0](https://github.com/vdmkenny/openreliant/compare/v0.1.0...v0.2.0) (2026-09-23)


### Features

* a component takes damage and is destroyed ([#148](https://github.com/vdmkenny/openreliant/issues/148)) ([185d9c6](https://github.com/vdmkenny/openreliant/commit/185d9c6593339369b0a82cf9d47893ec1e6e8f46))
* a help page for the command line ([#166](https://github.com/vdmkenny/openreliant/issues/166)) ([e2f9b14](https://github.com/vdmkenny/openreliant/commit/e2f9b14924639798ad03bd828cb06b458a27b79d))
* an object lists its model's components ([#147](https://github.com/vdmkenny/openreliant/issues/147)) ([539116b](https://github.com/vdmkenny/openreliant/commit/539116b4ac93e62b27a6060586eac85c649e3dc4))
* count the pilot's kills ([#189](https://github.com/vdmkenny/openreliant/issues/189)) ([60e59c5](https://github.com/vdmkenny/openreliant/commit/60e59c5c9a0333e8de2a239bb6158bbc763837f5))
* explosion effects: particles, fireballs, debris, shockwaves, break-up and sparks ([#172](https://github.com/vdmkenny/openreliant/issues/172)) ([941e635](https://github.com/vdmkenny/openreliant/commit/941e635c5fea1dc95df90e3a1f6840b2824f4a2b))
* fuller explosions ([#174](https://github.com/vdmkenny/openreliant/issues/174)) ([9b0a120](https://github.com/vdmkenny/openreliant/commit/9b0a120708cecb675928b45004be16d34955cb95))
* objects collide, and shove each other ([#145](https://github.com/vdmkenny/openreliant/issues/145)) ([f906227](https://github.com/vdmkenny/openreliant/commit/f9062271b708e3ae5468eb517478f8538745acab))
* pick and draw the player's target ([#184](https://github.com/vdmkenny/openreliant/issues/184)) ([56ae68b](https://github.com/vdmkenny/openreliant/commit/56ae68b2d5a15849c24721812d7426f4e0bbbfa0))
* port the order system and steering ([#142](https://github.com/vdmkenny/openreliant/issues/142)) ([aa775a3](https://github.com/vdmkenny/openreliant/commit/aa775a30932b15281ed784d6336ded858f52e44e))
* shield flares and hull hit sounds ([#180](https://github.com/vdmkenny/openreliant/issues/180)) ([dcda937](https://github.com/vdmkenny/openreliant/commit/dcda937b90c6bf90faa70bdb52eaa9be9fa634c4))
* ships are destroyed when their armour runs out ([#169](https://github.com/vdmkenny/openreliant/issues/169)) ([0791403](https://github.com/vdmkenny/openreliant/commit/07914039e227c1927cfed28fe9af5e33d2e07398)), closes [#41](https://github.com/vdmkenny/openreliant/issues/41)
* ships carry the guns their models hold ([#149](https://github.com/vdmkenny/openreliant/issues/149)) ([a2c66c5](https://github.com/vdmkenny/openreliant/commit/a2c66c5c4fd010aded4f5243e548aad47c10630e))
* ships fire the guns they carry ([#152](https://github.com/vdmkenny/openreliant/issues/152)) ([a5f9694](https://github.com/vdmkenny/openreliant/commit/a5f9694031bc9e66d55bf15fafb3ea8cf3cb830d))
* ships hit a capital ship's hull, and the hit hurts ([#146](https://github.com/vdmkenny/openreliant/issues/146)) ([eade58d](https://github.com/vdmkenny/openreliant/commit/eade58d85527fba31da2f8e03243cd417d6740ec))
* shots fly, hit, and are drawn as the game draws them ([#156](https://github.com/vdmkenny/openreliant/issues/156)) ([a2b59f5](https://github.com/vdmkenny/openreliant/commit/a2b59f59babd1bf1bdb5005edcd18931d2fee9f3))
* smoke and fireballs from damaged ships ([#193](https://github.com/vdmkenny/openreliant/issues/193)) ([51f741b](https://github.com/vdmkenny/openreliant/commit/51f741bf8728aacfe631215d22518392b9e4bfcc))
* smooth explosion effects between ticks ([#175](https://github.com/vdmkenny/openreliant/issues/175)) ([59541e9](https://github.com/vdmkenny/openreliant/commit/59541e9ba10962cee35597d8c241ba1fa171f47b))
* sound through OpenAL Soft, with HRTF, reverbs and a master bus ([#165](https://github.com/vdmkenny/openreliant/issues/165)) ([7a2ddb0](https://github.com/vdmkenny/openreliant/commit/7a2ddb0139886cd3f4b603511faeaacc17ae9f6f))
* sound, faithful to the original, through SDL3 ([#163](https://github.com/vdmkenny/openreliant/issues/163)) ([ab06271](https://github.com/vdmkenny/openreliant/commit/ab062719d5912995a37022eef0d4ff8e0b6c45df))
* the Fight order and its combat maneuvers ([#177](https://github.com/vdmkenny/openreliant/issues/177)) ([10a199e](https://github.com/vdmkenny/openreliant/commit/10a199e91dd80c44f96f6f20f1ccc3f3c7069f91))
* the object array, with the Reliant and a Coalition wing in the sandbox ([#137](https://github.com/vdmkenny/openreliant/issues/137)) ([fc725bf](https://github.com/vdmkenny/openreliant/commit/fc725bfa46288d16c6281da16181a198659d6638))
* the radar's contacts ([#190](https://github.com/vdmkenny/openreliant/issues/190)) ([d2fcdd5](https://github.com/vdmkenny/openreliant/commit/d2fcdd5dca370ea1511769a707d913f583d66c3d))
* the target display and the ship status indicator's armour ([#188](https://github.com/vdmkenny/openreliant/issues/188)) ([5f2fc17](https://github.com/vdmkenny/openreliant/commit/5f2fc17ddde550c103402019fc9fd3211b981caf))


### Fixes

* build OpenAL Soft optimized so HRTF keeps up with gunfire ([#173](https://github.com/vdmkenny/openreliant/issues/173)) ([03dd6c1](https://github.com/vdmkenny/openreliant/commit/03dd6c118964702b8e4187cf89c36910172581d8)), closes [#170](https://github.com/vdmkenny/openreliant/issues/170)
* scale damage by the difficulty setting ([#178](https://github.com/vdmkenny/openreliant/issues/178)) ([c1f2fd1](https://github.com/vdmkenny/openreliant/commit/c1f2fd16fd9d92a689b04365c21e65f722176ecd)), closes [#176](https://github.com/vdmkenny/openreliant/issues/176)
* start the sandbox's Sabres 150000 off ([#161](https://github.com/vdmkenny/openreliant/issues/161)) ([10517ea](https://github.com/vdmkenny/openreliant/commit/10517ea526e1b33e02b2a989b667f16810d00944))
* start the sandbox's Sabres further off ([#160](https://github.com/vdmkenny/openreliant/issues/160)) ([bfce022](https://github.com/vdmkenny/openreliant/commit/bfce0222f299efe2a295618c24bdf068d59779ff))

## [0.1.0](https://github.com/vdmkenny/openreliant/compare/v0.0.1...v0.1.0) (2026-09-22)


### Features

* blinking lights cast light, and every light shows its lamp ([#126](https://github.com/vdmkenny/openreliant/issues/126)) ([ae7a01b](https://github.com/vdmkenny/openreliant/commit/ae7a01b296689f5ae4f185785bc162d1d9e7ddb0))
* finish object_move and add knocks ([#121](https://github.com/vdmkenny/openreliant/issues/121)) ([344fb35](https://github.com/vdmkenny/openreliant/commit/344fb3570a95419209863cba770ca31e2abaea7b))
* install the game's files from your discs ([#112](https://github.com/vdmkenny/openreliant/issues/112)) ([60fd69d](https://github.com/vdmkenny/openreliant/commit/60fd69d19cff7d13b28229cf5fe633feb2eca574))
* joysticks and gamepads ([#116](https://github.com/vdmkenny/openreliant/issues/116)) ([8120219](https://github.com/vdmkenny/openreliant/commit/8120219a0ba763868439be217d55e210178971c7))
* light each pixel with the game's own lights ([#125](https://github.com/vdmkenny/openreliant/issues/125)) ([2c1bac4](https://github.com/vdmkenny/openreliant/commit/2c1bac4404701579cf7cd6232690c62426a10e5b))
* part animation, drawn between simulation steps ([#128](https://github.com/vdmkenny/openreliant/issues/128)) ([a931f1f](https://github.com/vdmkenny/openreliant/commit/a931f1faccf139eeabded9e582abf87b11a3bb28))
* the power distribution ([#124](https://github.com/vdmkenny/openreliant/issues/124)) ([7231d46](https://github.com/vdmkenny/openreliant/commit/7231d468487bb670024e5f2bea9785e880d0ab2d))


### Fixes

* commit an object's next place where the game does ([#120](https://github.com/vdmkenny/openreliant/issues/120)) ([8cb1956](https://github.com/vdmkenny/openreliant/commit/8cb19560f303d2fcd8f4dbc452afb31b113c802f))
* orthonormalize each object's orientation in turn, as the game does ([#123](https://github.com/vdmkenny/openreliant/issues/123)) ([c73d117](https://github.com/vdmkenny/openreliant/commit/c73d1172ed04467ba15d7f05dc1d3235b62a02f7))


### Documentation

* describe OpenReliant as a faithful reimplementation on SDL3 and Vulkan ([#108](https://github.com/vdmkenny/openreliant/issues/108)) ([d451d23](https://github.com/vdmkenny/openreliant/commit/d451d238b0d3fd14e808f12132c9a6a3aa098f41))
* the software device draws the display's text ([#129](https://github.com/vdmkenny/openreliant/issues/129)) ([a45c43c](https://github.com/vdmkenny/openreliant/commit/a45c43cc837d79cfb2cc737009f851626e327248))

## 0.0.1 (2026-09-22)


### Documentation

* describe the flying sandbox and the release builds in the README ([a033728](https://github.com/vdmkenny/openreliant/commit/a033728ab9349116056454a5f7e0a34dac082f90))
* rewrite the README status and download instructions in plain language ([6f76d3c](https://github.com/vdmkenny/openreliant/commit/6f76d3ccffd3c59ad90aef7d3208145cd3ba396b))
* say the sandbox is what OpenReliant runs as for now ([ea24b1a](https://github.com/vdmkenny/openreliant/commit/ea24b1a229d94e3daa8d2ac74277b199fc647e05))
