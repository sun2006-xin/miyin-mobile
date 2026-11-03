# Third-party notices

## Bundled Chinese title font

The appearance page bundles the Noto Serif SC variable font for Chinese
headings. Noto Serif CJK is developed by Google and Adobe and is nearly
identical in design to Source Han Serif. The font is available under the
[SIL Open Font License 1.1](https://github.com/notofonts/noto-cjk/blob/main/Serif/LICENSE).
The license text is included at `assets/miyin_v5/fonts/OFL.txt`.

Bundled file: `assets/miyin_v5/fonts/NotoSerifSC-VF.ttf`.
SHA-256: `A4AED9985A5916FBF6690456F8732A9FCCD517938E353165D4142B4F11A39280`.

## Chinese and English speech recognition model

觅音 bundles the `k2fsa-zipformer-bilingual-zh-en-t` streaming model from
[Hugging Face](https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t).
The model card declares the model as Apache-2.0. Its upstream description
identifies it as a community-contributed Chinese-English streaming ASR model.
The sherpa-onnx model documentation lists the small bilingual Chinese/English
model and the int8 encoder/joiner with an FP32 decoder used here:
[model documentation](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html).

The distributed model files are stored in `assets/voice/asr-zh-en/`. They are
run locally on the device; recorded microphone audio is not uploaded by this
recognition path.

SHA-256 checksums:

| File | SHA-256 |
| --- | --- |
| `encoder-epoch-99-avg-1.int8.onnx` | `DB6F51551762E40E549166FE041EA3E45464370B595E9AD23F06478EC3794FBB` |
| `decoder-epoch-99-avg-1.onnx` | `89BE509A83175261695BDEF5FD1C7B9AB1129A663D1284E7BA9F8507B21E0906` |
| `joiner-epoch-99-avg-1.int8.onnx` | `BDDA356D6F9B8C2D7CEE9EE0E26075FA537490F7FD06520BE408D287073667B9` |

The Apache License 2.0 text is included in `licenses/Apache-2.0.txt`.

## Bundled multilingual multi-speaker speech synthesis model

The Supertonic 3 int8 TTS model is bundled in the APK from the
[sherpa-onnx model release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models).
The upstream model card lists 31 languages and the sherpa-onnx interface
exposes ten speaker IDs. The model does not include Chinese; Chinese continues
to use the bundled Melo VITS voice. The APK asset is pinned by byte length and
SHA-256, then verified before local extraction on first launch.

The model is licensed under BigScience OpenRAIL-M. The license text and its
use-based restrictions are available from the
[upstream model license](https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE).
The app links to its full text. Bundling this model does not change the
separate native-runtime license boundary described below.

## English speech recognition model

The English-only
`sherpa-onnx-streaming-zipformer-en-2023-06-26` model distributed by
[sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html).
The upstream model card declares Apache-2.0 and identifies it as an English
streaming model trained on LibriSpeech. Its files are retained in the source
tree under `assets/voice/asr-en-66m/` for comparison, but are not bundled or
loaded by the current app, which uses one bilingual model for both languages.

SHA-256 checksums:

| File | SHA-256 |
| --- | --- |
| `encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx` | `5022B2ECA5B19D1BC104FCF33E26BC32604B7DF553CD2E1F62E31DC7B05E9C87` |
| `decoder-epoch-99-avg-1-chunk-16-left-128.onnx` | `85914F840B71110487ECE7A30EBD0BD4B8FB5C2623215BBA3AA5AB4C138FC591` |
| `joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx` | `ABD5E30F3F16FC510605C6029DBA33F10E4386BD75C5BDC30CF94076864DB10D` |
| `tokens.txt` | `49E3C2646595FD907228B3C6787069658F67B17377C60AEB8619C4551B2316FB` |
| `bpe.model` | `C53433DE083C4A6AD12D034550EF22DE68CEC62C4F58932A7B6B8B2F1E743FA5` |

## Bundled multilingual speech recognition model

The current review APK trials the int8 multilingual `base` Whisper ONNX files
from [the sherpa-onnx Whisper Base model repository](https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/tree/main).
The upstream [OpenAI Whisper license](https://github.com/openai/whisper/blob/main/LICENSE)
is MIT. The conversion repository has no separate model card; its distribution
terms need final review before a public release. The app verifies each APK
asset's expected byte length and SHA-256 before copying it into application
support on first launch. It is included in the installed app and is not
managed as a user download.

| File | SHA-256 |
| --- | --- |
| `base-encoder.int8.onnx` | `0B8FB1304B6109976038EFFF5ACE81720E00386F3FF6B54EE8C75291CA0A1E11` |
| `base-decoder.int8.onnx` | `9759D217388A01B3A4C7C15533201067B48AE819C4DAAFC8624E64B9409DC02D` |
| `base-tokens.txt` | `B34B360DBB493E781E479794586D661700670D65564001F23024971D1F2FA126` |

The sherpa-onnx Whisper integration is non-streaming: it returns its final
transcription after the user releases the microphone. An empty Whisper
language hint asks sherpa-onnx to infer the spoken language.

## Chinese and English speech synthesis model

The APK bundles `vits-melo-tts-zh_en`, converted from MyShell MeloTTS and
published in the sherpa-onnx model releases. The upstream archive includes a
MIT license, preserved at `assets/voice/tts-melo-zh-en/LICENSE`. The files
prepared locally on first use are listed in
`assets/voice/tts-melo-zh-en/asset-manifest.json`.

The upstream model documentation describes this as one Chinese-and-English
speaker at 44.1 kHz. It also states that English words missing from the model's
`lexicon.txt` cannot be pronounced. The app therefore offers one built-in
female voice shared by both languages and a speed control, not selectable
voices.

Model SHA-256 checksums:

| File | SHA-256 |
| --- | --- |
| `model.onnx` | `BF30582EB1B012250A35B1A4A80E7DFBCF8485E7BB9DE0D95EFBBEEF0E4AD86D` |
| `lexicon.txt` | `7236884B02435AC5D10CF69B4BE40A61B45AA676B5300F0E412F185748FEE528` |

## AI Chinese speech candidate (preview 60)

AI Chinese speech additionally uses `matcha-icefall-zh-en`, converted from
`dengcunqin/matcha_tts_zh_en_20251010`, with `vocos-16khz-univ.onnx`. The model
has one speaker at 16 kHz and declares Chinese/English support; this app routes
only AI Chinese speech to it. Translation and face-to-face speech retain their
existing provider selection, and AI non-Chinese speech uses Supertonic.

The author declares Apache-2.0 for the model. This is not a claim that the
complete training-data provenance has been independently established. Source
URLs, per-file hashes, Apache-2.0 and GPL-3.0 texts are retained inside
`assets/voice/tts-matcha-zh-en/matcha-zh-en.tar.gz`; the adjacent manifest records
the archive hash and extracted paths/sizes. This archive includes eSpeak NG
data required by the current Matcha frontend. Its license and the native-runtime
boundary below must be reviewed for public distribution independently of the
application's own license.

### Native runtime license boundary

The Flutter app still depends on `sherpa_onnx` 1.13.8. Although sherpa-onnx is
Apache-2.0, the Android native runtime contains eSpeak NG / piper-phonemize
components identified by the upstream project as GPL-licensed dependencies.
The Melo VITS configuration uses the model's supplied lexicon and does not
configure eSpeak data. The AI Matcha candidate described above does bundle and
configure eSpeak data. Neither configuration removes those components from
the packaged native library. The sherpa-onnx maintainers track their
removal for a future major version in
[issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731).

The old Kokoro model is no longer bundled. The model changes do not by
themselves settle redistribution obligations for the current prebuilt
native library or the newly bundled data. Keep public APK distribution gated on a reviewed source and
license package, or on replacing that runtime with a build that excludes the
GPL components.

## Offline English–Chinese dictionary

The app bundles `assets/dictionary/en-zh-cow-wordnet-3.0.jsonl`, a generated
exact-headword lookup table joining Chinese Open Wordnet (COW) equivalents to
Princeton WordNet 3.0 synsets. The source versions, checksums, generation
method, coverage, and known limitations are documented in
`assets/dictionary/SOURCES.md`. The complete upstream license texts are also
bundled at `assets/dictionary/LICENSE-COW.txt` and
`assets/dictionary/LICENSE-WordNet-3.0.txt`.

This data is a compact lexical reference, not a complete bilingual learner's
dictionary. Chinese entries are source word equivalents aligned by synset;
definitions and examples remain in English. The current search is exact
headword lookup after case and whitespace normalization. It does not provide
phonetics, inflection lookup, fuzzy matching, or sentence translation.

## Bundled local image text recognition

Android image text recognition is provided by the bundled Google ML Kit text
recognition dependency. The app uses its bundled model and processes selected
images locally; it does not depend on a Play Services model download for this
feature. Refer to the dependency's upstream terms and notices when distributing
the APK.
