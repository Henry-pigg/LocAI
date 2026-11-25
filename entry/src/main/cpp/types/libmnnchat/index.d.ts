/**
 * Alibaba MNN LLM Native Interface for HarmonyOS NEXT
 */
export interface NativeInferenceStats {
  prefillLatencyMs: number;
  decodeTokens: number;
  decodeSpeedTokensPerSec: number;
  peakMemoryMB: number;
  totalDurationMs: number;
}

export interface NativeLoadParams {
  threads?: number;
  precision?: string; // "low" | "normal" | "high"
  backend?: string;   // "cpu" | "opencl"
  contextLength?: number;
}

export function initEngine(baseDir: string): boolean;
export function loadModel(modelDir: string, paramsJson: string): boolean;
export function isModelLoaded(): boolean;
export function applyRuntimeConfig(paramsJson: string): boolean;
export function releaseModel(): boolean;
export function resetSession(): boolean;
export function startGenerateStream(
  prompt: string,
  roles: string[],
  contents: string[],
  onTokenCallback: (token: string) => void,
  onCompleteCallback: (statsJson: string) => void,
  onErrorCallback: (errorMessage: string) => void
): boolean;
export function stopGenerate(): boolean;
export function getInferenceStats(): string;
export function getEngineVersion(): string;
export function getAppliedConfig(): string;
export function isSimulatorEngine(): boolean;
export function probeAccelerators(): string;
