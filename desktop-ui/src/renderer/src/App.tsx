import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type {
  AgentLogPayload,
  AgentResultPayload,
  AgentStatusPayload,
  ChatRunRequest,
  DesktopSettings,
  ToolTarget
} from "./types";

interface ChecklistItem {
  label: string;
  done: boolean;
}

interface ParsedAssistant {
  planLines: string[];
  checklist: ChecklistItem[];
  finalLine: string;
  plainText: string;
}

interface ChatMessage {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  createdAt: number;
  parsed?: ParsedAssistant;
}

interface ChatSession {
  id: string;
  title: string;
  messages: ChatMessage[];
  logs: string[];
  activeRequestId: string | null;
}

const TOOL_TARGETS: ToolTarget[] = ["local", "docker", "modal", "daytona", "ssh"];

function uniqueId(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
}

function createSession(): ChatSession {
  return {
    id: uniqueId("session"),
    title: "New Session",
    messages: [],
    logs: [],
    activeRequestId: null
  };
}

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

function parseAssistantText(text: string): ParsedAssistant {
  const clean = stripAnsi(text || "").trim();
  const lines = clean.split(/\r?\n/);

  const planLines: string[] = [];
  const checklist: ChecklistItem[] = [];
  let capturePlan = false;
  let finalLine = "";

  for (const rawLine of lines) {
    const line = rawLine.trim();

    if (/^plan\s*:/i.test(line)) {
      capturePlan = true;
      continue;
    }

    if (/^checklist\s*:/i.test(line)) {
      capturePlan = false;
      continue;
    }

    if (/^final result\s*:/i.test(line)) {
      finalLine = line;
      capturePlan = false;
    }

    const checklistMatch = line.match(/^- \[( |x|X)\]\s+(.+)$/);
    if (checklistMatch) {
      checklist.push({
        done: checklistMatch[1].toLowerCase() === "x",
        label: checklistMatch[2]
      });
      continue;
    }

    if (capturePlan && /^[-*]\s+/.test(line)) {
      planLines.push(line.replace(/^[-*]\s+/, ""));
    }
  }

  return {
    planLines,
    checklist,
    finalLine,
    plainText: clean
  };
}

function statusLabel(status: AgentStatusPayload): string {
  if (status.lifecycle === "running") {
    return "Running";
  }
  if (status.lifecycle === "ready") {
    return "Ready";
  }
  if (status.lifecycle === "starting") {
    return "Starting";
  }
  if (status.lifecycle === "error") {
    return "Error";
  }
  return "Stopped";
}

export default function App() {
  const [sessions, setSessions] = useState<ChatSession[]>([createSession()]);
  const [activeSessionId, setActiveSessionId] = useState<string>(sessions[0].id);
  const [prompt, setPrompt] = useState("");

  const [settings, setSettings] = useState<DesktopSettings | null>(null);
  const [settingsDraft, setSettingsDraft] = useState<DesktopSettings | null>(null);
  const [settingsIssues, setSettingsIssues] = useState<string[]>([]);
  const [settingsOpen, setSettingsOpen] = useState(true);

  const [model, setModel] = useState("");
  const [provider, setProvider] = useState("");
  const [toolTarget, setToolTarget] = useState<ToolTarget>("local");

  const [agentStatus, setAgentStatus] = useState<AgentStatusPayload>({
    lifecycle: "stopped",
    started: false,
    runningRequestId: null,
    lastExitCode: null,
    lastError: ""
  });

  const [logsOpen, setLogsOpen] = useState(true);
  const [voiceListening, setVoiceListening] = useState(false);

  const requestToSessionRef = useRef<Record<string, string>>({});
  const speechRef = useRef<any>(null);

  const activeSession = useMemo(
    () => sessions.find((session) => session.id === activeSessionId) ?? sessions[0],
    [sessions, activeSessionId]
  );

  const latestAssistant = useMemo(
    () => [...(activeSession?.messages ?? [])].reverse().find((message) => message.role === "assistant"),
    [activeSession]
  );

  useEffect(() => {
    let disposed = false;

    async function bootstrap(): Promise<void> {
      const loaded = await window.hermesDesktop.getSettings();
      const status = await window.hermesDesktop.getAgentStatus();

      if (disposed) {
        return;
      }

      setSettings(loaded.settings);
      setSettingsDraft(loaded.settings);
      setSettingsIssues(loaded.issues);
      setModel(loaded.settings.defaultModel);
      setProvider(loaded.settings.defaultProvider);
      setToolTarget(loaded.settings.defaultToolTarget);
      setSettingsOpen(loaded.issues.length > 0 || !loaded.settings.hermesRepoPath.trim());
      setAgentStatus(status);
    }

    void bootstrap();

    return () => {
      disposed = true;
    };
  }, []);

  useEffect(() => {
    const offLog = window.hermesDesktop.onLog((payload: AgentLogPayload) => {
      const sessionId = requestToSessionRef.current[payload.requestId];
      if (!sessionId) {
        return;
      }

      const line = `[${new Date(payload.timestamp).toLocaleTimeString()}] ${payload.stream.toUpperCase()}: ${payload.chunk}`;
      setSessions((prev) =>
        prev.map((session) =>
          session.id === sessionId
            ? {
                ...session,
                logs: [...session.logs, line].slice(-1200)
              }
            : session
        )
      );
    });

    const offResult = window.hermesDesktop.onResult((payload: AgentResultPayload) => {
      const sessionId = requestToSessionRef.current[payload.requestId];
      if (!sessionId) {
        return;
      }

      delete requestToSessionRef.current[payload.requestId];

      const parsed = parseAssistantText(payload.finalResponse || payload.output || payload.errorOutput);
      const assistantMessage: ChatMessage = {
        id: uniqueId("msg"),
        role: "assistant",
        text: parsed.plainText || "Hermes finished with no text output.",
        createdAt: Date.now(),
        parsed
      };

      setSessions((prev) =>
        prev.map((session) =>
          session.id === sessionId
            ? {
                ...session,
                activeRequestId: null,
                logs: [
                  ...session.logs,
                  `Run finished in ${(payload.durationMs / 1000).toFixed(2)}s (exit ${String(payload.exitCode)})`
                ],
                messages: [...session.messages, assistantMessage]
              }
            : session
        )
      );
    });

    const offStatus = window.hermesDesktop.onStatus((payload: AgentStatusPayload) => {
      setAgentStatus(payload);
    });

    return () => {
      offLog();
      offResult();
      offStatus();
      if (speechRef.current) {
        try {
          speechRef.current.stop();
        } catch {
          // Ignore cleanup errors.
        }
      }
    };
  }, []);

  function patchSession(sessionId: string, mutator: (session: ChatSession) => ChatSession): void {
    setSessions((prev) => prev.map((session) => (session.id === sessionId ? mutator(session) : session)));
  }

  async function sendPrompt(event?: FormEvent): Promise<void> {
    event?.preventDefault();

    const trimmedPrompt = prompt.trim();
    if (!trimmedPrompt || !activeSession) {
      return;
    }

    if (!settings || !settings.hermesRepoPath.trim()) {
      setSettingsOpen(true);
      return;
    }

    const userMessage: ChatMessage = {
      id: uniqueId("msg"),
      role: "user",
      text: trimmedPrompt,
      createdAt: Date.now()
    };

    patchSession(activeSession.id, (session) => ({
      ...session,
      title:
        session.title === "New Session"
          ? trimmedPrompt.slice(0, 42) || "New Session"
          : session.title,
      messages: [...session.messages, userMessage]
    }));

    setPrompt("");

    try {
      const request: ChatRunRequest = {
        prompt: trimmedPrompt,
        model: model.trim() || undefined,
        provider: provider.trim() || undefined,
        toolTarget,
        sessionId: activeSession.id,
        verbose: settings.verboseLogs
      };

      const ack = await window.hermesDesktop.sendPrompt(request);
      requestToSessionRef.current[ack.requestId] = activeSession.id;

      patchSession(activeSession.id, (session) => ({
        ...session,
        activeRequestId: ack.requestId,
        logs: [...session.logs, `Prompt sent (${ack.requestId}).`] 
      }));
    } catch (error) {
      const systemMessage: ChatMessage = {
        id: uniqueId("msg"),
        role: "system",
        text: `Failed to send prompt: ${String((error as Error).message || error)}`,
        createdAt: Date.now()
      };

      patchSession(activeSession.id, (session) => ({
        ...session,
        messages: [...session.messages, systemMessage]
      }));
    }
  }

  function createNewSession(): void {
    const session = createSession();
    setSessions((prev) => [session, ...prev]);
    setActiveSessionId(session.id);
  }

  async function saveSettings(): Promise<void> {
    if (!settingsDraft) {
      return;
    }

    const response = await window.hermesDesktop.saveSettings(settingsDraft);
    setSettings(response.settings);
    setSettingsDraft(response.settings);
    setSettingsIssues(response.issues);
    setModel(response.settings.defaultModel);
    setProvider(response.settings.defaultProvider);
    setToolTarget(response.settings.defaultToolTarget);

    if (response.issues.length === 0) {
      setSettingsOpen(false);
    }
  }

  async function browsePath(field: keyof DesktopSettings, kind: "file" | "directory"): Promise<void> {
    if (!settingsDraft) {
      return;
    }

    const chosen = await window.hermesDesktop.pickPath(kind);
    if (!chosen) {
      return;
    }

    setSettingsDraft({
      ...settingsDraft,
      [field]: chosen
    });
  }

  async function startAgent(): Promise<void> {
    const status = await window.hermesDesktop.startAgent();
    setAgentStatus(status);
  }

  async function stopAgent(): Promise<void> {
    const status = await window.hermesDesktop.stopAgent();
    setAgentStatus(status);
  }

  async function cancelRun(): Promise<void> {
    const result = await window.hermesDesktop.cancelPrompt();
    setAgentStatus(result.status);
  }

  function toggleVoiceInput(): void {
    if (voiceListening && speechRef.current) {
      speechRef.current.stop();
      return;
    }

    const SpeechCtor = window.SpeechRecognition ?? window.webkitSpeechRecognition;
    if (!SpeechCtor) {
      if (activeSession) {
        const message: ChatMessage = {
          id: uniqueId("msg"),
          role: "system",
          text: "Voice input is unavailable on this machine. Use Windows speech typing or install a browser with SpeechRecognition support.",
          createdAt: Date.now()
        };

        patchSession(activeSession.id, (session) => ({
          ...session,
          messages: [...session.messages, message]
        }));
      }
      return;
    }

    const recognition = new SpeechCtor();
    recognition.lang = "en-US";
    recognition.interimResults = true;
    recognition.continuous = false;

    recognition.onstart = () => setVoiceListening(true);
    recognition.onend = () => setVoiceListening(false);
    recognition.onerror = () => setVoiceListening(false);
    recognition.onresult = (event: any) => {
      let transcript = "";
      for (let index = event.resultIndex; index < event.results.length; index += 1) {
        transcript += event.results[index][0].transcript;
      }
      setPrompt((prev) => `${prev}${prev && transcript ? " " : ""}${transcript}`.trim());
    };

    speechRef.current = recognition;
    recognition.start();
  }

  const statusText = statusLabel(agentStatus);

  if (!settingsDraft) {
    return <div className="loading-state">Loading desktop settings...</div>;
  }

  return (
    <div className="shell">
      <aside className="left-sidebar">
        <div className="sidebar-head">
          <h1>Hermes Desktop</h1>
          <button type="button" className="primary-btn" onClick={createNewSession}>
            + New Session
          </button>
        </div>
        <div className="session-list">
          {sessions.map((session) => (
            <button
              key={session.id}
              type="button"
              className={`session-item ${session.id === activeSessionId ? "active" : ""}`}
              onClick={() => setActiveSessionId(session.id)}
            >
              <span className="session-title">{session.title}</span>
              <span className="session-meta">
                {session.activeRequestId ? "Running" : `${session.messages.length} msgs`}
              </span>
            </button>
          ))}
        </div>
      </aside>

      <main className="chat-main">
        <header className="top-toolbar">
          <div className="status-pill" data-state={agentStatus.lifecycle}>
            {statusText}
          </div>

          <label className="toolbar-field">
            Provider
            <input value={provider} onChange={(event) => setProvider(event.target.value)} placeholder="auto" />
          </label>

          <label className="toolbar-field">
            Model
            <input value={model} onChange={(event) => setModel(event.target.value)} placeholder="anthropic/claude-sonnet-4" />
          </label>

          <label className="toolbar-field small">
            Tool Target
            <select value={toolTarget} onChange={(event) => setToolTarget(event.target.value as ToolTarget)}>
              {TOOL_TARGETS.map((value) => (
                <option key={value} value={value}>
                  {value}
                </option>
              ))}
            </select>
          </label>

          <button type="button" className="secondary-btn" onClick={startAgent}>
            Start
          </button>
          <button type="button" className="secondary-btn" onClick={stopAgent}>
            Stop
          </button>
          <button type="button" className="secondary-btn" onClick={cancelRun}>
            Cancel Run
          </button>
          <button type="button" className="secondary-btn" onClick={() => setSettingsOpen(true)}>
            Settings
          </button>
          <button type="button" className="secondary-btn" onClick={() => setLogsOpen((prev) => !prev)}>
            {logsOpen ? "Hide Logs" : "Show Logs"}
          </button>
        </header>

        <section className="chat-scroll">
          {activeSession.messages.length === 0 ? (
            <div className="empty-state">
              Ask Hermes to do something. Example: Create a simple Python hello world script and run it.
            </div>
          ) : (
            activeSession.messages.map((message) => (
              <article key={message.id} className={`chat-msg ${message.role}`}>
                <div className="msg-head">
                  <span>{message.role.toUpperCase()}</span>
                  <time>{new Date(message.createdAt).toLocaleTimeString()}</time>
                </div>

                {message.parsed && message.parsed.planLines.length > 0 ? (
                  <section className="parsed-block">
                    <h4>Plan</h4>
                    <ul>
                      {message.parsed.planLines.map((line) => (
                        <li key={`${message.id}-${line}`}>{line}</li>
                      ))}
                    </ul>
                  </section>
                ) : null}

                {message.parsed && message.parsed.checklist.length > 0 ? (
                  <section className="parsed-block">
                    <h4>Checklist</h4>
                    <ul>
                      {message.parsed.checklist.map((item) => (
                        <li key={`${message.id}-${item.label}`} className={item.done ? "done" : "pending"}>
                          {item.done ? "[x]" : "[ ]"} {item.label}
                        </li>
                      ))}
                    </ul>
                  </section>
                ) : null}

                {message.parsed?.finalLine ? (
                  <section className="parsed-block">
                    <h4>Final Result</h4>
                    <p>{message.parsed.finalLine}</p>
                  </section>
                ) : null}

                <pre className="msg-body">{message.text}</pre>
              </article>
            ))
          )}
        </section>

        <form className="composer" onSubmit={(event) => void sendPrompt(event)}>
          <textarea
            value={prompt}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder="Tell Hermes what to do..."
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                void sendPrompt();
              }
            }}
          />
          <div className="composer-actions">
            <button type="button" className="secondary-btn" onClick={toggleVoiceInput}>
              {voiceListening ? "Stop Mic" : "Voice Input"}
            </button>
            <button type="submit" className="primary-btn" disabled={!prompt.trim()}>
              Send
            </button>
          </div>
        </form>
      </main>

      {logsOpen ? (
        <aside className="right-panel">
          <h3>Live Execution</h3>
          {latestAssistant?.parsed ? (
            <div className="summary-box">
              <h4>Latest Checklist</h4>
              {latestAssistant.parsed.checklist.length > 0 ? (
                <ul>
                  {latestAssistant.parsed.checklist.map((item) => (
                    <li key={`${latestAssistant.id}-${item.label}`}>
                      {item.done ? "[x]" : "[ ]"} {item.label}
                    </li>
                  ))}
                </ul>
              ) : (
                <p>No checklist found in latest response.</p>
              )}
            </div>
          ) : null}

          <div className="log-box">
            {(activeSession.logs.length > 0 ? activeSession.logs : ["No logs yet."]).map((line, index) => (
              <pre key={`${index}-${line.slice(0, 20)}`}>{line}</pre>
            ))}
          </div>
        </aside>
      ) : null}

      {settingsOpen ? (
        <div className="settings-modal">
          <div className="settings-card">
            <h2>Machine Settings</h2>
            <p>
              Paths are machine-local. Configure this once per machine and Hermes Desktop will store settings in your local app data.
            </p>

            <div className="settings-grid">
              <label>
                Hermes repo path *
                <div className="path-field">
                  <input
                    value={settingsDraft.hermesRepoPath}
                    onChange={(event) => setSettingsDraft({ ...settingsDraft, hermesRepoPath: event.target.value })}
                    placeholder="Path to hermes-agent repo"
                  />
                  <button type="button" onClick={() => void browsePath("hermesRepoPath", "directory")}>
                    Browse
                  </button>
                </div>
              </label>

              <label>
                Hermes entry path (optional)
                <div className="path-field">
                  <input
                    value={settingsDraft.hermesEntryPath}
                    onChange={(event) => setSettingsDraft({ ...settingsDraft, hermesEntryPath: event.target.value })}
                    placeholder="Path to hermes script file"
                  />
                  <button type="button" onClick={() => void browsePath("hermesEntryPath", "file")}>
                    Browse
                  </button>
                </div>
              </label>

              <label>
                Python executable (optional)
                <div className="path-field">
                  <input
                    value={settingsDraft.pythonExecutable}
                    onChange={(event) => setSettingsDraft({ ...settingsDraft, pythonExecutable: event.target.value })}
                    placeholder="Path to python.exe"
                  />
                  <button type="button" onClick={() => void browsePath("pythonExecutable", "file")}>
                    Browse
                  </button>
                </div>
              </label>

              <label>
                DevTools path (optional)
                <div className="path-field">
                  <input
                    value={settingsDraft.devToolsPath}
                    onChange={(event) => setSettingsDraft({ ...settingsDraft, devToolsPath: event.target.value })}
                    placeholder="Path to DevTools root"
                  />
                  <button type="button" onClick={() => void browsePath("devToolsPath", "directory")}>
                    Browse
                  </button>
                </div>
              </label>

              <label>
                Workspace/output path
                <div className="path-field">
                  <input
                    value={settingsDraft.workspacePath}
                    onChange={(event) => setSettingsDraft({ ...settingsDraft, workspacePath: event.target.value })}
                    placeholder="Default working directory"
                  />
                  <button type="button" onClick={() => void browsePath("workspacePath", "directory")}>
                    Browse
                  </button>
                </div>
              </label>

              <label>
                API endpoint (optional)
                <input
                  value={settingsDraft.apiEndpoint}
                  onChange={(event) => setSettingsDraft({ ...settingsDraft, apiEndpoint: event.target.value })}
                  placeholder="https://your-endpoint/v1"
                />
              </label>

              <label>
                Default provider
                <input
                  value={settingsDraft.defaultProvider}
                  onChange={(event) => setSettingsDraft({ ...settingsDraft, defaultProvider: event.target.value })}
                  placeholder="openrouter"
                />
              </label>

              <label>
                Default model
                <input
                  value={settingsDraft.defaultModel}
                  onChange={(event) => setSettingsDraft({ ...settingsDraft, defaultModel: event.target.value })}
                  placeholder="anthropic/claude-sonnet-4"
                />
              </label>

              <label>
                Default tool target
                <select
                  value={settingsDraft.defaultToolTarget}
                  onChange={(event) =>
                    setSettingsDraft({ ...settingsDraft, defaultToolTarget: event.target.value as ToolTarget })
                  }
                >
                  {TOOL_TARGETS.map((value) => (
                    <option key={value} value={value}>
                      {value}
                    </option>
                  ))}
                </select>
              </label>

              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={settingsDraft.verboseLogs}
                  onChange={(event) => setSettingsDraft({ ...settingsDraft, verboseLogs: event.target.checked })}
                />
                Enable verbose run logs
              </label>
            </div>

            {settingsIssues.length > 0 ? (
              <ul className="issues-list">
                {settingsIssues.map((issue) => (
                  <li key={issue}>{issue}</li>
                ))}
              </ul>
            ) : null}

            {agentStatus.lastError ? <div className="error-banner">{agentStatus.lastError}</div> : null}

            <div className="settings-actions">
              <button type="button" className="primary-btn" onClick={() => void saveSettings()}>
                Save Settings
              </button>
              <button type="button" className="secondary-btn" onClick={() => setSettingsOpen(false)}>
                Close
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
