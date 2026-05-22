// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/fleet_monitor"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const Hooks = {}

Hooks.MoistureThresholds = {
  mounted() {
    this.lowSlider = this.el.querySelector('[data-role="low-slider"]')
    this.highSlider = this.el.querySelector('[data-role="high-slider"]')
    this.lowValue = this.el.querySelector('[data-role="low-value"]')
    this.highValue = this.el.querySelector('[data-role="high-value"]')
    this.deviceId = this.el.dataset.deviceId
    this.gap = parseFloat(this.el.dataset.gap || "3")

    // Find the marker elements inside the same card (they are siblings in the DOM)
    const card = this.el.closest('.card')
    if (card) {
      this.lowMarker = card.querySelector('[data-role="low-marker"]')
      this.highMarker = card.querySelector('[data-role="high-marker"]')
    }

    if (this.lowSlider && this.highSlider) {
      this.lowSlider.addEventListener('input', () => this.handleLowInput())
      this.highSlider.addEventListener('input', () => this.handleHighInput())

      // Send on release
      this.lowSlider.addEventListener('change', () => this.pushThresholds())
      this.highSlider.addEventListener('change', () => this.pushThresholds())
    }
  },

  updated() {
    // Refresh slider references after LiveView DOM morph
    const low = this.el.querySelector('[data-role="low-slider"]')
    const high = this.el.querySelector('[data-role="high-slider"]')
    if (low) this.lowSlider = low
    if (high) this.highSlider = high
  },

  handleLowInput() {
    let low = Math.max(0, Math.min(100, parseFloat(this.lowSlider.value)))
    let high = parseFloat(this.highSlider.value)

    if (low > high - this.gap) {
      high = low + this.gap
      if (high > 100) {
        high = 100
        low = high - this.gap
        this.lowSlider.value = low
      }
      this.highSlider.value = high
      this.updateHighVisuals(high)
    }

    this.updateLowVisuals(low)
  },

  handleHighInput() {
    let low = parseFloat(this.lowSlider.value)
    let high = Math.max(0, Math.min(100, parseFloat(this.highSlider.value)))

    if (high < low + this.gap) {
      low = high - this.gap
      if (low < 0) {
        low = 0
        high = low + this.gap
        this.highSlider.value = high
      }
      this.lowSlider.value = low
      this.updateLowVisuals(low)
    }

    this.updateHighVisuals(high)
  },

  updateLowVisuals(low) {
    const v = Math.max(0, Math.min(100, low))
    // Fresh query fallback: LiveView can replace the value spans/markers on re-renders
    const lv = this.lowValue || this.el.querySelector('[data-role="low-value"]')
    if (lv) lv.textContent = `${v.toFixed(1)}%`
    const lm = this.lowMarker || (this.el.closest('.card')?.querySelector('[data-role="low-marker"]'))
    if (lm) lm.style.left = `${v}%`
  },

  updateHighVisuals(high) {
    const v = Math.max(0, Math.min(100, high))
    const hv = this.highValue || this.el.querySelector('[data-role="high-value"]')
    if (hv) hv.textContent = `${v.toFixed(1)}%`
    const hm = this.highMarker || (this.el.closest('.card')?.querySelector('[data-role="high-marker"]'))
    if (hm) hm.style.left = `${v}%`
  },

  pushThresholds() {
    let low = Math.max(0, Math.min(100, parseFloat(this.lowSlider.value)))
    let high = Math.max(0, Math.min(100, parseFloat(this.highSlider.value)))

    this.pushEvent("set_moisture_thresholds", {
      device_id: this.deviceId,
      low: low,
      high: high
    })
  }
}

Hooks.TelemetryInterval = {
  mounted() {
    this.slider = this.el.querySelector('[data-role="interval-slider"]')
    this.deviceId = this.el.dataset.deviceId

    if (this.slider) {
      this.slider.addEventListener('input', () => {
        const ms = parseInt(this.slider.value, 10) || 60000
        const sec = Math.round(ms / 1000)
        // Always query fresh: the <span> can be replaced by LiveView morph on telemetry/status updates
        const valueEl = this.el.querySelector('[data-role="interval-value"]')
        if (valueEl) valueEl.textContent = `${sec}s`
      })

      this.slider.addEventListener('change', () => {
        const ms = parseInt(this.slider.value, 10) || 60000
        this.pushEvent("set_telemetry_interval", {
          device_id: this.deviceId,
          interval_ms: ms
        })
      })
    }
  },

  updated() {
    // Re-acquire the slider after LiveView morphs (in case the input element itself was replaced)
    const slider = this.el.querySelector('[data-role="interval-slider"]')
    if (slider && slider !== this.slider) {
      this.slider = slider
    }
  }
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

