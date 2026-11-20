import { useState, type ReactNode } from 'react'
import './optionsPanel.css'

interface Props { label: string; children: ReactNode; summary?: ReactNode; className?: string }
export default function OptionsPanel({ label, children, summary, className = '' }: Props) {
  const [visible, setVisible] = useState(true)
  return <div className={`display-options ${className}`} role="group" aria-label={label}>
    <div className="display-options-content">{visible ? children : summary && <p className="analysis-context">{summary}</p>}</div>
    <button type="button" className="text-button" aria-expanded={visible} onClick={() => setVisible(value => !value)}>{visible ? 'Hide options' : 'Show options'}</button>
  </div>
}
