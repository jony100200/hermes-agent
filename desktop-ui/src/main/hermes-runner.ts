import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { AgentLogPayload, AgentResultPayload, AgentStatusPayload, ChatRunRequest, DesktopSettings } from "./types";
import { resolveHermesEntryPath, resolvePythonPath } from "./config-store";

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

function normalizeChunk(data: Buffer | string): string {
  return data.toString("utf-8");
}

export class HermesRunner extends EventEmitter {
  private processRef: ReturnType<typeof spawn> | null = null;
  private started = false;
  private lifecycle: AgentStatusPayload["lifecycle"] = "stopped";
  private runningRequestId: string | null = null;
  private lastExitCode: number | null = null;
  private lastError = "";

  getStatus(): AgentStatusPayload {
    return {
      lifecycle: this.lifecycle,
      started: this.started,
      runningRequestId: this.runningRequestId,
      lastExitCode: this.lastExitCode,
      lastError: this.lastError
    };
  }

  async start(settings: DesktopSettings): Promise<AgentStatusPayload> {
    if (this.started) {
      return this.getStatus();
    }

    this.lifecycle = "starting";
    this.emitStatus();

    const pythonPath = resolvePythonPath(settings);
    const hermesEntry = resolveHermesEntryPath(settings);
    const cwd = settings.hermesRepoPath.trim() || process.cwd();

    const result = await this.runQuickCommand(pythonPath, [hermesEntry, "--version"], cwd, this.buildEnv(settings, "local"));

    this.lastExitCode = result.exitCode;
    if (result.exitCode === 0) {
      this.started = true;
      this.lifecycle = "ready";
      this.lastError = "";
    } else {
      this.started = false;
      this.lifecycle = "error";
      this.lastError = (result.stderr || result.stdout || "Failed to start Hermes").trim();
    }

    this.emitStatus();
    return this.getStatus();
  }

  stop(): AgentStatusPayload {
    this.cancelActiveRun("Agent stopped by user.");
    this.started = false;
    this.lifecycle = "stopped";
    this.emitStatus();
    return this.getStatus();
  }

  cancelActiveRun(reason = "Active run cancelled."): boolean {
    if (!this.processRef) {
      return false;
    }

    const activePid = this.processRef.pid;
    if (process.platform === "win32") {
      spawn("taskkill", ["/PID", String(activePid), "/T", "/F"], {
        windowsHide: true,
        stdio: "ignore"
      });
    } else {
      this.processRef.kill("SIGTERM");
    }

    this.emit(
      "log",
      {
        requestId: this.runningRequestId ?? "",
        stream: "system",
        chunk: reason,
        timestamp: Date.now()
      } satisfies AgentLogPayload
    );

    return true;
  }

  async runPrompt(settings: DesktopSettings, request: ChatRunRequest): Promise<{ requestId: string }> {
    if (this.processRef) {
      throw new Error("Another run is already active. Stop or wait for completion.");
    }

    if (!this.started) {
      const status = await this.start(settings);
      if (status.lifecycle !== "ready") {
        throw new Error(status.lastError || "Hermes is not ready.");
      }
    }

    const requestId = randomUUID();
    const startedAt = Date.now();
    const pythonPath = resolvePythonPath(settings);
    const hermesEntry = resolveHermesEntryPath(settings);

    const effectiveModel = request.model?.trim() || settings.defaultModel.trim();
    const effectiveProvider = request.provider?.trim() || settings.defaultProvider.trim();
    const effectiveTarget = request.toolTarget ?? settings.defaultToolTarget;

    const args: string[] = [
      hermesEntry,
      "chat",
      "-q",
      request.prompt,
      "--yolo",
      "--accept-hooks"
    ];

    if (request.verbose ?? settings.verboseLogs) {
      args.push("-v");
    } else {
      args.push("-Q");
    }

    if (effectiveModel) {
      args.push("-m", effectiveModel);
    }

    if (effectiveProvider) {
      args.push("--provider", effectiveProvider);
    }

    const cwd = settings.workspacePath.trim() || settings.hermesRepoPath.trim() || process.cwd();
    const env = this.buildEnv(settings, effectiveTarget);

    const child = spawn(pythonPath, args, {
      cwd,
      env,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"]
    });

    this.processRef = child;
    this.runningRequestId = requestId;
    this.lifecycle = "running";
    this.emitStatus();

    let stdoutBuffer = "";
    let stderrBuffer = "";

    child.stdout.on("data", (chunk) => {
      const text = normalizeChunk(chunk);
      stdoutBuffer += text;
      this.emit(
        "log",
        {
          requestId,
          stream: "stdout",
          chunk: text,
          timestamp: Date.now()
        } satisfies AgentLogPayload
      );
    });

    child.stderr.on("data", (chunk) => {
      const text = normalizeChunk(chunk);
      stderrBuffer += text;
      this.emit(
        "log",
        {
          requestId,
          stream: "stderr",
          chunk: text,
          timestamp: Date.now()
        } satisfies AgentLogPayload
      );
    });

    child.on("error", (error) => {
      this.lastError = String(error.message || error);
      this.lifecycle = "error";
      this.emitStatus();
    });

    child.on("close", (code) => {
      this.lastExitCode = code;
      this.runningRequestId = null;
      this.processRef = null;

      const cleanOut = stripAnsi(stdoutBuffer);
      const cleanErr = stripAnsi(stderrBuffer);
      const finalResponse = cleanOut.trim() || cleanErr.trim();
      const success = code === 0;

      if (!success && !cleanErr.trim()) {
        this.lastError = cleanOut.trim() || "Hermes command failed.";
      } else if (!success) {
        this.lastError = cleanErr.trim();
      } else {
        this.lastError = "";
      }

      this.lifecycle = this.started ? "ready" : "stopped";
      this.emitStatus();

      this.emit(
        "result",
        {
          requestId,
          exitCode: code,
          output: cleanOut,
          errorOutput: cleanErr,
          finalResponse,
          success,
          durationMs: Date.now() - startedAt
        } satisfies AgentResultPayload
      );
    });

    return { requestId };
  }

  private emitStatus(): void {
    this.emit("status", this.getStatus());
  }

  private buildEnv(settings: DesktopSettings, toolTarget: string): NodeJS.ProcessEnv {
    const env = { ...process.env };

    if (toolTarget && toolTarget !== "local") {
      env.TERMINAL_ENV = toolTarget;
    } else {
      delete env.TERMINAL_ENV;
    }

    if (settings.apiEndpoint.trim()) {
      env.OPENAI_BASE_URL = settings.apiEndpoint.trim();
      env.OPENAI_API_BASE = settings.apiEndpoint.trim();
    }

    return env;
  }

  private runQuickCommand(
    command: string,
    args: string[],
    cwd: string,
    env: NodeJS.ProcessEnv
  ): Promise<{ exitCode: number | null; stdout: string; stderr: string }> {
    return new Promise((resolve) => {
      const child = spawn(command, args, {
        cwd,
        env,
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"]
      });

      let stdout = "";
      let stderr = "";

      child.stdout.on("data", (chunk) => {
        stdout += normalizeChunk(chunk);
      });

      child.stderr.on("data", (chunk) => {
        stderr += normalizeChunk(chunk);
      });

      child.on("error", (error) => {
        resolve({ exitCode: 1, stdout, stderr: `${stderr}\n${String(error.message || error)}` });
      });

      child.on("close", (code) => {
        resolve({ exitCode: code, stdout: stripAnsi(stdout), stderr: stripAnsi(stderr) });
      });
    });
  }
}
