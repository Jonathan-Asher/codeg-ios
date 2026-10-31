import SherpaOnnx
import SwiftUI

/// One third-party component the app ships or downloads, with its license.
struct Acknowledgement: Identifiable, Hashable {
    enum License: String {
        case mit = "MIT"
        case bsd2 = "BSD-2-Clause"
        case bsd3 = "BSD-3-Clause"
        case apache2 = "Apache-2.0"
        case ccBy4 = "CC-BY-4.0"
        case gpl3 = "GPL-3.0-or-later"
        case none = "No license declared"
    }

    let name: String
    /// Version and what the app uses it for.
    let detail: String
    let license: License
    /// Copyright lines, also printed above an MIT or BSD text.
    let copyright: String
    let url: String
    /// Changes made to it, for licenses that ask for them (CC BY 4.0 §3(a)(1)(B)).
    var changes: String? = nil

    var id: String { name }
}

/// About › Acknowledgements: the open-source code in the app and the models it
/// downloads, with their licenses. The same list, with sources, is in
/// THIRD_PARTY_NOTICES.md; the models' provenance is in each release's
/// NOTICE.txt.
struct AcknowledgementsView: View {
    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("In the app", Self.software)
                    section("Inside sherpa-onnx", Self.insideSherpaOnnx)
                    section("Models downloaded to this iPhone", Self.models)
                    Text(verbatim: Self.engineVersions)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: LocalizedStringKey, _ items: [Acknowledgement]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 4)
            ForEach(items) { AcknowledgementCard(item: $0) }
        }
    }

    /// What the linked engines report about themselves.
    static var engineVersions: String {
        let versions = StreamingTransducerRecognizer.versions
        return "sherpa-onnx \(versions.sherpaOnnx) runs on ONNX Runtime \(versions.onnxRuntime), the copy BlueTTSKit links."
    }

    static let software: [Acknowledgement] = [
        Acknowledgement(name: "Codeg for iOS", detail: "The app this fork is based on.", license: .apache2,
                        copyright: "Copyright 2026 xintaofei", url: "https://github.com/xintaofei/codeg-ios"),
        Acknowledgement(name: "SwiftTerm", detail: "1.13.0. The terminal.", license: .mit,
                        copyright: "Copyright (c) 2019-2022 Miguel de Icaza\nCopyright (c) 2017-2019, The xterm.js authors\nCopyright (c) 2014-2016, SourceLair Private Company\nCopyright (c) 2012-2013, Christopher Jeffrey",
                        url: "https://github.com/migueldeicaza/SwiftTerm"),
        Acknowledgement(name: "whisper.cpp", detail: "1.9.1. Voice typing and Talk's final transcript.", license: .mit,
                        copyright: "Copyright (c) 2023-2026 The ggml authors", url: "https://github.com/ggml-org/whisper.cpp"),
        Acknowledgement(name: "ONNX Runtime", detail: "1.30.0. Runs BlueTTS, the streaming Zipformer and Smart Turn.", license: .mit,
                        copyright: "Copyright (c) Microsoft Corporation", url: "https://github.com/microsoft/onnxruntime"),
        Acknowledgement(name: "BlueTTSKit", detail: "Read aloud and Talk's voice: BlueTTS 2.5 with RenikudPlus. Ports Light-BlueTTS (MIT) and renikud-plus (MIT).",
                        license: .mit, copyright: "Copyright (c) 2026 Jonathan Ashurov", url: "https://github.com/maxmelichov/Light-BlueTTS"),
        Acknowledgement(name: "espeak-ng", detail: "1.52.0, with ucd-tools. English sounds inside Hebrew text, for BlueTTS.", license: .gpl3,
                        copyright: "Copyright (C) 2005-2017 Jonathan Duddington, Reece H. Dunn and the espeak-ng contributors",
                        url: "https://github.com/espeak-ng/espeak-ng"),
        Acknowledgement(name: "sherpa-onnx", detail: "2.0.1, its C API built without TTS. Talk's live transcript.", license: .apache2,
                        copyright: "Copyright (c) 2022-2026 Xiaomi Corporation and the sherpa-onnx contributors",
                        url: "https://github.com/k2-fsa/sherpa-onnx"),
        Acknowledgement(name: "Smart Turn inference", detail: "Talk's end-of-turn front end follows pipecat-ai/smart-turn's inference code and transformers' WhisperFeatureExtractor.",
                        license: .bsd2, copyright: "Copyright (c) 2024–2025, Daily", url: "https://github.com/pipecat-ai/smart-turn"),
    ]

    static let insideSherpaOnnx: [Acknowledgement] = [
        Acknowledgement(name: "kaldi-native-fbank", detail: "1.22.4. Audio features.", license: .apache2,
                        copyright: "Copyright (c) 2022 Xiaomi Corporation", url: "https://github.com/csukuangfj/kaldi-native-fbank"),
        Acknowledgement(name: "KISS FFT", detail: "Inside kaldi-native-fbank.", license: .bsd3,
                        copyright: "Copyright (c) 2003-2010 Mark Borgerding. All rights reserved.", url: "https://github.com/mborgerding/kissfft"),
        Acknowledgement(name: "kaldi-decoder", detail: "0.3.0. Parts of Kaldi.", license: .apache2,
                        copyright: "Copyright 2009-2013 Microsoft Corporation, Saarland University, Johns Hopkins University and others\nCopyright (c) 2023 Xiaomi Corporation",
                        url: "https://github.com/k2-fsa/kaldi-decoder"),
        Acknowledgement(name: "kaldifst", detail: "In sherpa-onnx's source.", license: .apache2,
                        copyright: "Copyright (c) 2022 Xiaomi Corporation", url: "https://github.com/k2-fsa/kaldifst"),
        Acknowledgement(name: "OpenFst", detail: "1.8.5.", license: .apache2,
                        copyright: "Copyright 2005-2024 Google LLC", url: "https://www.openfst.org"),
        Acknowledgement(name: "simple-sentencepiece", detail: "0.7.", license: .apache2,
                        copyright: "Copyright 2024 Wei Kang", url: "https://github.com/pkufool/simple-sentencepiece"),
        Acknowledgement(name: "utf8proc", detail: "2.12.0. Its Unicode data is under the Unicode license.", license: .mit,
                        copyright: "Copyright (c) 2014-2021 Steven G. Johnson, Jiahao Chen, Tony Kelman, Jonas Fonseca, and other contributors\nCopyright (c) 2009, 2013 Public Software Group e. V., Berlin, Germany",
                        url: "https://github.com/JuliaStrings/utf8proc"),
        Acknowledgement(name: "JSON for Modern C++", detail: "3.12.0.", license: .mit,
                        copyright: "Copyright (c) 2013-2025 Niels Lohmann", url: "https://github.com/nlohmann/json"),
    ]

    static let models: [Acknowledgement] = [
        Acknowledgement(name: "zipformer2-66m-streaming-he", detail: "By Yakov Kolani, mirrored by ivrit.ai. Talk's live Hebrew transcript. Fine-tuned from icefall's streaming Zipformer (Apache-2.0) on ivrit.ai audio.",
                        license: .ccBy4, copyright: "© Yakov Kolani", url: "https://huggingface.co/thewh1teagle/zipformer2-66m-streaming-he",
                        changes: "The int8 sherpa-onnx files are unchanged; only their file names have the model's name in front."),
        Acknowledgement(name: "Smart Turn v3.2", detail: "smart-turn-v3.2-cpu.onnx, unchanged. Talk's end-of-turn check. A Whisper Tiny encoder (MIT, OpenAI) with a classifier.",
                        license: .bsd2, copyright: "Copyright (c) 2024–2025, Daily", url: "https://huggingface.co/pipecat-ai/smart-turn-v3"),
        Acknowledgement(name: "ivrit.ai whisper-large-v3-turbo", detail: "Voice typing. Quantized to q8_0 by this fork, the only change. A fine-tune of OpenAI's whisper-large-v3-turbo (MIT).",
                        license: .apache2, copyright: "ivrit.ai", url: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml"),
        Acknowledgement(name: "OpenAI Whisper", detail: "large-v3-turbo q5_0 and tiny q8_0, in ggml form from whisper.cpp.", license: .mit,
                        copyright: "Copyright (c) 2022 OpenAI", url: "https://github.com/openai/whisper"),
        Acknowledgement(name: "Silero VAD", detail: "v5.1.2, ggml form from whisper.cpp. Finds speech for voice typing and Talk.", license: .mit,
                        copyright: "Copyright (c) 2020-present Silero Team", url: "https://github.com/snakers4/silero-vad"),
        Acknowledgement(name: "RenikudPlus", detail: "Hebrew pronunciation for BlueTTS.", license: .apache2,
                        copyright: "notmax123", url: "https://huggingface.co/notmax123/RenikudPlus"),
        Acknowledgement(name: "BlueTTS 2.5", detail: "The voice model. Its authors declare no license.", license: .none,
                        copyright: "notmax123", url: "https://huggingface.co/notmax123/BlueTTS2.5-onnx"),
    ]
}

private struct AcknowledgementCard: View {
    let item: Acknowledgement
    @State private var showsText = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Text(verbatim: item.license.rawValue)
                        .font(.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(verbatim: item.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: item.copyright)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let changes = item.changes {
                    Text(verbatim: changes)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: item.url) {
                    Link(destination: url) {
                        Text(verbatim: item.url).font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    .tint(Theme.accent)
                }
                licenseText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var licenseText: some View {
        if let link = LicenseTexts.link(item.license) {
            Link(destination: link) {
                Text("License text").font(.caption.weight(.semibold))
            }
            .tint(Theme.accent)
        } else if let text = LicenseTexts.text(item.license, copyright: item.copyright) {
            DisclosureGroup(isExpanded: $showsText) {
                Text(verbatim: text)
                    .font(.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text("License text").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// License texts: MIT and BSD bodies under the component's copyright, the
/// Apache-2.0 text bundled with the app, links for CC BY 4.0 and the GPL.
enum LicenseTexts {
    static func link(_ license: Acknowledgement.License) -> URL? {
        switch license {
        case .ccBy4: URL(string: "https://creativecommons.org/licenses/by/4.0/legalcode")
        case .gpl3: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")
        default: nil
        }
    }

    static func text(_ license: Acknowledgement.License, copyright: String) -> String? {
        switch license {
        case .mit: copyright + "\n\n" + mit
        case .bsd2: copyright + "\n\n" + bsd2
        case .bsd3: copyright + "\n\n" + bsd3
        case .apache2: apache2
        case .ccBy4, .gpl3, .none: nil
        }
    }

    static let apache2: String? = Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    static let mit = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    static let bsd2 = """
    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """

    static let bsd3 = """
    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}
