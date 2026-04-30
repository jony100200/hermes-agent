export type AgentLifecycleStatus = "stopped" | "starting" | "ready" | "running" | "error";

export type ToolTarget = "local" | "docker" | "modal" | "daytona" | "ssh";

export interface DesktopSettings {
  hermesRepoPath: string;
  hermesEntryPath: string;
  pythonExecutable: string;
  devToolsPath: string;
  workspacePath: string;
  apiEndpoint: string;
  defaultModel: string;
  defaultProvider: string;
  defaultToolTarget: ToolTarget;
  verboseLogs: boolean;
}

export interface SettingsResponse {
  settings: DesktopSettings;
  issues: string[];
}

export interface ChatRunRequest {
  prompt: string;
  model?: string;
  provider?: string;
  toolTarget?: ToolTarget;
  sessionId?: string;
  verbose?: boolean;
}

export interface ChatRunAck {
  requestId: string;
}

export interface AgentLogPayload {
  requestId: string;
  stream: "stdout" | "stderr" | "system";
  chunk: string;
  timestamp: number;
}

export interface AgentResultPayload {
  requestId: string;
  exitCode: number | null;
  output: string;
  errorOutput: string;
  finalResponse: string;
  success: boolean;
  durationMs: number;
}

export interface AgentStatusPayload {
  lifecycle: AgentLifecycleStatus;
  started: boolean;
  runningRequestId: string | null;
  lastExitCode: number | null;
  lastError: string;
}
