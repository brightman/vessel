# WiseLife global launch preview

Open http://localhost:8789/launch-preview/index.html while the local website preview server is running.

Independent English homepage based on the user-provided ChatGPT design brief. The public homepage files and Tencent deployment are not replaced by this preview.

## Files

- `index.html`, `launch.css`, `launch.js`: eight-section responsive homepage.
- `assets/`: natural workspace photograph and captures of actual product prototypes.
- `demos/iphone.html`, `demos/watch.html`: copies of the existing demos with return navigation. Their styles/scripts reference the website root.
- `demos/mac/`: local copy of the Companion prototype, with knowledge base and month-calendar selection.

## Interactions

Device tabs, planned Today sample-context details, memory → grounded answer → editable reminder preview, privacy data routes, hardware compatibility, video playback, launch form validation and interest selection. Also supports keyboard navigation, native dialogs, dark appearance and reduced motion.

The email form never sends, logs or stores an email. Its completion state explicitly says this is a preview. Action confirmation changes demo state only. The Today experience is marked as a product vision, not a shipping feature or medical assessment.

## Content and asset limits

- English homepage is provided in this iteration. Chinese and Japanese remain a future localization step.
- Existing 27-second demo is used at its actual duration. A new 60-second film and real Watch recording footage are not fabricated.
- Image generation was unavailable due to Canva reauthentication. The hero combines real prototype screenshots with an existing stock office scene; it is not presented as live-device proof.
- Companion currently has a light UI in the actual prototype. That UI is preserved rather than substituting a fabricated dark screenshot.
- App, Mac and Ring availability are shown separately. Ring integration does not imply that its crowdfunding or hardware sales are open.

Source brief: `../docs/global-launch-source.md`. Design notes: `../docs/global-launch-design.md`.
Verification: `../docs/verification/global-launch/results.json` and screenshots.
