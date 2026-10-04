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
