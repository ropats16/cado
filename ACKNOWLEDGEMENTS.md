# Acknowledgements

Cado is MIT-licensed and builds on the open-source software and models below.
Thank you to everyone who made them.

<!--
Maintainers: this file is compiled into the app's Acknowledgements screen
(#21) by scripts/embed_acknowledgements.sh (`make acknowledgements`), with
Cado's own LICENSE. Re-run it after editing either file; AcknowledgementsTests
fails while the embedded copy is stale. The screen shows the intro above and
the `## ` sections; this comment is left out.

Each speech engine has one section, headed by its name exactly as Settings
shows it (`EngineKind.displayName`); AcknowledgementsTests checks every
registered engine has one. Other components (libraries, models not tied to an
engine) get a section of their own. Use this format:

    ## <Name>

    - **<Component>** — <author>. <License> (<SPDX id>). <URL>
      <Optional note: what Cado uses it for, attribution the license asks for.>

Full license texts live with each component (e.g. the submodule's LICENSE,
FluidAudio's ThirdPartyLicenses/) or at the linked URL.
-->

## Whisper (whisper.cpp)

- **whisper.cpp** — Georgi Gerganov and contributors. MIT License (MIT).
  https://github.com/ggml-org/whisper.cpp
  Vendored as a submodule at `Sources/CWhisper/whisper.cpp`; Cado's
  default speech engine.
- **ggml** — Georgi Gerganov and contributors. MIT License (MIT).
  https://github.com/ggml-org/ggml
  The tensor library under whisper.cpp (Metal on Apple Silicon), bundled with it.
  Includes llamafile's sgemm (© 2024 Mozilla Foundation, MIT) and YaRN RoPE
  code (© 2023 Jeffrey Quesnelle and Bowen Peng, MIT).
- **Whisper models** — OpenAI. MIT License (MIT). https://github.com/openai/whisper
  Model weights, converted to ggml format and published at
  https://huggingface.co/ggerganov/whisper.cpp; downloaded in Settings ›
  Speech Model, not bundled.
- **Silero VAD** — Silero Team. MIT License (MIT).
  https://github.com/snakers4/silero-vad
  Voice-activity model, in ggml format from
  https://huggingface.co/ggml-org/whisper-vad; optional, downloaded only by
  `scripts/download_vad_model.sh`, not bundled.

## WhisperKit (Core ML)

- **WhisperKit** (argmax-oss-swift) — Argmax, Inc. MIT License (MIT).
  https://github.com/argmaxinc/argmax-oss-swift
  Runs Whisper on Core ML (Neural Engine); its WhisperKit library is linked
  into the app.
- **swift-transformers** (portions, in WhisperKit's `ArgmaxCore/External`) —
  Hugging Face SAS. Apache License 2.0 (Apache-2.0).
  https://github.com/huggingface/swift-transformers
  Hub and tokenizer code, modified by Argmax; linked in through WhisperKit.
- **Whisper models (Core ML)** — OpenAI. MIT License (MIT).
  https://github.com/openai/whisper
  Converted to Core ML by Argmax and published (MIT) at
  https://huggingface.co/argmaxinc/whisperkit-coreml, with OpenAI's tokenizer
  files from https://huggingface.co/openai; downloaded in Settings › Speech
  Model, not bundled.

## Turbo (English/EU)

- **Parakeet TDT 0.6B v3** — NVIDIA. Creative Commons Attribution 4.0
  International (CC-BY-4.0). https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  License: https://creativecommons.org/licenses/by/4.0/. Used unmodified, in
  the Core ML conversion by FluidInference
  (https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml);
  downloaded in Settings › Speech Model, not bundled.
- **FluidAudio** — FluidInference. Apache License 2.0 (Apache-2.0).
  https://github.com/FluidInference/FluidAudio
  Runs Parakeet on Core ML (Neural Engine); linked into the app.
- **NemoTextProcessing (text-processing-rs)** — FluidInference. Apache License
  2.0 (Apache-2.0). https://github.com/FluidInference/text-processing-rs
  Prebuilt library behind FluidAudio's text normalization, which Cado opts out
  of (`traits: []`); only builds made with a Swift toolchain older than 6.2
  still link it.
- **fastcluster** — © 2011 Daniel Müllner; changes from 1.1.24 © Google Inc.
  BSD 2-Clause License (BSD-2-Clause). https://danifold.net/fastcluster.html
  Linked in through FluidAudio.
- **VBx** — © 2021-2024 BUT Speech@FIT. Apache License 2.0 (Apache-2.0).
  https://github.com/BUTSpeechFIT/VBx
  FluidAudio's speaker-diarization clustering is based on it; linked in through
  FluidAudio, not used by Cado.
- **Misaki, cutlet and Convert-Numbers-to-Japanese** — hexgrad (Apache-2.0),
  © 2020 Paul O'Leary McCann (MIT), © 2018 David Wilson (MIT).
  https://github.com/hexgrad/misaki, https://github.com/polm/cutlet,
  https://github.com/Greatdane/Convert-Numbers-to-Japanese
  Ported into FluidAudio's Japanese text-to-speech frontend; linked in through
  FluidAudio, not used by Cado.

## Apple Speech

- **Speech framework and on-device speech models** — Apple Inc. Part of macOS,
  under the macOS Software License Agreement. https://developer.apple.com/documentation/speech
  SpeechAnalyzer / SpeechTranscriber (macOS 26); macOS downloads and manages
  the models. Nothing is bundled with Cado.

## Sparkle

- **Sparkle** — © 2006-2013 Andy Matuschak, © 2009-2013 Elgato Systems GmbH,
  © 2011-2014 Kornel Lesiński, © 2015-2017 Mayur Pawashe, © 2014 C.W. Betts,
  © 2014 Petroules Corporation, © 2014 Big Nerd Ranch. MIT License (MIT).
  https://sparkle-project.org, https://github.com/sparkle-project/Sparkle
  Auto-update: checks Cado's feed on GitHub Releases and installs signed
  updates. Its framework is bundled in the app. It includes bsdiff/bspatch
  (© 2003-2005 Colin Percival, BSD-2-Clause), sais-lite (© 2008-2010 Yuta
  Mori, MIT), ed25519 (© 2015 Orson Peters, Zlib) and SUSignatureVerifier
  (© 2011 Mark Hamlin, BSD-2-Clause); full texts in Sparkle's LICENSE.
