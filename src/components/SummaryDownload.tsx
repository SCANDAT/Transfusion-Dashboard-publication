import { useState } from 'react'
import './summaryDownloads.css'

interface Props { createSvg: () => string; filename: string; disabled?: boolean; ready?: boolean }

export default function SummaryDownload({ createSvg, filename, disabled = false, ready = false }: Props) {
  const [error, setError] = useState(false)
  const [preparing, setPreparing] = useState(false)
  async function download() {
    if (disabled || !ready || preparing) return
    setError(false)
    setPreparing(true)
    try {
      const drawing = createSvg()
      if (!drawing.includes('<svg') || !filename.endsWith('.svg')) throw new Error('INVALID_FIGURE_EXPORT')
      const { embedSvgFonts } = await import('../figures/svgFonts')
      const svg = await embedSvgFonts(drawing)
      const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml;charset=utf-8' }))
      const link = document.createElement('a')
      link.href = url; link.download = filename; link.click()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
    } catch { setError(true) } finally { setPreparing(false) }
  }
  return <div className="summary-download">
    <button type="button" disabled={disabled || !ready || preparing} aria-busy={preparing} onClick={download}>{preparing ? 'Preparing figure...' : 'Download summary figure (SVG)'}</button>
    {error && <span role="alert">The figure could not be prepared.</span>}
  </div>
}
