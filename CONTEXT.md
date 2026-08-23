# Domain Glossary

## Brand
**Notable**. User-facing product name for the app (titles, README, UI chrome, docs). Production host may remain Feedback-named (for example `feedback.rizafahmi.com`); that hostname is not the brand.

## Note
A message sent by a viewer to a streamer. Always has a sender name and message body. May optionally include a monetary tip. In the database this is stored as a `Donation` record — the schema name is a legacy of the donation-first design and does not reflect the current product framing.

## Tip
An optional monetary amount attached to a Note. Denominated in IDR. When present, triggers the Mayar QRIS payment flow. When absent, the Note is persisted immediately without payment processing.

## Sender
A viewer who submits a Note. Previously called "Donor." Does not require an account.

## Reaction
A mandatory emoji selection that categorizes a Note. One of four sentiments: bad, ok, good, great. Every Note must have exactly one Reaction. Reactions are the primary visual element on the overlay.

### Emoji Pools
Each sentiment maps to a pool of emoji. The overlay randomly picks one from the pool per display:
- **bad**: 😅 🫠 💤 🙈
- **ok**: 😐 🤔 😶 🫤
- **good**: 😊 👍 🙌 💪
- **great**: 🤩 🔥 🎉 ⭐

### Float Behavior
- Emoji appears at a random position on the overlay
- Floats toward a random destination with organic, non-linear movement
- Duration: 3–4 seconds per emoji
- Multiple emojis can be on screen simultaneously (no queuing)
- Emoji-only — no sender name or message text on the tip/reaction overlay
- Sender name and full message remain on `/admin`; free-feedback message text is also tokenized onto the closing-slide word cloud at `/cloud` and `/cloud-overlay` under display-time safety rules (see [AGENTS.md](AGENTS.md) Guidelines and [Milestone 16](docs/milestones/16-feedback-word-cloud/milestone-log.md))

## Streamer
The single user who receives Notes and optional Tips. Also called "Host."

## Overlay Modes
The single `/overlay` route renders two visual modes within one OBS browser source:
- **Floating Reactions**: Emoji bubbles that float and fade for feedback-only Notes (no tip). Ambient, lightweight, continuous.
- **Celebration Alert**: The existing full-screen alert (name, amount, message, confetti, sound) for confirmed Tips. Rare, high-impact, sequential.

## Feedback
Synonym for Note in user-facing copy. The product frames the interaction as "send feedback" rather than "make a donation."

## Appreciation
The act of attaching a Tip to a Note. User-facing copy uses "show appreciation" rather than "donate."
