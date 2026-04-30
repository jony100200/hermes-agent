import { app, BrowserWindow, dialog, ipcMain, OpenDialogOptions } from "electron";
import { join } from "node:path";
import { ConfigStore } from "./config-store";
import { HermesRunner } from "./hermes-runner";
import { ChatRunRequest, DesktopSettings } from "./types";

const store = new ConfigStore();
const runner = new HermesRunner();
let mainWindow: BrowserWindow | null = null;

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1500,
    height: 920,
    minWidth: 1100,
    minHeight: 720,
    backgroundColor: "#0e1116",
    webPreferences: {
      preload: join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });

  mainWindow.setMenuBarVisibility(false);

  if (process.env.ELECTRON_RENDERER_URL) {
    mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    mainWindow.loadFile(join(__dirname, "../renderer/index.html"));
  }

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

function wireRunnerEvents(): void {
  runner.on("log", (payload) => {
    mainWindow?.webContents.send("desktop:agent:log", payload);
  });

  runner.on("result", (payload) => {
    mainWindow?.webContents.send("desktop:agent:result", payload);
  });

  runner.on("status", (payload) => {
    mainWindow?.webContents.send("desktop:agent:status", payload);
  });
}

function wireIpcHandlers(): void {
  ipcMain.handle("desktop:settings:get", () => {
    return store.load();
  });

  ipcMain.handle("desktop:settings:save", (_event, partial: Partial<DesktopSettings>) => {
    return store.save(partial);
  });

  ipcMain.handle("desktop:path:pick", async (_event, kind: "file" | "directory") => {
    const options: OpenDialogOptions = {
      properties: kind === "directory" ? ["openDirectory"] : ["openFile"]
    };

    const result = mainWindow
      ? await dialog.showOpenDialog(mainWindow, options)
      : await dialog.showOpenDialog(options);

    if (result.canceled || result.filePaths.length === 0) {
      return null;
    }

    return result.filePaths[0];
  });

  ipcMain.handle("desktop:agent:start", async () => {
    const settings = store.load().settings;
    return runner.start(settings);
  });

  ipcMain.handle("desktop:agent:stop", () => {
    return runner.stop();
  });

  ipcMain.handle("desktop:agent:status", () => {
    return runner.getStatus();
  });

  ipcMain.handle("desktop:chat:send", async (_event, request: ChatRunRequest) => {
    const settings = store.load().settings;
    return runner.runPrompt(settings, request);
  });

  ipcMain.handle("desktop:chat:cancel", () => {
    return {
      cancelled: runner.cancelActiveRun("Run cancelled from UI."),
      status: runner.getStatus()
    };
  });
}

app.whenReady().then(() => {
  wireRunnerEvents();
  wireIpcHandlers();
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
