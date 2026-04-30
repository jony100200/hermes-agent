import { app } from "electron";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DesktopSettings, SettingsResponse } from "./types";

const DEFAULT_SETTINGS: DesktopSettings = {
  hermesRepoPath: "",
  hermesEntryPath: "",
  pythonExecutable: "",
  devToolsPath: "",
  workspacePath: "",
  apiEndpoint: "",
  defaultModel: "",
  defaultProvider: "",
  defaultToolTarget: "local",
  verboseLogs: true
};

function normalizeSettings(input?: Partial<DesktopSettings>): DesktopSettings {
  return {
    ...DEFAULT_SETTINGS,
    ...(input ?? {})
  };
}

export function resolveHermesEntryPath(settings: DesktopSettings): string {
  if (settings.hermesEntryPath.trim()) {
    return settings.hermesEntryPath.trim();
  }

  if (settings.hermesRepoPath.trim()) {
    const localEntry = join(settings.hermesRepoPath.trim(), "hermes");
    if (existsSync(localEntry)) {
      return localEntry;
    }
  }

  return "hermes";
}

export function resolvePythonPath(settings: DesktopSettings): string {
  if (settings.pythonExecutable.trim()) {
    return settings.pythonExecutable.trim();
  }

  if (settings.hermesRepoPath.trim()) {
    const candidates = [
      join(settings.hermesRepoPath.trim(), ".venv", "Scripts", "python.exe"),
      join(settings.hermesRepoPath.trim(), "venv", "Scripts", "python.exe")
    ];

    for (const candidate of candidates) {
      if (existsSync(candidate)) {
        return candidate;
      }
    }
  }

  return "python";
}

export function validateSettings(settings: DesktopSettings): string[] {
  const issues: string[] = [];
  const repo = settings.hermesRepoPath.trim();

  if (!repo) {
    issues.push("Hermes repo path is required.");
  } else if (!existsSync(repo)) {
    issues.push("Hermes repo path does not exist.");
  }

  if (settings.hermesEntryPath.trim() && !existsSync(settings.hermesEntryPath.trim())) {
    issues.push("Custom Hermes entry path does not exist.");
  }

  if (settings.pythonExecutable.trim() && !existsSync(settings.pythonExecutable.trim())) {
    issues.push("Custom Python executable path does not exist.");
  }

  if (settings.workspacePath.trim() && !existsSync(settings.workspacePath.trim())) {
    issues.push("Workspace/output path does not exist.");
  }

  if (settings.devToolsPath.trim() && !existsSync(settings.devToolsPath.trim())) {
    issues.push("DevTools path does not exist.");
  }

  const autoHermesPath = resolveHermesEntryPath(settings);
  if (autoHermesPath !== "hermes" && !existsSync(autoHermesPath)) {
    issues.push("Hermes entry script is missing in the repo path.");
  }

  return issues;
}

export class ConfigStore {
  private readonly configPath: string;
  private settingsCache: DesktopSettings | null = null;

  constructor() {
    this.configPath = join(app.getPath("userData"), "hermes-desktop-ui.settings.json");
  }

  load(): SettingsResponse {
    if (this.settingsCache) {
      return {
        settings: this.settingsCache,
        issues: validateSettings(this.settingsCache)
      };
    }

    if (!existsSync(this.configPath)) {
      this.settingsCache = normalizeSettings();
      return {
        settings: this.settingsCache,
        issues: validateSettings(this.settingsCache)
      };
    }

    try {
      const raw = readFileSync(this.configPath, "utf-8");
      const parsed = JSON.parse(raw) as Partial<DesktopSettings>;
      this.settingsCache = normalizeSettings(parsed);
    } catch {
      this.settingsCache = normalizeSettings();
    }

    return {
      settings: this.settingsCache,
      issues: validateSettings(this.settingsCache)
    };
  }

  save(partial: Partial<DesktopSettings>): SettingsResponse {
    const current = this.load().settings;
    const next = normalizeSettings({ ...current, ...partial });

    mkdirSync(dirname(this.configPath), { recursive: true });
    writeFileSync(this.configPath, JSON.stringify(next, null, 2), "utf-8");

    this.settingsCache = next;

    return {
      settings: next,
      issues: validateSettings(next)
    };
  }
}
