# Third-party notices

Codeg for iOS depends on the following open-source software. These notices are
provided for attribution and do not change the license of Codeg for iOS.

## codeg

- Source: https://github.com/xintaofei/codeg
- License: Apache License 2.0

The iOS client implements the public protocol and mirrors selected concepts from
the codeg web client. The Apache License 2.0 text is included in this
repository's [LICENSE](LICENSE) file.

## SwiftTerm 1.13.0

- Source: https://github.com/migueldeicaza/SwiftTerm
- License: MIT

Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)

Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)

Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)

Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Added by the Codeg Plus fork

### BlueTTSKit (vendored in `Packages/BlueTTSKit`)

- Source: Jonathan Ashurov's codeg-voice repository, added with git subtree
- License: MIT, except BlueTTSEspeak (below). See `Packages/BlueTTSKit/LICENSE`.
- Ports Light-BlueTTS (https://github.com/maxmelichov/Light-BlueTTS, MIT) and
  renikud-plus (MIT).

### espeak-ng 1.52.0 and ucd-tools (inside BlueTTSEspeak)

- Source: https://github.com/espeak-ng/espeak-ng
- License: GPL-3.0-or-later (`Packages/BlueTTSKit/Sources/CEspeakNG/COPYING`)

Linking BlueTTSEspeak makes the app a combined GPL-3 work. That is fine for a
personal TestFlight build; see docs/FORK.md before any public release.

### ONNX Runtime 1.30.0

- Source: https://github.com/microsoft/onnxruntime
- License: MIT (`Packages/BlueTTSKit/Sources/OnnxRuntimeBindings/LICENSE`)

### Voice model files (downloaded at runtime, not bundled)

- BlueTTS 2.5 ONNX (notmax123/BlueTTS2.5-onnx): no license declared.
- RenikudPlus (notmax123/RenikudPlus): Apache-2.0.
- Voices from Light-BlueTTS (maxmelichov/Light-BlueTTS): MIT.

### whisper.cpp 1.9.1 (the `whisper` XCFramework, `Packages/WhisperCpp`)

- Source: https://github.com/ggml-org/whisper.cpp, release v1.9.1
  (`whisper-v1.9.1-xcframework.zip`), linked as a dynamic framework
- License: MIT, Copyright (c) 2023-2026 The ggml authors. The full text is the
  same MIT License text as SwiftTerm's above, with that copyright line.

### Speech-to-text model files (downloaded at runtime, not bundled)

Published in the `models-v1` release of this repository with a `NOTICE.txt`
and the Apache-2.0 text.

- `ggml-ivrit-large-v3-turbo-q8_0.bin`: ivrit.ai's
  `ivrit-ai/whisper-large-v3-turbo-ggml`, Apache-2.0, quantized to q8_0 by this
  fork (the only change). A fine-tune of OpenAI's whisper-large-v3-turbo
  (MIT, Copyright (c) 2022 OpenAI).
- `ggml-large-v3-turbo-q5_0.bin`: OpenAI whisper-large-v3-turbo in ggml form
  from `ggerganov/whisper.cpp` on Hugging Face, MIT.
- `ggml-silero-v5.1.2.bin`: Silero VAD v5.1.2 (MIT, Copyright (c)
  2020-present Silero Team), ggml conversion from `ggml-org/whisper-vad`, MIT.
- `ggml-tiny-q8_0.bin`: OpenAI whisper tiny (MIT, Copyright (c) 2022 OpenAI),
  q8_0 ggml form from `ggerganov/whisper.cpp` on Hugging Face, MIT. Used only
  to tell Hebrew from English.

### sherpa-onnx 2.0.1 (the `SherpaOnnxC` XCFramework, `Packages/SherpaOnnx`)

- Source: https://github.com/k2-fsa/sherpa-onnx, tag v2.0.1
  (`af2d8d81dbfa61c4cea4c568da78f3982edca005`), linked statically
- License: Apache License 2.0 (the same text as this repository's
  [LICENSE](LICENSE)). Copyright (c) 2022-2026 Xiaomi Corporation and the
  sherpa-onnx contributors.
- Built by `scripts/build-sherpa-onnx.sh` (release
  `sherpa-onnx-2.0.1-ort1.30` of this repository): the C API with TTS and
  speaker diarization off, compiled against the ONNX Runtime 1.30.0 headers
  and linked against BlueTTSKit's ONNX Runtime, which it does not bundle.
- It contains, statically linked:
  - kaldi-native-fbank 1.22.4 (https://github.com/csukuangfj/kaldi-native-fbank), Apache-2.0;
  - KISS FFT (https://github.com/mborgerding/kissfft, commit febd4cae), BSD-3-Clause,
    Copyright (c) 2003-2010 Mark Borgerding. All rights reserved.;
  - kaldi-decoder 0.3.0 (https://github.com/k2-fsa/kaldi-decoder), Apache-2.0;
  - kaldifst (in sherpa-onnx's source, https://github.com/k2-fsa/kaldifst), Apache-2.0;
  - OpenFst 1.8.5 (https://www.openfst.org, csukuangfj/openfst v1.8.5-2026-07-09), Apache-2.0,
    Copyright 2005-2024 Google LLC;
  - simple-sentencepiece 0.7 (https://github.com/pkufool/simple-sentencepiece), Apache-2.0;
  - utf8proc 2.12.0 (https://github.com/JuliaStrings/utf8proc), MIT, Copyright (c) 2014-2021
    Steven G. Johnson, Jiahao Chen, Tony Kelman, Jonas Fonseca, and other contributors;
    Copyright (c) 2009, 2013 Public Software Group e. V., Berlin, Germany; its Unicode data
    under the Unicode License;
  - JSON for Modern C++ 3.12.0 (https://github.com/nlohmann/json), MIT, Copyright (c)
    2013-2025 Niels Lohmann.

The MIT and BSD texts, and the Apache-2.0 text, are shown in the app under
Settings › About › Acknowledgements.

### Smart Turn front end (`Packages/SmartTurn`)

`WhisperLogMel` is a Swift implementation of the steps of
pipecat-ai/smart-turn's `inference.py` (https://github.com/pipecat-ai/smart-turn,
BSD-2-Clause, Copyright (c) 2024–2025, Daily) and of transformers'
`WhisperFeatureExtractor` (https://github.com/huggingface/transformers,
Apache-2.0), checked against them in its tests.

### Talk model files (downloaded at runtime, not bundled)

Published in the `models-v2` release of this repository with a `NOTICE.txt`,
`LICENSE-CC-BY-4.0.txt` and `LICENSE-BSD-2-Clause-smart-turn.txt`.

- `zipformer2-66m-streaming-he-{encoder,decoder,joiner}.int8.onnx` and
  `zipformer2-66m-streaming-he-tokens.txt`: "zipformer2-66m-streaming-he" by
  Yakov Kolani (https://huggingface.co/thewh1teagle/zipformer2-66m-streaming-he),
  CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/), from ivrit.ai's
  mirror (https://huggingface.co/ivrit-ai/zipformer2-66m-streaming-he). The
  contents are unchanged; the files were renamed with the model's name in
  front. A fine-tune of icefall's streaming Zipformer (Apache-2.0) on ivrit.ai
  audio.
- `smart-turn-v3.2-cpu.onnx`: Smart Turn v3.2 from
  https://huggingface.co/pipecat-ai/smart-turn-v3, unchanged, BSD-2-Clause,
  Copyright (c) 2024–2025, Daily. Its encoder is OpenAI's Whisper Tiny (MIT).
- The streaming Zipformer's pack also downloads `ggml-silero-v5.1.2.bin`, the
  models-v1 file listed above.
