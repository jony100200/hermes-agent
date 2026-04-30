import { contextBridge, ipcRenderer } from "electron";
import type {
  AgentLogPayload,
  AgentResultPayload,
  AgentStatusPayload,
  ChatRunAck,
  ChatRunRequest,
  DesktopSettings,
  SettingsResponse
} from "../main/types";

function subscribe<T>(channel: string, listener: (payload: T) => void): () => void {
  const wrapped = (_event: Electron.IpcRendererEvent, payload: T) => listener(payload);
  ipcRenderer.on(channel, wrapped);
  return () => ipcRenderer.removeListener(channel, wrapped);
}

const api = {
  getSettings: (): Promise<SettingsResponse> => ipcRenderer.invoke("desktop:settings:get"),
  saveSettings: (partial: Partial<DesktopSettings>): Promise<SettingsResponse> =>
    ipcRenderer.invoke("desktop:settings:save", partial),
  pickPath: (kind: "file" | "directory"): Promise<string | null> =>
    ipcRenderer.invoke("desktop:path:pick", kind),
  startAgent: (): Promise<AgentStatusPayload> => ipcRenderer.invoke("desktop:agent:start"),
  stopAgent: (): Promise<AgentStatusPayload> => ipcRenderer.invoke("desktop:agent:stop"),
  getAgentStatus: (): Promise<AgentStatusPayload> => ipcRenderer.invoke("desktop:agent:status"),
  sendPrompt: (request: ChatRunRequest): Promise<ChatRunAck> => ipcRenderer.invoke("desktop:chat:send", request),
  cancelPrompt: (): Promise<{ cancelled: boolean; status: AgentStatusPayload }> =>
    ipcRenderer.invoke("desktop:chat:cancel"),
  onLog: (listener: (payload: AgentLogPayload) => void): (() => void) =>
    subscribe<AgentLogPayload>("desktop:agent:log", listener),
  onResult: (listener: (payload: AgentResultPayload) => void): (() => void) =>
    subscribe<AgentResultPayload>("desktop:agent:result", listener),
  onStatus: (listener: (payload: AgentStatusPayload) => void): (() => void) =>
    subscribe<AgentStatusPayload>("desktop:agent:status", listener)
};

contextBridge.exposeInMainWorld("hermesDesktop", api);

export type HermesDesktopApi = typeof api;
