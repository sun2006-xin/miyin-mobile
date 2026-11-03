# Privacy and local processing

Miyin stores conversation history, translation history, selected images and
recordings on the device. Delete controls in the app manage those records.
Exported files and files saved to shared phone storage must also be managed
with the phone's file manager. Uninstalling the app does not necessarily delete
files exported to shared storage.

Bundled speech recognition, speech synthesis and the on-device chat model run
locally. Selecting a remote chat provider sends the request to that provider.
Its policy, billing and retention settings apply. The app's privacy controls
determine whether conversation context is attached and whether local history
is saved. API credentials must not be included in issue reports or screenshots.

Web search and page reading contact internet services. Search queries and the
requested page address become visible to the relevant services. A link supplied
to the model does not make that service part of Miyin's local processing path.

Google ML Kit performs translation and image text recognition on the device.
Its SDK can contact Google to obtain updates or language models and can send
performance and utilization metrics. Local inference does not mean that every
SDK is network silent. See [Google ML Kit terms](https://developers.google.com/ml-kit/terms)
and [Google Privacy Policy](https://policies.google.com/privacy).

Screen capture, microphone capture and other-app audio capture require Android
permissions or system consent. Recording may include other people's voices and
screen contents; choose what to record and share carefully. App-generated
recordings remain local unless you explicitly export or share them.

This document describes the application paths above. It does not replace the
policies of Android, the device manufacturer, or a user-selected online provider.
