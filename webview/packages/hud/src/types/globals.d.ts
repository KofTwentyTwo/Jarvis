// Vite's `?raw` import suffix for shader strings (Plan 03-03 uses this).
declare module '*.glsl?raw' {
  const src: string
  export default src
}
declare module '*.vert?raw' {
  const src: string
  export default src
}
declare module '*.frag?raw' {
  const src: string
  export default src
}
