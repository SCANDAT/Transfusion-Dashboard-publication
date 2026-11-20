import { parseDisplayJson, validateDisplayManifest, validateStudyScope, type DisplayManifest } from './displayManifest.mjs'

const pin = import.meta.env.VITE_READER_DISPLAY_SHA256
let displayManifest: DisplayManifest | undefined

class WithheldResult extends Error {}
export function isWithheld(error: unknown): boolean { return error instanceof WithheldResult }

async function readChecked(path: string, expected: string, signal?: AbortSignal): Promise<unknown> {
  if (!/^[a-f0-9]{64}$/.test(expected)) throw new Error('Invalid dashboard index checksum')
  const url = new URL(import.meta.env.BASE_URL + path, window.location.origin)
  if (url.origin !== window.location.origin) throw new Error('Invalid dashboard address')
  const response = await fetch(url, { credentials:'same-origin', redirect:'error', cache:'no-cache', signal })
  if (!response.ok || response.url !== url.href || response.redirected) throw new Error('Dashboard file unavailable')
  const bytes = await response.arrayBuffer()
  const hash = await crypto.subtle.digest('SHA-256', bytes)
  const actual = Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, '0')).join('')
  if (actual !== expected) throw new Error('Dashboard result integrity check failed')
  if (signal?.aborted) throw new DOMException('Request aborted', 'AbortError')
  return parseDisplayJson(new TextDecoder('utf-8', { fatal:true, ignoreBOM:true }).decode(bytes))
}

async function manifest(signal?: AbortSignal): Promise<DisplayManifest> {
  if (signal?.aborted) throw new DOMException('Request aborted', 'AbortError')
  if (!displayManifest) {
    const result = validateDisplayManifest(await readChecked('reader.json', pin, signal))
    displayManifest = result
  }
  return displayManifest
}

export async function openReader(signal?: AbortSignal): Promise<{releaseId:string}> {
  const checked = await manifest(signal)
  return {releaseId:checked.releaseId}
}

export async function readDisplay(key: string, signal?: AbortSignal): Promise<unknown> {
  const checked = await manifest(signal)
  if (!Object.prototype.hasOwnProperty.call(checked.assets, key)) throw new Error('Unknown dashboard selection')
  const expected = checked.assets[key]
  if (expected === null) throw new WithheldResult('This result is withheld from the public dashboard.')
  if (!expected) throw new Error('Missing dashboard result digest')
  const value = await readChecked('results/' + key + '.json', expected, signal)
  if (key.startsWith('study/')) validateStudyScope(value, checked)
  return value
}
