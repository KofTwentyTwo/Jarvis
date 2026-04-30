import { useEffect, useState } from 'react'
import { useJarvisStore } from '../store'
import './hud-frame.css'

/**
 * Iron Man HUD chrome layered over the canvas: corner brackets, status
 * panel (top-left), system label (top-right), perimeter ticker (bottom),
 * and a centered state readout under the ring.
 *
 * Pure DOM/SVG so it doesn't compete with the canvas for GPU. Uses CSS
 * keyframe animation, suspended under Reduce Motion via the global media
 * query (already set up in tokens.css).
 */
export function HudFrame() {
  const hudState = useJarvisStore((s) => s.hudState)
  const stateLabel = STATE_DISPLAY[hudState] ?? hudState.toUpperCase()
  const stateColor = STATE_ACCENT[hudState] ?? 'cyan'
  const time = useClock()

  return (
    <div className="hud-frame" data-state={hudState} data-accent={stateColor}>
      {/* Corner brackets — top-left, top-right, bottom-left, bottom-right */}
      <CornerBracket position="tl" />
      <CornerBracket position="tr" />
      <CornerBracket position="bl" />
      <CornerBracket position="br" />

      {/* Status panel — top-left */}
      <div className="hud-frame__panel hud-frame__panel--tl">
        <div className="hud-frame__row">
          <span className="hud-frame__lbl">SYS</span>
          <span className="hud-frame__val">JARVIS Mk-II</span>
        </div>
        <div className="hud-frame__row">
          <span className="hud-frame__lbl">STATE</span>
          <span className="hud-frame__val hud-frame__val--accent">{stateLabel}</span>
        </div>
        <div className="hud-frame__row">
          <span className="hud-frame__lbl">CLK</span>
          <span className="hud-frame__val">{time}</span>
        </div>
      </div>

      {/* System label — top-right */}
      <div className="hud-frame__panel hud-frame__panel--tr">
        <div className="hud-frame__row">
          <span className="hud-frame__lbl">PWR</span>
          <span className="hud-frame__val">100%</span>
        </div>
        <div className="hud-frame__row">
          <span className="hud-frame__lbl">CORE</span>
          <span className="hud-frame__val hud-frame__val--accent">NOMINAL</span>
        </div>
        <div className="hud-frame__row">
          <span className="hud-frame__lbl">LINK</span>
          <span className="hud-frame__val">SECURE</span>
        </div>
      </div>

      {/* Center state readout under the ring */}
      <div className="hud-frame__center">
        <div className="hud-frame__center-inner">
          <span className="hud-frame__center-state">{stateLabel}</span>
          <span className="hud-frame__center-sub">// arc reactor online</span>
        </div>
      </div>

      {/* Perimeter ticker — bottom edge */}
      <div className="hud-frame__ticker">
        <div className="hud-frame__ticker-track">
          <Ticker />
          <Ticker />
        </div>
      </div>
    </div>
  )
}

const STATE_DISPLAY: Record<string, string> = {
  booting: 'BOOTING',
  idle: 'STANDBY',
  listening: 'LISTENING',
  thinking: 'PROCESSING',
  speaking: 'TRANSMIT',
  awaitingConfirmation: 'AWAITING',
  reconfiguring: 'RECONFIG',
}

const STATE_ACCENT: Record<string, 'cyan' | 'amber' | 'green' | 'red'> = {
  booting: 'cyan',
  idle: 'cyan',
  listening: 'green',
  thinking: 'cyan',
  speaking: 'cyan',
  awaitingConfirmation: 'amber',
  reconfiguring: 'amber',
}

function CornerBracket({ position }: { position: 'tl' | 'tr' | 'bl' | 'br' }) {
  return (
    <svg
      className={`hud-frame__corner hud-frame__corner--${position}`}
      viewBox="0 0 60 60"
      width="60"
      height="60"
      aria-hidden
    >
      {/* L-shape, ~3px thick. Per-corner CSS rotates this. */}
      <path d="M 3 28 L 3 3 L 28 3" stroke="currentColor" strokeWidth="2" fill="none" />
      <path d="M 8 35 L 8 8 L 35 8" stroke="currentColor" strokeWidth="1" fill="none" opacity="0.55" />
      <circle cx="3" cy="3" r="2.2" fill="currentColor" />
    </svg>
  )
}

const TICKER_CONTENT = [
  'CORE 100%',
  'COIL 0.42 mΩ',
  'PALLADIUM 14%',
  'TEMP 36.8°C',
  'PSI 1.013 bar',
  'NET LATENCY 18 ms',
  'AGENT IDLE',
  'OPUS 4.7 ONLINE',
  'OLLAMA 127.0.0.1:11434',
  'TCC AUDIO ✓',
  'TCC CAMERA ✓',
  'TCC AUTOMATION ✓',
  'KEYCHAIN HEALTHY',
  'REPLAY LOG WAL',
  'MCP HELPERS 3',
  'WAKE WORD ARMED',
]

function Ticker() {
  return (
    <span className="hud-frame__ticker-content">
      {TICKER_CONTENT.map((s, i) => (
        <span key={i} className="hud-frame__ticker-item">
          {s}
        </span>
      ))}
    </span>
  )
}

function useClock() {
  const [now, setNow] = useState(() => formatClock(new Date()))
  useEffect(() => {
    const id = setInterval(() => setNow(formatClock(new Date())), 1000)
    return () => clearInterval(id)
  }, [])
  return now
}

function formatClock(d: Date) {
  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')
  const ss = String(d.getSeconds()).padStart(2, '0')
  return `${hh}:${mm}:${ss}`
}
