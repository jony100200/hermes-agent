# Hermes Desktop UI (Windows-first prototype)

This is a desktop shell for Hermes Agent using Electron + React.

It controls Hermes through CLI calls and does not reimplement Hermes logic.

## Goals delivered

- Open WebUI-inspired layout
  - Left sessions sidebar
  - Main chat panel
  - Right live logs/checklist panel
- Machine-local configuration
  - No hardcoded absolute paths
  - Per-machine settings stored in app data
- Hermes execution control
  - Start/stop/cancel
  - Model/provider/tool target controls
  - Status indicator
- Voice input
  - Uses SpeechRecognition API where available
  - Falls back gracefully when unavailable
- End-to-end chat flow
  - User prompt -> Hermes CLI run -> streamed logs -> final response

## Tech stack

- Electron
- electron-vite
- React + TypeScript
- Native IPC bridge (preload + contextBridge)

## Reference inspiration

- hermes-desktop
- Open WebUI (interaction style and panel layout)
- AionUi Electron structure patterns

## File structure

```text
desktop-ui/
  package.json
  electron.vite.config.ts
  tsconfig.json
  src/
    main/
      index.ts              # Electron main process + IPC handlers
      config-store.ts       # machine-local settings load/save/validate
      hermes-runner.ts      # Hermes CLI process control + streaming
      types.ts
    preload/
      index.ts              # safe renderer API surface
    renderer/
      index.html
      src/
        main.tsx
        App.tsx             # chat UI, sessions, settings, logs panel
        styles.css
        types.ts
```

## Machine-local config model

Settings are saved to:

- `%APPDATA%` equivalent Electron userData path
- file: `hermes-desktop-ui.settings.json`

Configurable fields:

- Hermes repo path
- Hermes entry path (optional override)
- Python executable (optional override)
- DevTools path (optional)
- workspace/output folder
- API endpoint (optional)
- default model/provider/tool target
- verbose log mode

## Run locally

From repo root:

```powershell
cd desktop-ui
npm install
npm run dev
```

Build:

```powershell
npm run build
npm run preview
```

## First machine setup

1. Open Settings in the app on first launch.
2. Set Hermes repo path for this machine.
3. Optionally set Python executable and workspace path.
4. Save settings.
5. Click Start.

## First test flow

Prompt:

Create a simple Python hello world script and run it

Expected UI behavior:

1. User message appears in chat.
2. Hermes run starts and status changes to Running.
3. Live logs stream in right panel.
4. Assistant response appears with parsed plan/checklist/final result sections when present.
5. Run completes with exit code and duration note.

## Notes

- This prototype uses Hermes CLI invocation (`hermes chat -q ...`) under the configured Python executable.
- If microphone input is unavailable, use Windows speech typing (`Win + H`) as fallback.
- If provider keys are missing, Hermes run will fail and errors are surfaced in logs and status.
