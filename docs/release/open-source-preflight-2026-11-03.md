# Open-source preflight evidence, 2026-11-03

This is a preparation record, not a public release announcement.

## Original-source license

The owner selected Apache-2.0. Root `LICENSE` contains the full canonical text;
`NOTICE` identifies the original application source and distinguishes third-party
components, models, fonts and data. These assets retain their own terms.

## Baseline clean build

Source commit: `36e18d04472faa87f37a5263d66ca525cedacd88`.
A separate checkout at `D:/MiyinOpenSourceVerify/20261103-68` was created with
`git clone --no-hardlinks --no-checkout`, then checked out at that commit.
No development output directory or private Gradle initialization script was
copied. Ten LFS objects were restored from the local Git LFS object store.

With Flutter 3.47.2 and `PUB_CACHE=D:/DevTools/pub-cache-miyin`:

```
flutter pub get
flutter build apk --release --target-platform android-arm64
```

Both commands returned exit code 0. Standard Flutter generated the required
Android build scaffolding. Gradle assembleRelease completed in 218.3 seconds;
Flutter reported an arm64 APK of 2138.8 MB. The existing package cache was reused.
This proves this baseline builds without untracked project files; it does not
prove remote GitHub LFS availability or a completely empty dependency cache.
The subsequent speech-runtime migration requires another clean build before
its candidate can inherit this result.

## Public-content audit

The local redacting scanner inspected all locally reachable Git refs at the
baseline: 48 commits, 5 tags, 643 blobs, 340 tracked paths. It also inspected
bounded text members of locally available LFS archives. Eight credential-like
candidates were reviewed: all occurred in test fixtures (reserved example
addresses or fake keys); no unresolved candidate remained in that run.
No sensitive credential filenames were found. Four tracked UI preview images
were visually reviewed and contained synthetic examples rather than recordings
or credentials. Commit metadata and third-party notices contain email addresses;
publication exposes the selected history's authorship metadata.

This is a bounded pattern audit, not proof that no private data exists. Large
model binaries, untracked files, unreachable/reflog-only objects and remote-only
refs were excluded. Audio was not listened to. Newly added or changed files must
be scanned in the final public snapshot as well.

## Native speech migration in progress

The old sherpa_onnx 1.13.8 runtime and Matcha archive included eSpeak-related
components. The candidate moves to 2.0.1 following upstream's removal in 2.0.0.
The first migration test exposed skipped English words in mixed Chinese speech.
A CMUdict-derived IPA lexicon now covers 124101 English entries; known words
pass a native OPPO synthetic synthesis check without the former OOV errors.
Unknown English names use letter spelling instead of silently disappearing.
Chinese date/number/phone normalization rules are restored from the model
package. The candidate archive excludes eSpeak data and retains separate model,
vocoder and CMUdict license texts. Automated and listening acceptance are
separate; no broad claim of unchanged voice quality is made here.

## Remaining release gates

- Finish current runtime regression, resource inventory and final clean build.
- Make all third-party license texts accessible in the public source and APK.
- Verify the final public source snapshot, LFS download path and APK checksums.
- Decide the published history scope: older commits still retain older runtime
  and resource artifacts. No history rewrite or visibility change was performed.
- Use a stable release signing plan; do not commit private signing material.

No push, public visibility change or public APK release occurred in this preflight.
