# Cove

A private harbor for every AI model, native on your Mac.

Cove is a native macOS app (SwiftUI + AppKit) that puts cloud models (OpenAI, Anthropic, Google Gemini, OpenRouter, Mistral, Groq, any OpenAI-compatible endpoint) and local models (Ollama, LM Studio) behind one keyboard-first interface. It is local-first: chats live in SQLite on your Mac, API keys live in the Keychain, and requests go straight from your Mac to the provider.

This repository implements the **v0.1 MVP** scope of the PRD (§10).

## What's in v0.1

| PRD | Feature | Where |
|---|---|---|
| M1 | OpenAI-compatible, Anthropic and Gemini providers | `Packages/CoveProviders` |
| M2 | Auto-detects Ollama (`:11434`) and LM Studio (`:1234`) | `LocalModelDiscovery`, `ProviderRegistry` |
| M3 | Streaming with cancel (⌘.) and tokens/sec for local models | `ConversationEngine`, `ComposerView` |
| M4 | Per-chat model picker; default and quick-chat models | `ModelPicker`, Settings → General |
| C1 | Markdown, highlighted code with copy buttons, LaTeX (rendered to Unicode) | `Packages/CoveUI` |
| C2 | Edit, regenerate, branch navigation, fork into a new chat | message tree in `CoveStore` + `ChatViewModel` |
| C3 | Images, PDFs, text and code via drag and drop, paste or picker | `AttachmentProcessor` |
| C4 | Full-text search across all chats (FTS5) | `SearchRepository`, sidebar search |
| A1 | Prompt library with `{{selection}}`, `{{clipboard}}`, `{{date}}` | `PromptTemplate`, Settings → Prompts |
| T5 | `web_search` (Brave, Tavily, Kagi, Perplexity, You.com) and `fetch_url` | `Packages/CoveTools` |
| T8 | `generate_image` (OpenAI image models, saved as attachments) | `GenerateImageTool` |
| S1 | Global hotkey (⌥Space) opens a floating quick-chat panel | `FloatingPanel`, `QuickChatView` |
| S2 | Menu bar icon with recent chats and quick actions | `MenuBarContent` |
| S3 | Screenshot ask (⌥⇧S): select a region, chat opens with it attached | `ScreenCaptureService` |
| S6 | On-device dictation with Apple Speech | `DictationService` |
| D1 | All data in local SQLite; no account | `CoveStore` |
| D2 | Keys in the Keychain, plus an optional passphrase layer (AES-GCM + scrypt) | `KeychainSecretStore`, `PassphraseSecretStore` |
| L1 | Developer ID signing, notarization, Sparkle updates | `scripts/bundle-app.sh`, `.github/workflows/release.yml` |

Tool calls run through an approval gate. By default ("Ask for writes"), Cove asks before any tool that changes data, sends something, or costs money, and you can allow a tool for the rest of a chat. When the Mac is offline, cloud chats fail fast with a "Retry with a local model" button, and network tools are hidden from the model, which is told why.

## Layout

```
Package.swift            Shared libraries (build and test on macOS and Linux)
Packages/
  CoveModels/            Value types: messages, content parts, tools, providers
  CoveProviders/         LLMProvider + adapters, SSE, URLSession streaming, discovery
  CoveStore/             GRDB/SQLite schema, repositories, FTS5, attachments, secrets
  CoveTools/             Tool protocol, registry, approval gate, built-in tools
  CoveCore/              ConversationEngine, ContextBuilder, PromptTemplate, ProviderRegistry
  CoveUI/                Markdown parser, highlighter, LaTeX, SwiftUI components
  CoveSystem/            macOS: floating panel, screen capture, dictation, permissions
Apps/CoveMac/            The app (SwiftUI scenes, settings, Sparkle, KeyboardShortcuts)
Tests/ProviderFixtures/  Recorded streaming responses for provider replay tests
scripts/bundle-app.sh    Builds, signs and notarizes Cove.app
```

## Building

Requirements: macOS 14+, Xcode 16 (Swift 6 toolchain). The repository folder must be named `cove`, because the app package refers to the root package by path.

```bash
swift test                                        # libraries (works on Linux too)
swift build -c release --package-path Apps/CoveMac
scripts/bundle-app.sh                             # → dist/Cove.app (ad-hoc signed)
open dist/Cove.app
```

For a distributable build, set `CODESIGN_IDENTITY`, `SPARKLE_PUBLIC_KEY` and `NOTARY_PROFILE` (see the script header), or push a `v*` tag to run the release workflow.

First run:
1. Open **Settings → Models**. Add a cloud provider key, or start Ollama or LM Studio.
2. Optionally, pick a web search provider and add its key under **Settings → Tools**.
3. Press **⌥Space** anywhere for quick chat, or **⌥⇧S** to ask about a screenshot (this needs the Screen Recording permission).

## Known gaps and follow-ups

- **Not in v0.1:** Azure OpenAI and Bedrock (M6, P1) are stubbed. Agents, projects, MCP, Cove Command, context profiles and sync are later milestones.
- **LaTeX:** math renders to Unicode text, which works offline and needs no web view. Full typesetting (for example SwiftMath) is a follow-up.
- **Reasoning:** reasoning content is shown but not sent back across turns. Anthropic thinking signatures and Gemini thought signatures need an opaque field on `ContentPart`.
- **sqlite-vec:** not bundled yet. The `chunk_vec` table arrives with document Q&A (A3).
- **Search index:** the FTS table stores its own copy of each message's text (instead of the PRD's contentless table) so deletes and snippets work.
- **Passphrase KDF:** the passphrase layer uses scrypt, because swift-crypto has no Argon2id.
