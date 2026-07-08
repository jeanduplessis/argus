// TerminalNSView.swift
// Argus
//
// NSView subclass that hosts the Metal-rendered Ghostty terminal surface.
// This is the key rendering bridge: it sets up a CAMetalLayer, forwards
// keyboard/mouse events to the Ghostty surface, and manages the Metal
// pipeline lifecycle.

import AppKit
import Metal
import QuartzCore

class TerminalNSView: NSView, @preconcurrency NSTextInputClient {

    // MARK: - Properties

    weak var surface: TerminalSurface?
    private var trackingArea: NSTrackingArea?
    private var currentCursor: NSCursor = .iBeam

    // MARK: - NSView Configuration

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override class var defaultFocusRingType: NSFocusRingType { .none }

    // MARK: - Metal Layer

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = true
        metalLayer.allowsNextDrawableTimeout = false
        return metalLayer
    }

    // MARK: - Initializers

    init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        // Configure the Metal layer after initialization
        setupMetalLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalNSView does not support NSCoder")
    }

    // MARK: - Metal Setup

    private func setupMetalLayer() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.framebufferOnly = true
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            surface?.createSurface()
            updateContentScale()
            updateSurfaceSize()
            updateTrackingArea()

            if let surface = surface?.surface,
               let screen = window?.screen,
               let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            {
                ghostty_surface_set_display_id(surface, displayId)
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        updateSurfaceSize()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateTrackingArea()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateSurfaceSize()
    }

    // MARK: - Sizing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        let scale = window?.backingScaleFactor ?? 1.0
        let w = UInt32(bounds.width * scale)
        let h = UInt32(bounds.height * scale)
        if w > 0, h > 0 {
            surface?.setSize(width: w, height: h)
        }

        // Update the metal layer's drawable size
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }
    }

    private func updateContentScale() {
        guard let ghosttySurface = surface?.surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(ghosttySurface, Double(scale), Double(scale))

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
        }
    }

    // MARK: - Drawing

    override func updateLayer() {
        guard let ghosttySurface = surface?.surface else { return }
        ghostty_surface_draw(ghosttySurface)
        surface?.needsDisplay = false
    }

    // MARK: - Tracking Area (for mouse move events)

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseMoved,
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    func updateCursor(shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            currentCursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            currentCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            currentCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            currentCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            currentCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            currentCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            currentCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            currentCursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            currentCursor = .operationNotAllowed
        default:
            currentCursor = .iBeam
        }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - First Responder

    override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        if let surfaceId = surface?.id {
            NotificationCenter.default.post(
                name: .terminalSurfaceDidBecomeFirstResponder,
                object: surfaceId
            )
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else {
            super.keyDown(with: event)
            return
        }

        var keyInput = ghosttyKeyEvent(from: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)

        // Provide printable text only. Control characters (e.g. Ctrl+C/Ctrl+S)
        // must be encoded by Ghostty from keycode+mods; passing AppKit's raw
        // control-character text makes Ghostty emit CSI-u sequences like
        // "3;5u"/"19;5u" that readline and editors may insert literally.
        if let chars = ghosttyText(from: event), !chars.isEmpty,
           let firstByte = chars.utf8.first, firstByte >= 0x20 {
            chars.withCString { ptr in
                keyInput.text = ptr
                _ = ghostty_surface_key(ghosttySurface, keyInput)
            }
        } else {
            _ = ghostty_surface_key(ghosttySurface, keyInput)
        }

    }

    override func keyUp(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else {
            super.keyUp(with: event)
            return
        }

        var keyInput = ghosttyKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        keyInput.text = nil

        _ = ghostty_surface_key(ghosttySurface, keyInput)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else {
            super.flagsChanged(with: event)
            return
        }

        // Determine if this is a press or release based on whether the flag is set
        let isPress = isModifierPress(event: event)

        var keyInput = ghosttyKeyEvent(from: event, action: isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        keyInput.text = nil

        _ = ghostty_surface_key(ghosttySurface, keyInput)
    }

    private func ghosttyKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var keyInput = ghostty_input_key_s()
        keyInput.action = action
        keyInput.mods = ghosttyMods(from: event.modifierFlags)
        keyInput.consumed_mods = ghosttyConsumedMods(from: event.modifierFlags)
        keyInput.keycode = UInt32(event.keyCode)
        keyInput.unshifted_codepoint = ghosttyUnshiftedCodepoint(from: event)
        keyInput.composing = false
        keyInput.text = nil
        return keyInput
    }

    /// Determine if a flagsChanged event is a press or release.
    private func isModifierPress(event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 56, 60: return flags.contains(.shift)     // Left/Right Shift
        case 59, 62: return flags.contains(.control)   // Left/Right Control
        case 58, 61: return flags.contains(.option)    // Left/Right Option
        case 55, 54: return flags.contains(.command)   // Left/Right Command
        case 57:     return flags.contains(.capsLock)   // Caps Lock
        case 63:     return flags.contains(.function)   // Fn
        default:     return false
        }
    }

    // MARK: - Text Input (NSTextInputClient / IME Support)

    func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let ghosttySurface = surface?.surface else { return }
        let string: String
        if let s = insertString as? String {
            string = s
        } else if let s = insertString as? NSAttributedString {
            string = s.string
        } else {
            string = String(describing: insertString)
        }

        guard !string.isEmpty else { return }

        string.withCString { ptr in
            ghostty_surface_text(ghosttySurface, ptr, UInt(string.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let ghosttySurface = surface?.surface else { return }
        let text: String
        if let s = string as? String {
            text = s
        } else if let s = string as? NSAttributedString {
            text = s.string
        } else {
            text = String(describing: string)
        }

        text.withCString { ptr in
            ghostty_surface_preedit(ghosttySurface, ptr, UInt(text.utf8.count))
        }
    }

    func unmarkText() {
        guard let ghosttySurface = surface?.surface else { return }
        ghostty_surface_preedit(ghosttySurface, nil, 0)
    }

    func hasMarkedText() -> Bool { false }

    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .underlineStyle]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let ghosttySurface = surface?.surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(ghosttySurface, &x, &y, &w, &h)

        // Convert from view coordinates to screen coordinates
        let viewPoint = NSPoint(x: x, y: y)
        let windowPoint = convert(viewPoint, to: nil)
        guard let screenPoint = window?.convertPoint(toScreen: windowPoint) else {
            return NSRect(x: x, y: y, width: w, height: h)
        }
        return NSRect(x: screenPoint.x, y: screenPoint.y - h, width: w, height: h)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func otherMouseDown(with event: NSEvent) {
        let button = mouseButton(from: event.buttonNumber)
        handleMouseButton(GHOSTTY_MOUSE_PRESS, button, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        let button = mouseButton(from: event.buttonNumber)
        handleMouseButton(GHOSTTY_MOUSE_RELEASE, button, event)
    }

    override func mouseMoved(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event)
    }

    override func pressureChange(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else { return }
        ghostty_surface_mouse_pressure(
            ghosttySurface,
            UInt32(event.stage),
            Double(event.pressure)
        )
    }

    // MARK: - Mouse Helpers

    private func handleMouseButton(
        _ state: ghostty_input_mouse_state_e,
        _ button: ghostty_input_mouse_button_e,
        _ event: NSEvent
    ) {
        guard let ghosttySurface = surface?.surface else { return }
        let mods = ghosttyMods(from: event.modifierFlags)

        // Update position before button state
        handleMousePosition(event)

        let consumed = ghostty_surface_mouse_button(ghosttySurface, state, button, mods)
        if !consumed && state == GHOSTTY_MOUSE_PRESS && button == GHOSTTY_MOUSE_RIGHT {
            // Show context menu if Ghostty didn't consume the right-click
            super.rightMouseDown(with: event)
        }
    }

    private func handleMousePosition(_ event: NSEvent) {
        guard let ghosttySurface = surface?.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(from: event.modifierFlags)

        // Ghostty expects unflipped coordinates with origin at top-left
        ghostty_surface_mouse_pos(
            ghosttySurface,
            Double(pos.x),
            Double(pos.y),
            mods
        )
    }

    private func handleScroll(_ event: NSEvent) {
        guard let ghosttySurface = surface?.surface else { return }

        var scrollX = event.scrollingDeltaX
        var scrollY = event.scrollingDeltaY

        // For pixel-based scrolling (trackpad), the values are already in pixels.
        // For line-based scrolling (mouse wheel), multiply by a factor.
        if !event.hasPreciseScrollingDeltas {
            scrollX *= 10
            scrollY *= 10
        }

        // Build scroll mods
        var scrollMods: ghostty_input_scroll_mods_t = 0

        // Momentum phase
        if event.momentumPhase == .began {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue) << 16
        } else if event.momentumPhase == .changed {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 16
        } else if event.momentumPhase == .ended {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 16
        } else if event.momentumPhase == .cancelled {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue) << 16
        }

        // Precise scrolling flag
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 1 // Precise bit
        }

        ghostty_surface_mouse_scroll(
            ghosttySurface,
            scrollX,
            scrollY,
            scrollMods
        )
    }

    /// Convert NSEvent buttonNumber to Ghostty button enum.
    private func mouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        case 8: return GHOSTTY_MOUSE_NINE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }
}

// MARK: - Keycode Mapping

/// Convert macOS virtual keycode to Ghostty key enum.
///
/// macOS keycodes are hardware-level virtual keycodes (not affected by
/// keyboard layout). This mapping covers the full US keyboard layout
/// plus function keys, arrows, numpad, and modifier keys.
func ghosttyKey(from keyCode: UInt16) -> ghostty_input_key_e {
    switch keyCode {
    // Letters (macOS virtual keycodes → GHOSTTY_KEY_*)
    case 0:   return GHOSTTY_KEY_A
    case 1:   return GHOSTTY_KEY_S
    case 2:   return GHOSTTY_KEY_D
    case 3:   return GHOSTTY_KEY_F
    case 4:   return GHOSTTY_KEY_H
    case 5:   return GHOSTTY_KEY_G
    case 6:   return GHOSTTY_KEY_Z
    case 7:   return GHOSTTY_KEY_X
    case 8:   return GHOSTTY_KEY_C
    case 9:   return GHOSTTY_KEY_V
    case 10:  return GHOSTTY_KEY_INTL_BACKSLASH  // § key on ISO keyboards
    case 11:  return GHOSTTY_KEY_B
    case 12:  return GHOSTTY_KEY_Q
    case 13:  return GHOSTTY_KEY_W
    case 14:  return GHOSTTY_KEY_E
    case 15:  return GHOSTTY_KEY_R
    case 16:  return GHOSTTY_KEY_Y
    case 17:  return GHOSTTY_KEY_T
    case 18:  return GHOSTTY_KEY_DIGIT_1
    case 19:  return GHOSTTY_KEY_DIGIT_2
    case 20:  return GHOSTTY_KEY_DIGIT_3
    case 21:  return GHOSTTY_KEY_DIGIT_4
    case 22:  return GHOSTTY_KEY_DIGIT_6
    case 23:  return GHOSTTY_KEY_DIGIT_5
    case 24:  return GHOSTTY_KEY_EQUAL
    case 25:  return GHOSTTY_KEY_DIGIT_9
    case 26:  return GHOSTTY_KEY_DIGIT_7
    case 27:  return GHOSTTY_KEY_MINUS
    case 28:  return GHOSTTY_KEY_DIGIT_8
    case 29:  return GHOSTTY_KEY_DIGIT_0
    case 30:  return GHOSTTY_KEY_BRACKET_RIGHT
    case 31:  return GHOSTTY_KEY_O
    case 32:  return GHOSTTY_KEY_U
    case 33:  return GHOSTTY_KEY_BRACKET_LEFT
    case 34:  return GHOSTTY_KEY_I
    case 35:  return GHOSTTY_KEY_P
    case 36:  return GHOSTTY_KEY_ENTER
    case 37:  return GHOSTTY_KEY_L
    case 38:  return GHOSTTY_KEY_J
    case 39:  return GHOSTTY_KEY_QUOTE
    case 40:  return GHOSTTY_KEY_K
    case 41:  return GHOSTTY_KEY_SEMICOLON
    case 42:  return GHOSTTY_KEY_BACKSLASH
    case 43:  return GHOSTTY_KEY_COMMA
    case 44:  return GHOSTTY_KEY_SLASH
    case 45:  return GHOSTTY_KEY_N
    case 46:  return GHOSTTY_KEY_M
    case 47:  return GHOSTTY_KEY_PERIOD
    case 48:  return GHOSTTY_KEY_TAB
    case 49:  return GHOSTTY_KEY_SPACE
    case 50:  return GHOSTTY_KEY_BACKQUOTE
    case 51:  return GHOSTTY_KEY_BACKSPACE
    case 53:  return GHOSTTY_KEY_ESCAPE

    // Modifier keys
    case 54:  return GHOSTTY_KEY_META_RIGHT       // Right Command
    case 55:  return GHOSTTY_KEY_META_LEFT         // Left Command
    case 56:  return GHOSTTY_KEY_SHIFT_LEFT
    case 57:  return GHOSTTY_KEY_CAPS_LOCK
    case 58:  return GHOSTTY_KEY_ALT_LEFT          // Left Option
    case 59:  return GHOSTTY_KEY_CONTROL_LEFT
    case 60:  return GHOSTTY_KEY_SHIFT_RIGHT
    case 61:  return GHOSTTY_KEY_ALT_RIGHT         // Right Option
    case 62:  return GHOSTTY_KEY_CONTROL_RIGHT
    case 63:  return GHOSTTY_KEY_FN

    // Function keys
    case 122: return GHOSTTY_KEY_F1
    case 120: return GHOSTTY_KEY_F2
    case 99:  return GHOSTTY_KEY_F3
    case 118: return GHOSTTY_KEY_F4
    case 96:  return GHOSTTY_KEY_F5
    case 97:  return GHOSTTY_KEY_F6
    case 98:  return GHOSTTY_KEY_F7
    case 100: return GHOSTTY_KEY_F8
    case 101: return GHOSTTY_KEY_F9
    case 109: return GHOSTTY_KEY_F10
    case 103: return GHOSTTY_KEY_F11
    case 111: return GHOSTTY_KEY_F12
    case 105: return GHOSTTY_KEY_F13
    case 107: return GHOSTTY_KEY_F14
    case 113: return GHOSTTY_KEY_F15
    case 106: return GHOSTTY_KEY_F16
    case 64:  return GHOSTTY_KEY_F17
    case 79:  return GHOSTTY_KEY_F18
    case 80:  return GHOSTTY_KEY_F19
    case 90:  return GHOSTTY_KEY_F20

    // Arrow keys
    case 123: return GHOSTTY_KEY_ARROW_LEFT
    case 124: return GHOSTTY_KEY_ARROW_RIGHT
    case 125: return GHOSTTY_KEY_ARROW_DOWN
    case 126: return GHOSTTY_KEY_ARROW_UP

    // Navigation keys
    case 115: return GHOSTTY_KEY_HOME
    case 119: return GHOSTTY_KEY_END
    case 116: return GHOSTTY_KEY_PAGE_UP
    case 121: return GHOSTTY_KEY_PAGE_DOWN
    case 117: return GHOSTTY_KEY_DELETE              // Forward Delete

    // Numpad
    case 65:  return GHOSTTY_KEY_NUMPAD_DECIMAL
    case 67:  return GHOSTTY_KEY_NUMPAD_MULTIPLY
    case 69:  return GHOSTTY_KEY_NUMPAD_ADD
    case 71:  return GHOSTTY_KEY_NUMPAD_CLEAR
    case 75:  return GHOSTTY_KEY_NUMPAD_DIVIDE
    case 76:  return GHOSTTY_KEY_NUMPAD_ENTER
    case 78:  return GHOSTTY_KEY_NUMPAD_SUBTRACT
    case 81:  return GHOSTTY_KEY_NUMPAD_EQUAL
    case 82:  return GHOSTTY_KEY_NUMPAD_0
    case 83:  return GHOSTTY_KEY_NUMPAD_1
    case 84:  return GHOSTTY_KEY_NUMPAD_2
    case 85:  return GHOSTTY_KEY_NUMPAD_3
    case 86:  return GHOSTTY_KEY_NUMPAD_4
    case 87:  return GHOSTTY_KEY_NUMPAD_5
    case 88:  return GHOSTTY_KEY_NUMPAD_6
    case 89:  return GHOSTTY_KEY_NUMPAD_7
    case 91:  return GHOSTTY_KEY_NUMPAD_8
    case 92:  return GHOSTTY_KEY_NUMPAD_9

    // Special keys
    case 114: return GHOSTTY_KEY_HELP
    case 110: return GHOSTTY_KEY_CONTEXT_MENU

    // Volume / media keys (if present)
    case 72:  return GHOSTTY_KEY_AUDIO_VOLUME_DOWN
    case 73:  return GHOSTTY_KEY_AUDIO_VOLUME_UP
    case 74:  return GHOSTTY_KEY_AUDIO_VOLUME_MUTE

    default:  return GHOSTTY_KEY_UNIDENTIFIED
    }
}

// MARK: - Modifier Mapping

/// Convert NSEvent modifier flags to Ghostty modifier bitmask.
func ghosttyText(from event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }

    if characters.count == 1,
       let scalar = characters.unicodeScalars.first {
        // AppKit reports Ctrl+letter as a single control character. Ghostty
        // expects printable text plus Ctrl in the modifier mask so it can encode
        // legacy terminal controls itself.
        if scalar.value < 0x20 {
            return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }

        // Function keys are represented in the private-use area; don't send that
        // pseudo-text to the terminal.
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
            return nil
        }
    }

    return characters
}

func ghosttyUnshiftedCodepoint(from event: NSEvent) -> UInt32 {
    guard event.type == .keyDown || event.type == .keyUp,
          let chars = event.characters(byApplyingModifiers: []),
          let codepoint = chars.unicodeScalars.first
    else { return 0 }
    return codepoint.value
}

func ghosttyConsumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    ghosttyMods(from: flags.subtracting([.control, .command]))
}

func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue

    if flags.contains(.shift) {
        mods |= GHOSTTY_MODS_SHIFT.rawValue
    }
    if flags.contains(.control) {
        mods |= GHOSTTY_MODS_CTRL.rawValue
    }
    if flags.contains(.option) {
        mods |= GHOSTTY_MODS_ALT.rawValue
    }
    if flags.contains(.command) {
        mods |= GHOSTTY_MODS_SUPER.rawValue
    }
    if flags.contains(.capsLock) {
        mods |= GHOSTTY_MODS_CAPS.rawValue
    }
    if flags.contains(.numericPad) {
        mods |= GHOSTTY_MODS_NUM.rawValue
    }

    return ghostty_input_mods_e(rawValue: mods)
}
