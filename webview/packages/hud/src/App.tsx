import { ParticleRing } from './hud/ParticleRing'

export function App() {
  return (
    <div className="jarvis-hud">
      <div className="jarvis-hud__ring">
        <ParticleRing particles={512} />
      </div>
    </div>
  )
}
