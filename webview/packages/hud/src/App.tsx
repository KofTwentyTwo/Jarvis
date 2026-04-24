import { ParticleRing } from './hud/ParticleRing'
import { LoadingFallbacks } from './hud/LoadingFallbacks'

export function App() {
  return (
    <div className="jarvis-hud">
      <div className="jarvis-hud__ring">
        <ParticleRing particles={512} />
      </div>
      <LoadingFallbacks />
      {/* <ChatPanel /> lands in Plan 03-04 */}
    </div>
  )
}
