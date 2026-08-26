# Inbox for iPhone

Native SwiftUI prototype built around one rule: **Get something into the app in at most two actions. The app sorts it.**

## v0.1

- Native iPhone app with SwiftUI
- Native iOS Share Extension: Share → Inbox
- Accepts text, URLs, screenshots/images, PDFs and files
- On-device OCR with Apple Vision
- PDF text extraction with PDFKit
- Automatic sorting into **Jetzt**, **Warten**, **Später**, **Ablage**
- Detects common German dates, weekdays and euro amounts
- Keeps the original image/PDF in the shared app container
- One-tap clipboard import inside the app
- No API key or cloud account required for this first prototype

## Open and run

1. Clone/download the repository on a Mac and open `inbox.xcodeproj` in Xcode.
2. Select target **Inbox** → Signing & Capabilities → choose your Apple Development Team.
3. Select target **InboxShareExtension** → choose the same Team.
4. Add/enable the App Group `group.de.knodelt.inbox` for **both targets**. The identifier must be identical in both targets.
5. If Xcode reports that `de.knodelt.Inbox` is already registered, change the bundle IDs for the app and extension to unique IDs you control.
6. Run **Inbox** on your iPhone or the Simulator.
7. In Safari, Photos, Files etc. tap **Share** and select **Inbox**.

> The Share Extension and the main app use an App Group because iOS isolates extensions from their containing apps. Depending on your Apple developer membership, App Groups may require an Apple Developer Program team rather than a free Personal Team.

## Structure

- `Inbox/InboxApp.swift` — SwiftUI app, list/detail UI and local app store
- `InboxShareExtension/ShareViewController.swift` — receives shared content, OCR/PDF extraction and automatic import
- `Shared/Shared.swift` — shared data model, App Group storage and analyzer
- `inbox.xcodeproj` — app + share-extension targets

## Current analyzer

v0.1 deliberately analyzes locally on-device. It uses extracted text plus deterministic rules to find action language, waiting states, dates and euro amounts. Low-confidence results get a question-mark marker so they can be corrected manually.

The next product step is a **secure server-side semantic analyzer** returning structured JSON (title, bucket, due date, amount, confidence), while keeping this local analyzer as an offline/privacy fallback. API secrets must never be stored inside the iPhone app.
