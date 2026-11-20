import sourceSerifUrl from '../assets/fonts/source-serif-4.woff2?url'
import libreCaslonUrl from '../assets/fonts/libre-caslon-text.woff2?url'
import sourceSerifLicense from '../assets/fonts/source-serif-4-OFL.txt?raw'
import libreCaslonLicense from '../assets/fonts/libre-caslon-text-OFL.txt?raw'

const FONTS = [
  { family: 'Source Serif 4', url: sourceSerifUrl, weight: '200 900', size: 436484, sha256: '11003b7885b648b7e5440d1ec8b0d3b2245a53fd5c8ab53adfa86a0175b315e7', license: sourceSerifLicense },
  { family: 'Libre Caslon Text', url: libreCaslonUrl, weight: '400 700', size: 61304, sha256: '6cd9c08998836d6fa6db4d5d0e0507053fcd81c02c5499a7f35dfa9034ff4b92', license: libreCaslonLicense },
] as const
let embeddedFonts: Promise<string> | null = null

function xml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
function base64(bytes: Uint8Array): string {
  let text = ''
  for (let offset = 0; offset < bytes.length; offset += 8192) text += String.fromCharCode(...bytes.subarray(offset, offset + 8192))
  return btoa(text)
}
async function fontDefinitions(): Promise<string> {
  const faces = await Promise.all(FONTS.map(async font => {
    const response = await fetch(font.url, { credentials: 'same-origin', cache: 'force-cache' })
    if (!response.ok) throw new Error('FIGURE_FONT_UNAVAILABLE')
    const data = await response.arrayBuffer(), bytes = new Uint8Array(data)
    if (bytes.length !== font.size || String.fromCharCode(...bytes.subarray(0, 4)) !== 'wOF2') throw new Error('FIGURE_FONT_INVALID')
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', data))).map(byte => byte.toString(16).padStart(2, '0')).join('')
    if (hash !== font.sha256) throw new Error('FIGURE_FONT_INTEGRITY')
    return `@font-face{font-family:"${font.family}";src:url(data:font/woff2;base64,${base64(bytes)}) format("woff2");font-style:normal;font-weight:${font.weight};font-display:block;}`
  }))
  const typography = 'svg{font-synthesis:none;font-optical-sizing:auto;font-variant-numeric:lining-nums tabular-nums;}'
  return `<defs data-role="embedded-fonts"><style type="text/css">${faces.join('')}${typography}</style></defs><metadata id="font-licenses">${xml(FONTS.map(font => font.family + '\n' + font.license).join('\n\n'))}</metadata>`
}

/** Embed the same local font files used by the dashboard without changing drawing or result metadata. */
export async function embedSvgFonts(svg: string): Promise<string> {
  if (!/<svg\b[^>]*>/.test(svg) || svg.includes('data-role="embedded-fonts"')) throw new Error('FIGURE_FONT_DOCUMENT_INVALID')
  if (!embeddedFonts) embeddedFonts = fontDefinitions().catch(error => { embeddedFonts = null; throw error })
  const definitions = await embeddedFonts
  const resultMetadata = /<metadata id="summary-data">[\s\S]*?<\/metadata>/
  if (/<svg\b[^>]*\bdata-compact-summary="true"/.test(svg)) {
    if (resultMetadata.test(svg)) throw new Error('Unexpected compact result metadata')
    return finishDisplayFigure(svg.replace(/<svg\b[^>]*>/, opening => opening + definitions))
  }
  return resultMetadata.test(svg) ? svg.replace(resultMetadata, original => original + definitions) : svg.replace(/<svg\b[^>]*>/, opening => opening + definitions)
}

function finishDisplayFigure(source: string): string {
  const svgNamespace = 'http://www.w3.org/2000/svg'
  const document = new DOMParser().parseFromString(source, 'image/svg+xml')
  const root = document.documentElement
  if (root.localName !== 'svg' || root.namespaceURI !== svgNamespace || document.querySelector('parsererror')) {
    throw new Error('Invalid summary SVG')
  }
  const metadata = Array.from(root.getElementsByTagNameNS(svgNamespace, 'metadata'))
  const licence = metadata.find(node => node.id === 'font-licenses')
  const fontBlocks = root.querySelectorAll('defs[data-role="embedded-fonts"]')
  if (metadata.length !== 1 || root.getAttribute('data-compact-summary') !== 'true' || licence?.parentElement !== root ||
      fontBlocks.length !== 1 || !licence.textContent?.trim()) {
    throw new Error('Unexpected summary or font metadata')
  }
  // Refuse to remove an attribute a future figure uses in a stylesheet.
  const styles = Array.from(root.querySelectorAll('style'), node => node.textContent ?? '')
  const inlineStyles = Array.from(root.querySelectorAll('[style]'), node => node.getAttribute('style') ?? '')
  if ([...styles, ...inlineStyles].some(css => /(?:\[\s*|attr\(\s*)data-/i.test(css))) {
    throw new Error('Summary styling depends on a data attribute')
  }

  const legalDescription = document.createElementNS(svgNamespace, 'desc')
  legalDescription.id = licence.id
  fontBlocks[0]!.setAttribute('aria-hidden', 'true')
  legalDescription.textContent = licence.textContent
  fontBlocks[0]!.appendChild(legalDescription)
  licence.remove()

  for (const node of [root, ...Array.from(root.querySelectorAll('*'))]) {
    for (const name of node.getAttributeNames()) {
      if (name.toLowerCase().startsWith('data-')) node.removeAttribute(name)
    }
  }
  return '<?xml version="1.0" encoding="UTF-8"?>\n' + new XMLSerializer().serializeToString(root)
}
