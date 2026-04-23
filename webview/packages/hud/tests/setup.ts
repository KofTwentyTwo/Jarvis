import '@testing-library/jest-dom'

// jsdom lacks ResizeObserver; R3F's <Canvas> uses react-use-measure which
// requires it. Install a no-op polyfill for tests.
if (typeof globalThis.ResizeObserver === 'undefined') {
  class ResizeObserverPolyfill {
    observe(): void {
      /* noop */
    }
    unobserve(): void {
      /* noop */
    }
    disconnect(): void {
      /* noop */
    }
  }
  ;(globalThis as unknown as { ResizeObserver: typeof ResizeObserverPolyfill }).ResizeObserver =
    ResizeObserverPolyfill
}
