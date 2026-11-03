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
to use Melo for translation and Matcha for AI speech. The APK asset is pinned by byte length and
SHA-256, then verified before local extraction on first launch.

The model is licensed under BigScience OpenRAIL-M. The license text and its
use-based restrictions are available from the
[upstream model license](https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE).
The full upstream model license is bundled at `assets/legal/Supertonic-OpenRAIL-M.txt`.
The converted archive also retains an MIT notice; that converter notice does
not replace the upstream model license or its use-based restrictions.

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
is MIT, preserved at `assets/legal/Whisper-MIT.txt`. The conversion repository
has no separate model card; conversion provenance remains a release-review item. The app verifies each APK
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

## AI Chinese speech candidate (preview 68)

AI Chinese speech uses the author's Apache-2.0 Matcha model
`dengcunqin/matcha_tts_zh_en_20251010`, with the MIT-licensed Vocos vocoder.
Translation and face-to-face retain their existing providers; AI non-Chinese
speech uses Supertonic. The author declares Apache-2.0 for the acoustic model;
complete training-data provenance has not been independently established.

The r3 Matcha archive excludes eSpeak data. It includes full acoustic-model,
vocoder and CMUdict license texts, sources, Chinese normalization rules, and
CMUdict-derived English IPA. Unknown Latin words are spelled by letter instead
of silently skipped. The adjacent manifest pins archive size and SHA-256.
Synthetic native synthesis checks do not replace listening acceptance.

### Native runtime license boundary

This candidate uses `sherpa_onnx` 2.0.1. Upstream removed eSpeak NG and
piper-phonemize in [2.0.0](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v2.0.0).
Matcha uses supplied lexicons and normalization rules; Melo uses its supplied
lexicon. Neither config sets an eSpeak data directory. Older commits/APKs
retain their original components and require separate distribution review.
This change does not settle every third-party model's provenance by itself.

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
definitions and examples remain in English. The dictionary also includes separately sourced phonetic data; see the current
`assets/dictionary/SOURCES.md` and its bundled license files. It is not a
sentence translation engine.

## Bundled local image text recognition

Android image text recognition is provided by the bundled Google ML Kit text
recognition dependency. The app uses its bundled model and processes selected
images locally; it does not depend on a Play Services model download for this
feature. Refer to the dependency's upstream terms and notices when distributing
the APK.

## Application license and privacy

Original application source is Apache-2.0; third-party assets retain their own
licenses. `assets/legal/` contains the original-source license and additional
model notices. Google ML Kit is subject to its separate SDK terms and can
download models/updates and send performance/utilization metrics; on-device
inference is not a promise of network silence. See root `PRIVACY.md` and
https://developers.google.com/ml-kit/terms.
