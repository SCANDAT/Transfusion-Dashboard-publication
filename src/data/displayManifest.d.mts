export interface DisplayManifest {
  readonly schemaVersion: 'transfusion-dashboard/display-v2'
  readonly releaseId: string
  readonly assets: Readonly<Record<string, string | null>>
}
export function displayKeys(): string[]
export function allStudyPopulationsSelected(isSelected: (key: string) => boolean): boolean
export function validateStudyScope(value: unknown, manifest: DisplayManifest): void
export function validateDisplayManifest(value: unknown): DisplayManifest
export function parseDisplayJson(text: string): unknown
