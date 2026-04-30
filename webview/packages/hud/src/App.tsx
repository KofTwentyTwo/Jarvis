import { ParticleRing } from './hud/ParticleRing'
import { LoadingFallbacks } from './hud/LoadingFallbacks'
import { HudFrame } from './hud/HudFrame'
import { ChatPanel } from './chat/ChatPanel'

export function App() {
  return (
    <div className="jarvis-hud">
      <div className="jarvis-hud__ring">
        <ParticleRing particles={512} />
      </div>
      <LoadingFallbacks />
      <HudFrame />
      <div className="jarvis-hud__chat">
        <ChatPanel />
      </div>
    </div>
  )
}
