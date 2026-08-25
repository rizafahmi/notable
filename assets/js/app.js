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
import {hooks as colocatedHooks} from "phoenix-colocated/notable"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {}
import confetti from "../vendor/canvas-confetti"

Hooks.PlaySound = {
  mounted() {
    setTimeout(() => {
      // Play sound
      this.el.play().catch(error => {
        if (error.name === "NotAllowedError") {
          console.warn(
            "🔈 Autoplay blocked by browser. This is expected in Chrome/Safari during local testing.\n" +
            "👉 Click anywhere on the overlay page to allow sound, then replay the alert.\n" +
            "ℹ️ Note: OBS Browser Sources bypass this restriction automatically."
          )
        } else {
          console.error("Audio playback failed:", error)
        }
      })

      // Fire confetti celebration
      const duration = 4000;
      const end = Date.now() + duration;

      (function frame() {
        // Accents colors matching oklch(75% 0.14 165) ~ #10b981 green-ish and oklch(75% 0.14 65) ~ #eab308 orange/yellow-ish
        confetti({
          particleCount: 5,
          angle: 60,
          spread: 55,
          origin: { x: 0, y: 0.8 },
          colors: ['#79bd65', '#ea3d54', '#ee7b2a', '#ffffff']
        });
        confetti({
          particleCount: 5,
          angle: 120,
          spread: 55,
          origin: { x: 1, y: 0.8 },
          colors: ['#79bd65', '#ea3d54', '#ee7b2a', '#ffffff']
        });

        if (Date.now() < end) {
          requestAnimationFrame(frame);
        }
      }());
    }, 1500)
  }
}

// ===== Animated QR Canvas Hook =====
//
// Draws the QR matrix with a travelling data-flow wave, lightning-bolt data
// modules, pathway pulses and colour-coded finder patterns.
//
// Every colour it paints comes from the palette in `Notable.Qr`, handed over as
// a data attribute. That is deliberate: the scannability budget is enforced by
// Elixir tests against that palette, and animating only *between* palette
// colours keeps every intermediate frame inside the budget too (sRGB blends are
// never lighter than their lighter endpoint). Introducing a colour here that is
// not in the palette would escape that guarantee.
Hooks.QrCanvas = {
  mounted() {
    this._start()
    // ResizeObserver covers window resizes and the expand/minimize cycle
    // (`display: none` -> visible). A window listener alone misses re-expand,
    // and would also see clientWidth 0 while minimized.
    this._onResize = () => this._resize()
    if (typeof ResizeObserver !== "undefined") {
      this._ro = new ResizeObserver(this._onResize)
      this._ro.observe(this.el)
    } else {
      window.addEventListener("resize", this._onResize)
    }
  },

  destroyed() {
    if (this._raf) cancelAnimationFrame(this._raf)
    this._raf = null
    if (this._ro) {
      this._ro.disconnect()
      this._ro = null
    } else if (this._onResize) {
      window.removeEventListener("resize", this._onResize)
    }
  },

  _start() {
    const el = this.el

    try {
      this.matrix = JSON.parse(el.dataset.matrix || "[]")
      this.palette = JSON.parse(el.dataset.palette || "null")
    } catch (_e) {
      return
    }

    this.size = Number(el.dataset.size) || this.matrix.length
    this.quiet = Number(el.dataset.quiet) || 0
    if (!this.size || !this.matrix.length || !this.palette) return

    this.ctx = el.getContext("2d")
    if (!this.ctx) return

    this.boltPath = this._buildBoltPath()
    this.runs = this._buildPathways()
    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    this._resize()

    if (this.reducedMotion) {
      this._draw(0)
      return
    }

    const tick = (now) => {
      this._draw(now)
      this._raf = requestAnimationFrame(tick)
    }
    this._raf = requestAnimationFrame(tick)
  },

  _resize() {
    if (!this.ctx) return
    // Always render at least 2x. At one device pixel per CSS pixel a module is
    // only ~8px wide and the bolt glyph degrades into speckle; supersampling
    // costs little and is what makes the bolts read as lightning.
    const dpr = Math.min(Math.max(window.devicePixelRatio || 1, 2), 3)
    // While the card is minimized it is `display: none`, so clientWidth is 0.
    // Keep the last good backing store rather than baking the 280 fallback into
    // a 320/260 card the moment it reappears.
    const cssSize = this.el.clientWidth
    if (!cssSize) return
    if (cssSize === this._cssSize && dpr === this._dpr) return

    this._cssSize = cssSize
    this._dpr = dpr
    this.el.width = Math.round(cssSize * dpr)
    this.el.height = Math.round(cssSize * dpr)
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    // Animated mode redraws on the next frame; reduced-motion has no raf loop.
    if (this.reducedMotion) this._draw(0)
    else if (!this._raf) this._draw(performance.now())
  },

  // The bolt glyph as a reusable Path2D in a unit box, scaled about the module
  // centre so `bolt_scale` means the same thing here as it does in Elixir.
  _buildBoltPath() {
    const path = new Path2D()
    const s = this.palette.bolt_scale

    this.palette.bolt_polygon.forEach(([x, y], i) => {
      const px = (x - 0.5) * s + 0.5
      const py = (y - 0.5) * s + 0.5
      if (i === 0) path.moveTo(px, py)
      else path.lineTo(px, py)
    })

    path.closePath()
    return path
  },

  // Horizontal runs of adjacent dark modules, which the pathway pulses travel
  // along. Runs of one or two modules read as flicker rather than flow, so
  // they are skipped.
  _buildPathways() {
    const runs = []

    for (let r = 0; r < this.size; r++) {
      let start = null

      for (let c = 0; c <= this.size; c++) {
        const on = c < this.size && this.matrix[r][c] === 1

        if (on && start === null) {
          start = c
        } else if (!on && start !== null) {
          if (c - start >= 3) runs.push({row: r, from: start, to: c - 1})
          start = null
        }
      }
    }

    return runs
  },

  _finderIndex(row, col) {
    const boxes = finderOrigins(this.size)

    for (let i = 0; i < boxes.length; i++) {
      const [fr, fc] = boxes[i]
      if (row >= fr && row <= fr + 6 && col >= fc && col <= fc + 6) return i
    }

    return null
  },

  // Picks a colour from a cycle at a continuous position, blending between
  // neighbours so transitions are smooth rather than stepped.
  _cycle(colours, position) {
    const n = colours.length
    const scaled = ((position % 1) + 1) % 1 * n
    const index = Math.floor(scaled)
    return blendHex(colours[index], colours[(index + 1) % n], scaled - index)
  },

  // Finder patterns are what a decoder locks onto, so they are drawn as three
  // whole rectangles - 7x7 ring, 5x5 light ring, 3x3 core - snapped to device
  // pixels. Filling them module by module leaves faint antialiased seams
  // across the block, which is both a visual defect and needless noise in the
  // one part of the code that has to be crisp. Only the hue is animated.
  _drawFinders(cell, time) {
    const {ctx, palette, size, quiet} = this
    const snap = (v) => Math.round(v * this._dpr) / this._dpr

    finderOrigins(size).forEach(([fr, fc], i) => {
      const breath = (Math.sin(time * 1.1 + i * 2.1) + 1) / 2
      const colour = blendHex(palette.finders[i], palette.module_cycle[0], breath * 0.5)

      const box = (rowOffset, colOffset, span, fill) => {
        const x = snap((fc + quiet + colOffset) * cell)
        const y = snap((fr + quiet + rowOffset) * cell)
        ctx.fillStyle = fill
        ctx.fillRect(x, y, snap((fc + quiet + colOffset + span) * cell) - x,
                     snap((fr + quiet + rowOffset + span) * cell) - y)
      }

      box(0, 0, 7, colour)
      box(1, 1, 5, palette.background)
      box(2, 2, 3, colour)
    })
  },

  _draw(t) {
    if (!this.ctx || !this._cssSize) return

    const {ctx, size, quiet, palette} = this
    const w = this._cssSize
    const span = size + quiet * 2
    const cell = w / span
    const time = this.reducedMotion ? 0 : t / 1000

    ctx.setTransform(this._dpr, 0, 0, this._dpr, 0, 0)
    ctx.globalCompositeOperation = "source-over"
    ctx.fillStyle = palette.background
    ctx.fillRect(0, 0, w, w)

    // Which pathway packets are lit right now, keyed "row:col".
    const lit = new Map()
    if (!this.reducedMotion) {
      this.runs.forEach((run, i) => {
        const length = run.to - run.from + 1
        const head = ((time * 3.2 + i * 0.37) % 2) * length
        for (let c = run.from; c <= run.to; c++) {
          const distance = Math.abs(c - run.from - head)
          if (distance < 1.6) lit.set(`${run.row}:${c}`, 1 - distance / 1.6)
        }
      })
    }

    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (!this.matrix[r][c]) continue

        // Finders are drawn whole, after this loop.
        if (this._finderIndex(r, c) !== null) continue

        const x = (c + quiet) * cell
        const y = (r + quiet) * cell

        // Diagonal data-flow wave travelling across the matrix.
        const wave = (Math.sin((r + c) * 0.34 - time * 1.9) + 1) / 2
        const pulse = lit.get(`${r}:${c}`) || 0

        const base = this._cycle(palette.module_cycle, wave * 0.5 + time * 0.05)
        ctx.fillStyle = pulse > 0 ? blendHex(base, palette.pulse, pulse) : base

        const inset = cell * 0.02
        const s = cell - inset * 2
        ctx.beginPath()
        if (typeof ctx.roundRect === "function") {
          ctx.roundRect(x + inset, y + inset, s, s, Math.min(s * 0.2, 3))
        } else {
          ctx.rect(x + inset, y + inset, s, s)
        }
        ctx.fill()

        // Lightning bolt, brightening as the wave and any pathway pulse pass.
        const boltPos = wave * 0.6 + time * 0.11 + pulse * 0.3
        ctx.fillStyle = this._cycle(palette.bolt_cycle, boltPos)
        ctx.save()
        ctx.translate(x, y)
        ctx.scale(cell, cell)
        ctx.fill(this.boltPath)
        ctx.restore()
      }
    }

    this._drawFinders(cell, time)

    if (this.reducedMotion) return

    // Scanner sweep. `multiply` can only darken, so the band tints the white
    // quiet areas without ever lifting a dark module toward the threshold.
    const sweepY = ((time * 0.28) % 1) * w
    const height = w * 0.13
    const gradient = ctx.createLinearGradient(0, sweepY - height, 0, sweepY + height)
    gradient.addColorStop(0, "#ffffff")
    gradient.addColorStop(0.42, palette.sweep)
    gradient.addColorStop(0.5, palette.sweep_core)
    gradient.addColorStop(0.58, palette.sweep)
    gradient.addColorStop(1, "#ffffff")

    ctx.globalCompositeOperation = palette.sweep_composite
    ctx.fillStyle = gradient
    ctx.fillRect(0, sweepY - height, w, height * 2)
    ctx.globalCompositeOperation = "source-over"
  }
}

// Top-left corners of the three finder patterns, matching
// `Notable.Qr.finder_positions/1`.
function finderOrigins(size) {
  return [[0, 0], [0, size - 7], [size - 7, 0]]
}

// Blends two `#rrggbb` colours in sRGB, matching `Notable.Qr.blend/3`.
// Returns `#rrggbb` (not `rgb(...)`) so callers can feed the result straight
// back in - pathway pulses blend the wave colour into `palette.pulse`.
function blendHex(from, to, amount) {
  const a = parseInt(from.slice(1), 16)
  const b = parseInt(to.slice(1), 16)
  const mix = (shift) => {
    const x = (a >> shift) & 255
    const y = (b >> shift) & 255
    return Math.round(x + (y - x) * amount)
  }
  const hex = (n) => n.toString(16).padStart(2, "0")
  return `#${hex(mix(16))}${hex(mix(8))}${hex(mix(0))}`
}

// ===== QR Code Page Hook =====
Hooks.QrCode = {
  mounted() {
    this._initExpandMinimize()

    this.handleEvent("qr:download", () => this._downloadPNG())
    this.handleEvent("qr:share", ({url}) => this._share(url))
  },

  destroyed() {
    if (this._expandTimer) clearTimeout(this._expandTimer)
    if (this._minimizeTimer) clearTimeout(this._minimizeTimer)
  },

  _initExpandMinimize() {
    const wrapper = this.el.querySelector("#overlayWrapper")
    if (!wrapper) return

    const pill = this.el.querySelector("#minimizedPill")
    if (pill) {
      pill.addEventListener("click", () => {
        wrapper.classList.remove("is-minimized")
        wrapper.classList.add("is-expanded")
      })
    }

    // Auto-cycle: expanded for 3 min, minimized for 15s
    const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    if (prefersReducedMotion) return

    const EXPANDED_MS = 180000
    const MINIMIZED_MS = 15000
    let isPaused = false

    const minimize = () => {
      if (isPaused) return
      wrapper.classList.remove("is-expanded")
      wrapper.classList.add("is-minimized")
      this._stopTimerBar()
      this._minimizeTimer = setTimeout(expand, MINIMIZED_MS)
    }

    const expand = () => {
      if (isPaused) return
      wrapper.classList.remove("is-minimized")
      wrapper.classList.add("is-expanded")
      this._startTimerBar(EXPANDED_MS)
      this._expandTimer = setTimeout(minimize, EXPANDED_MS)
    }

    this._startTimerBar(EXPANDED_MS)
    this._expandTimer = setTimeout(minimize, EXPANDED_MS)

    // Pause on hover
    wrapper.addEventListener("mouseenter", () => {
      isPaused = true
      if (this._expandTimer) { clearTimeout(this._expandTimer); this._expandTimer = null }
      if (this._minimizeTimer) { clearTimeout(this._minimizeTimer); this._minimizeTimer = null }
      this._stopTimerBar()
    })
    wrapper.addEventListener("mouseleave", () => {
      isPaused = false
      if (wrapper.classList.contains("is-expanded")) {
        this._startTimerBar(EXPANDED_MS)
        this._expandTimer = setTimeout(minimize, EXPANDED_MS)
      } else {
        this._minimizeTimer = setTimeout(expand, MINIMIZED_MS)
      }
    })
  },

  _startTimerBar(durationMs) {
    const timerBar = this.el.querySelector("#timerBar")
    if (!timerBar) return
    timerBar.style.animation = "none"
    void timerBar.offsetWidth
    timerBar.style.animation = `qr-timer-drain ${durationMs}ms linear forwards`
  },

  _stopTimerBar() {
    const timerBar = this.el.querySelector("#timerBar")
    if (timerBar) timerBar.style.animation = "none"
  },

  // Renders the hidden, unanimated SVG to a PNG. The download deliberately
  // bypasses the canvas: what a user saves should be a plain, maximally
  // scannable QR, not a frame of the animation.
  _downloadPNG() {
    const svgEl = this.el.querySelector("#qr-svg-hidden svg")
    if (!svgEl) return

    const svgData = new XMLSerializer().serializeToString(svgEl)

    // A `blob:` URL would be blocked here: the page's CSP allows `img-src`
    // from 'self', `data:` and https only. Base64 keeps it inside `data:`.
    const encoded = window.btoa(unescape(encodeURIComponent(svgData)))
    const img = new Image()

    img.onload = () => {
      // The SVG carries explicit width/height, so fall back only if a browser
      // reports nothing rather than silently rasterising at the 150px default.
      const side = img.naturalWidth || 280
      const scale = 4
      const canvas = document.createElement("canvas")
      canvas.width = side * scale
      canvas.height = side * scale

      const ctx = canvas.getContext("2d")
      ctx.fillStyle = "#ffffff"
      ctx.fillRect(0, 0, canvas.width, canvas.height)
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height)

      const a = document.createElement("a")
      a.href = canvas.toDataURL("image/png")
      a.download = "qr-code.png"
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
    }

    img.src = "data:image/svg+xml;base64," + encoded
  },

  _share(url) {
    if (navigator.share) {
      navigator.share({ title: "Livestream Feedback", url: url }).catch(() => {})
    } else {
      // Fallback: copy to clipboard
      navigator.clipboard.writeText(url).then(() => {
        this._showToast("Link copied to clipboard!")
      }).catch(() => {
        this._showToast("Copy failed. URL: " + url)
      })
    }
  },

  _showToast(message) {
    const toast = document.createElement("div")
    toast.textContent = message
    toast.style.cssText = `
      position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
      background: rgba(31, 29, 46, 0.92); color: #e0def4; padding: 12px 24px;
      border-radius: 9999px; border: 1px solid rgba(196, 167, 231, 0.4);
      font-size: 14px; font-weight: 600; z-index: 9999;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
      animation: qr-cta-badge-float 3s ease-in-out infinite;
    `
    document.body.appendChild(toast)
    setTimeout(() => toast.remove(), 3000)
  }
}

// ===== Flash Auto-Hide Hook =====
// Auto-dismisses toast/flash notices after a few seconds so they don't
// stick around indefinitely. The timer resets on `updated` so a second
// flash (e.g. another form submission) gets a fresh window. Connection
// error toasts opt out via `auto_hide={false}` and stay managed by
// `phx-connected` / `phx-disconnected`.
Hooks.FlashAutoHide = {
  mounted() {
    this._flashGeneration = this.el.dataset.flashGeneration
    this._scheduleClear()
  },
  updated() {
    const flashGeneration = this.el.dataset.flashGeneration

    if (flashGeneration !== this._flashGeneration) {
      this._flashGeneration = flashGeneration
      this._scheduleClear()
    }
  },
  destroyed() {
    this._clearTimer()
  },
  _scheduleClear() {
    this._clearTimer()
    const key = this.el.dataset.flashKey
    if (!key) return
    const flashGeneration = this._flashGeneration

    this._timer = setTimeout(() => {
      if (this.el.dataset.flashGeneration === flashGeneration) {
        this.pushEvent("lv:clear-flash", {key})
      }
    }, 5000)
  },
  _clearTimer() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
  }
}

// ===== Feedback Word Cloud Layout Hook =====
//
// Packs the rendered feedback words into a rough ellipse: measure each word as
// the browser actually laid it out, then spiral outwards from the centre until
// a gap is found that the word fits into.
//
// This hook decides geometry and nothing else. Colour, size and rotation are
// picked by `Notable.WordCloud.Style` and arrive on the element as a
// `cloud-tone-N` class, an inline `font-size` and `data-rotated`. The project
// has no JavaScript test runner, so every decision that can be unit-tested
// lives in Elixir.
//
// Two mechanics here are load-bearing rather than stylistic:
//
//   1. Positions are written into a `<style>` element in `<head>`, not into
//      inline styles. LiveView's DOM patch removes attributes the server
//      template does not own, so an inline `transform` would be wiped the
//      moment another word arrived.
//   2. `.cloud-packed` is flipped on `<html>`, outside the LiveView container,
//      for the same reason. Its absence is also the no-JavaScript fallback:
//      `.cloud-words` stays a centred wrapping list until the hook mounts.
//
// Placement is incremental. A word keeps the position it was first given and
// new words are packed into the space that is left, because words rearranging
// themselves mid-talk is the failure mode this page cannot have. A full
// re-pack happens only when a word genuinely cannot be placed, or when the web
// font finally loads and every measurement taken so far is stale.
const CLOUD_PACKED_CLASS = "cloud-packed"
// Layout-space pixels kept between two words. Small, so short words nest into
// tall words' gaps rather than sitting on a shared gutter.
const CLOUD_PADDING = 4
const CLOUD_RADIUS_STEP = 6
const CLOUD_ARC_STEP = 9
const CLOUD_MAX_RADIUS = 4000
// How far a word that has grown may be nudged from where it already sat before
// the packer gives up and re-seeds the search at the cloud's centre.
const CLOUD_NEAR_RADIUS = 260
// Horizontal stretch of the spiral, which is what makes the mass elliptical
// rather than circular.
const CLOUD_ASPECT = 1.75
const CLOUD_FIT_MARGIN = 0.9
const CLOUD_MAX_SCALE = 6

const cloudRound = (value, places = 2) => {
  const factor = 10 ** places
  return Math.round(value * factor) / factor
}

// Words are `[\p{L}\p{N}]+` tokens, so this can never actually fire — it is
// here so a future change to tokenisation cannot turn a word into a selector.
const cloudEscape = (value) => value.replace(/["\\]/g, "\\$&")

Hooks.WordCloud = {
  mounted() {
    this._placed = new Map()
    this._scale = null
    this._offset = {x: 0, y: 0}
    this._firstRender = true

    this._sheet = document.createElement("style")
    this._sheet.setAttribute("data-word-cloud", this.el.id)
    document.head.appendChild(this._sheet)
    document.documentElement.classList.add(CLOUD_PACKED_CLASS)

    // A resize only rescales; it never re-packs, so nothing moves relative to
    // anything else when the projector resolution or OBS canvas changes.
    this._onResize = () => this._fit({allowGrow: true})
    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(this._onResize)
      this._observer.observe(this.el)
    } else {
      window.addEventListener("resize", this._onResize)
    }

    this._layout({repack: true})

    // `font-display: swap` means the first measurement is of the fallback
    // face. Re-pack once the real one lands rather than keeping a layout
    // measured against metrics that no longer apply.
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(() => {
        if (this.el.isConnected) this._layout({repack: true})
      })
    }
  },

  updated() {
    this._layout({repack: false})
  },

  destroyed() {
    document.documentElement.classList.remove(CLOUD_PACKED_CLASS)
    if (this._sheet) {
      this._sheet.remove()
      this._sheet = null
    }
    if (this._observer) {
      this._observer.disconnect()
      this._observer = null
    } else if (this._onResize) {
      window.removeEventListener("resize", this._onResize)
    }
  },

  _layout({repack}) {
    const items = Array.from(this.el.querySelectorAll("[data-word]"))

    if (items.length === 0) {
      this._placed.clear()
      this._render()
      return
    }

    const present = new Set(items.map(el => el.dataset.word))
    for (const word of Array.from(this._placed.keys())) {
      if (!present.has(word)) this._placed.delete(word)
    }

    // `offsetWidth`/`offsetHeight` are layout sizes, so they are unaffected by
    // the fit transform sitting on the container.
    const measured = items.map(el => ({
      word: el.dataset.word,
      rotated: el.dataset.rotated === "true",
      width: el.offsetWidth,
      height: el.offsetHeight
    }))

    let pending
    if (repack) {
      this._placed.clear()
      pending = measured
    } else {
      pending = []
      for (const item of measured) {
        const placed = this._placed.get(item.word)
        if (!placed) {
          pending.push(item)
          continue
        }
        // The word's count crossed a size threshold, so the box it was placed
        // in no longer describes it. Re-place that one word, not the cloud.
        // Compared against the *measured* size, not the collision box: a
        // rotated word's collision box has its dimensions swapped, so
        // comparing that would re-place every vertical word on every update.
        if (placed.measuredWidth !== item.width || placed.measuredHeight !== item.height) {
          this._placed.delete(item.word)
          // Carry where it already sat, so a word that grows on its third
          // mention nudges within its neighbourhood instead of teleporting to
          // whatever gap happens to be nearest the middle of the cloud.
          pending.push({
            ...item,
            origin: {x: placed.x + placed.width / 2, y: placed.y + placed.height / 2}
          })
        }
      }
    }

    if (pending.length === 0) {
      this._fit({allowGrow: false})
      return
    }

    // Biggest first: a greedy spiral only packs tightly when the large words
    // claim the centre before the small ones fill it in.
    pending.sort((a, b) => b.width * b.height - a.width * a.height)

    const obstacles = Array.from(this._placed.values())

    for (const item of pending) {
      const placement = this._spiral(item, obstacles, item.origin)

      if (!placement) {
        // Genuinely out of room next to what is already there. This is the one
        // case that earns moving words that are already on screen.
        if (!repack) {
          this._layout({repack: true})
          return
        }

        // A re-pack that still cannot place a word leaves `_placed` holding
        // only part of the cloud. Render that partial state rather than
        // returning, so the sheet never disagrees with what the hook believes
        // is on screen — otherwise the next update packs the dropped words
        // into space that is still visually occupied.
        this._fit({allowGrow: true})
        return
      }

      obstacles.push(placement)
      this._placed.set(item.word, placement)
    }

    this._fit({allowGrow: repack})
  },

  // Archimedean-ish search: ring by ring outwards from a seed point, testing
  // evenly spaced candidates on each ring. n is at most `max_words`, so the
  // brute-force overlap test against every placed word stays cheap.
  //
  // `origin` is the centre a word already occupied, passed when the word has
  // outgrown its box. It is searched first, within a short radius, so a growing
  // word settles beside itself; only if that neighbourhood is full does the
  // search fall back to the cloud's centre.
  _spiral(item, obstacles, origin) {
    const width = item.rotated ? item.height : item.width
    const height = item.rotated ? item.width : item.height

    // A rotated word turns about its own centre, so the element's untransformed
    // top-left is derived from the centre rather than from the collision box.
    const boxAt = (centreX, centreY) => ({
      word: item.word,
      rotated: item.rotated,
      measuredWidth: item.width,
      measuredHeight: item.height,
      width,
      height,
      x: centreX - width / 2,
      y: centreY - height / 2,
      tx: centreX - item.width / 2,
      ty: centreY - item.height / 2
    })

    const search = (seedX, seedY, maxRadius) => {
      const seed = boxAt(seedX, seedY)
      if (!this._collides(seed, obstacles)) return seed

      for (let radius = CLOUD_RADIUS_STEP; radius <= maxRadius; radius += CLOUD_RADIUS_STEP) {
        const steps = Math.min(240, Math.max(16, Math.round((2 * Math.PI * radius) / CLOUD_ARC_STEP)))
        // Rotate each ring by an irrational-ish amount so candidates from
        // successive rings never line up into visible spokes.
        const phase = radius * 0.137

        for (let step = 0; step < steps; step++) {
          const angle = phase + (step * 2 * Math.PI) / steps
          const candidate = boxAt(
            seedX + Math.cos(angle) * radius * CLOUD_ASPECT,
            seedY + Math.sin(angle) * radius
          )

          if (!this._collides(candidate, obstacles)) return candidate
        }
      }

      return null
    }

    if (origin) {
      const nearby = search(origin.x, origin.y, CLOUD_NEAR_RADIUS)
      if (nearby) return nearby
    }

    return search(0, 0, CLOUD_MAX_RADIUS)
  },

  _collides(rect, obstacles) {
    for (const other of obstacles) {
      if (
        rect.x < other.x + other.width + CLOUD_PADDING &&
        rect.x + rect.width + CLOUD_PADDING > other.x &&
        rect.y < other.y + other.height + CLOUD_PADDING &&
        rect.y + rect.height + CLOUD_PADDING > other.y
      ) {
        return true
      }
    }

    return false
  },

  // Fits the finished cloud to the container as one transform on the list.
  //
  // Words never move relative to each other once placed — that is the stability
  // guarantee. What this does is zoom and centre the whole mass, which is
  // animated over 700ms rather than snapped, so an arriving word settles the
  // cloud instead of scattering it.
  _fit({allowGrow}) {
    if (!this._placed.size) return

    const width = this.el.clientWidth
    const height = this.el.clientHeight
    if (!width || !height) return

    let left = Infinity
    let top = Infinity
    let right = -Infinity
    let bottom = -Infinity
    for (const rect of this._placed.values()) {
      left = Math.min(left, rect.x)
      top = Math.min(top, rect.y)
      right = Math.max(right, rect.x + rect.width)
      bottom = Math.max(bottom, rect.y + rect.height)
    }

    const spanX = Math.max(right - left, 1)
    const spanY = Math.max(bottom - top, 1)
    const fit = Math.min(
      (width * CLOUD_FIT_MARGIN) / spanX,
      (height * CLOUD_FIT_MARGIN) / spanY,
      CLOUD_MAX_SCALE
    )

    // An arriving word may shrink the cloud so it still fits; it may not zoom
    // it back in, which would make the page pulse every time someone submits.
    // A re-pack or a container resize starts the scale over.
    const scale = allowGrow || this._scale === null ? fit : Math.min(this._scale, fit)

    this._scale = scale
    this._offset = {
      x: width / 2 - scale * (left + spanX / 2),
      y: height / 2 - scale * (top + spanY / 2)
    }
    this._render()
  },

  _render() {
    if (!this._sheet) return

    const selector = `#${CSS && CSS.escape ? CSS.escape(this.el.id) : this.el.id}`
    // Measuring forced a style recalc with no transform on these elements, so
    // the very first positions would otherwise animate in from the origin.
    const settle = this._firstRender ? ";transition:none" : ""

    const rules = [
      `${selector}{transform:translate(${cloudRound(this._offset.x)}px,${cloudRound(this._offset.y)}px) ` +
        `scale(${cloudRound(this._scale || 1, 4)})${settle}}`
    ]

    for (const rect of this._placed.values()) {
      const spin = rect.rotated ? " rotate(-90deg)" : ""
      rules.push(
        `${selector} [data-word="${cloudEscape(rect.word)}"]` +
          `{transform:translate(${cloudRound(rect.tx)}px,${cloudRound(rect.ty)}px)${spin};opacity:1}`
      )
    }

    this._sheet.textContent = rules.join("\n")

    if (this._firstRender) {
      this._firstRender = false
      requestAnimationFrame(() => this._render())
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
