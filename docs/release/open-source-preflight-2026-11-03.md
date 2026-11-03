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

## Preview68 follow-up evidence

Commit `ab557d946cdf60663654f4fb1e216965f607a0ff` was built in the independent
checkout above. Standard pub get and release arm64 build both exited 0;
assembleRelease took 79.6 seconds. This second build reused that checkout's
generated build cache; only the earlier baseline build started clean.

Final scan:49 commits,357 tracked paths,8 test-fixture candidates,0 unresolved
candidates,0 sensitive filenames. The three private-address matches are tests
for rejecting private-network page requests. No credential values were printed.

APK:2234874321 bytes; SHA-256
`dd02aca628a3581bb808f32bf47c2e7daf5edbee7ccf767b7bd9f32e2639ac29`.
Verified all8 legal assets against committed text, Matcha archive against its
manifest, and all3 sherpa native libraries against pinned2.0.1 package bytes
after the same NDK symbol stripping. No top-level eSpeak assets were present;
the Matcha archive inventory itself contains13 permitted model/lexicon/license
files and no eSpeak tree. This does not prove licensing of all historical APKs.

Fresh automated checks:229 Dart tests,10 web logic groups, browser suite all
passed. Selected Dart analysis returned16 existing info-level style findings
in the unchanged mobile shell, no warning/error; it was not a clean analyzer
exit. CMU converter4 tests passed. OPPO native synthesis with2.0.1,CMU lexicon
and all3 Chinese normalization rules passed mixed English, numeric Chinese and
spelled unknown-name samples without OOV errors. Listening acceptance remains
separate. The phone microphone was not opened for this work.
