# Inbox for iPhone

Native SwiftUI app built around one rule: **Get something into the app in at most two actions. The app understands and sorts it.**

## v0.3

- Native iPhone app with SwiftUI
- Native iOS Share Extension: **Share → Inbox → done**
- Accepts text, URLs, screenshots/images, PDFs and files
- On-device OCR with Apple Vision
- PDF text extraction with PDFKit
- Keeps the original screenshot/PDF through the shared App Group
- Automatic sorting into **Braucht dich**, **Demnächst**, **Warten** and **Ablage**
- Detects euro amounts and common German dates including forms such as `28. August 2026`
- Detects basic intent such as payment, invoice, reply, appointment, offer and delivery
- Improved merchant/person extraction: sentence fragments such as `steht an`, `ist fällig` or `bezahlen` are cut away from names
- Cleaner titles such as **Solakon bezahlen** instead of OCR-derived sentence fragments
- Compact detail screen with the important facts grouped together
- Existing saved items are re-analyzed once after updating to the new analyzer version
- Filters common screenshot/OCR interface noise before analysis
- Raw OCR text stays behind details instead of dominating the UI
- No API key or Cloudflare backend required for v0.3

## Open and run

1. Open `inbox.xcodeproj` in Xcode.
2. Select target **Inbox** → Signing & Capabilities → choose your Apple Development Team.
3. Select target **InboxShareExtension** → choose the same Team.
4. Keep App Group `group.de.knodelt.inbox` enabled for **both targets**. The identifier must be identical.
5. If Xcode reports that a bundle identifier is already registered, change the app and extension bundle IDs to unique IDs you control.
6. Select your iPhone and run **Inbox**.
7. In Photos, Mail, Safari or Files tap **Share → Inbox**.

## Development workflow

- Product/code changes can be committed directly to GitHub.
- Xcode is still required to compile, sign and install the native iPhone app on a device.
- After a GitHub update, use **Integrate → Pull** in the correctly cloned Xcode project and run the app again.
- Cloudflare is **not required** for the current local analyzer.

## When Cloudflare becomes useful

A Cloudflare Worker can be added later for a stronger semantic/AI analyzer, synchronization between devices, accounts, push/background workflows and email ingestion. API secrets should live server-side, never inside the iPhone app.

The intended long-term architecture is hybrid: **fast/private local extraction on the iPhone + optional server-side understanding when the local analyzer is not confident enough.**

## Structure

- `Inbox/InboxApp.swift` — assistant-style SwiftUI dashboard and compact detail UI
- `InboxShareExtension/ShareViewController.swift` — receives shared content, OCR/PDF extraction and direct import
- `Shared/Shared.swift` — shared data model, App Group storage and local analyzer
- `inbox.xcodeproj` — app + share-extension targets
