import { useEffect, useId, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import './chartDialog.css'

interface Props {
  open: boolean
  title: string
  context?: ReactNode
  onClose: () => void
  children: ReactNode
}

/** Display the chart in a modal dialog and keep keyboard focus inside it. */
export default function ChartDialog({ open, title, context, onClose, children }: Props) {
  const id = useId()
  const dialog = useRef<HTMLDialogElement>(null)
  const closeButton = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    if (!open || !dialog.current) return
    const element = dialog.current
    const opener = document.activeElement
    const previousOverflow = document.body.style.overflow
    element.showModal()
    document.body.style.overflow = 'hidden'
    closeButton.current?.focus()
    return () => {
      if (element.open) element.close()
      document.body.style.overflow = previousOverflow
      if (opener?.isConnected && (opener instanceof HTMLElement || opener instanceof SVGElement) && 'focus' in opener) {
        (opener as HTMLElement).focus({ preventScroll: true })
      }
    }
  }, [open])

  return createPortal(<dialog ref={dialog} className="chart-dialog" aria-labelledby={`${id}-title`}
    aria-describedby={context ? `${id}-context` : undefined}
    onKeyDown={event => {
      if (event.key !== 'Tab') return
      const items = Array.from(event.currentTarget.querySelectorAll<HTMLElement>('button, a[href], input, select, textarea, [tabindex]'))
        .filter(item => item.tabIndex >= 0 && !item.matches(':disabled') && !item.closest('[hidden]'))
      const first = items[0], last = items[items.length - 1]
      if (!first || !last) { event.preventDefault(); return }
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
    }}
    onCancel={event => { event.preventDefault(); onClose() }}
    onClose={() => { if (open) onClose() }}
    onClick={event => {
      if (event.target !== event.currentTarget) return
      const rect = event.currentTarget.getBoundingClientRect()
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) onClose()
    }}>
    {open && <div className="chart-dialog-shell">
      <div className="chart-dialog-heading">
        <div><h2 id={`${id}-title`}>{title}</h2>{context && <div id={`${id}-context`} className="chart-dialog-context">{context}</div>}</div>
        <button ref={closeButton} type="button" className="chart-dialog-close" onClick={onClose} aria-label="Close enlarged chart">Close <span aria-hidden="true">×</span></button>
      </div>
      <div className="chart-dialog-content" tabIndex={0} role="region" aria-label={`${title} chart content`}>{children}</div>
    </div>}
  </dialog>, document.body)
}