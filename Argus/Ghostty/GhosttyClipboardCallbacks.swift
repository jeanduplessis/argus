// GhosttyClipboardCallbacks.swift
// Argus
//
// C callback bridge for Ghostty clipboard reads, writes, and confirmations.

import AppKit
import Foundation

/// One clipboard representation served to or received from Ghostty.
/// Binary-safe: Ghostty's C API no longer guarantees null-terminated data.
struct TerminalClipboardContent: Sendable {
    let mime: String
    let data: Data
}

// swiftlint:disable:next function_parameter_count
func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimesLen: Int,
    _ list: Bool
) -> ghostty_clipboard_read_result_e {
    guard let userdata, let state else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let terminalSurface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    guard let ghosttySurface = terminalSurface.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    // Argus serves plain text only, so unrelated (and potentially large)
    // clipboard representations are never read.
    var contents: [TerminalClipboardContent] = []
    if requestsText(mimes: mimes, mimesLen: mimesLen),
        let text = NSPasteboard.general.string(forType: .string),
        let data = text.data(using: .utf8)
    {
        contents.append(TerminalClipboardContent(mime: "text/plain", data: data))
    }
    let available = list ? ["text/plain"] : []
    guard !contents.isEmpty || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    completeClipboardRequest(ghosttySurface, contents: contents, available: available, state: state)
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

/// Whether any requested MIME type is a text representation Argus can serve.
/// An empty/nil request asks for whatever is available, which includes text.
private func requestsText(mimes: UnsafePointer<UnsafePointer<CChar>?>?, mimesLen: Int) -> Bool {
    guard let mimes, mimesLen > 0 else { return true }
    for index in 0..<mimesLen {
        guard let pointer = mimes[index] else { continue }
        let mime = String(cString: pointer)
        if mime.hasPrefix("text/") || mime == "STRING" || mime == "UTF8_STRING" { return true }
    }
    return false
}

/// Completes a clipboard read request, copying everything into C memory for
/// the duration of the call. Modeled on Ghostty's own macOS integration
/// (macos/Sources/Ghostty/Ghostty.App.swift).
private func completeClipboardRequest(
    _ surface: ghostty_surface_t,
    contents: [TerminalClipboardContent],
    available: [String],
    state: UnsafeMutableRawPointer?,
    confirmed: Bool = false,
    remember: Bool = false
) {
    var cStrings: [UnsafeMutablePointer<CChar>] = []
    var cDatas: [UnsafeMutableRawPointer] = []
    defer {
        cStrings.forEach { free($0) }
        cDatas.forEach { $0.deallocate() }
    }

    var cContents: [ghostty_clipboard_content_s] = []
    for entry in contents {
        guard let mime = strdup(entry.mime) else { continue }
        cStrings.append(mime)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
        cDatas.append(buffer)
        entry.data.withUnsafeBytes { source in
            if let base = source.baseAddress {
                buffer.copyMemory(from: base, byteCount: source.count)
            }
        }
        cContents.append(
            ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: entry.data.count))
    }

    var cAvailable: [UnsafePointer<CChar>?] = []
    for mime in available {
        guard let string = strdup(mime) else { continue }
        cStrings.append(string)
        cAvailable.append(UnsafePointer(string))
    }

    cContents.withUnsafeBufferPointer { contentsBuffer in
        cAvailable.withUnsafeBufferPointer { availableBuffer in
            var complete = ghostty_clipboard_complete_s(
                contents: contentsBuffer.baseAddress,
                contents_len: contentsBuffer.count,
                available: availableBuffer.baseAddress,
                available_len: availableBuffer.count,
                confirmed: confirmed,
                remember: remember)
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
        }
    }
}

func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata, let state, let confirm else { return }
    let terminalSurface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    let payload = confirm.pointee

    // Copy the borrowed C representations: the confirmation is asynchronous
    // and completes with exactly what the user approved, so the clipboard is
    // never re-read.
    var contents: [TerminalClipboardContent] = []
    if let contentsPointer = payload.contents {
        for index in 0..<payload.contents_len {
            let item = contentsPointer[index]
            guard let mime = item.mime else { continue }
            var data = Data()
            if item.len > 0, let pointer = item.data {
                data = Data(bytes: pointer, count: item.len)
            }
            contents.append(TerminalClipboardContent(mime: String(cString: mime), data: data))
        }
    }

    let kind: TerminalClipboardConfirmationKind =
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
            GHOSTTY_CLIPBOARD_REQUEST_LIST:
            .terminalRead
        default:
            .unsafePaste
        }
    let preview =
        contents
        .first(where: { $0.mime.hasPrefix("text/") })
        .flatMap { String(bytes: $0.data, encoding: .utf8) }
    let requestState = TerminalClipboardRequestState(pointer: state)
    let decision = TerminalClipboardDecision(surfaceId: terminalSurface.id) { approved in
        guard let ghosttySurface = terminalSurface.surface else { return }
        if approved {
            completeClipboardRequest(
                ghosttySurface,
                contents: contents,
                available: [],
                state: requestState.pointer,
                confirmed: true
            )
        } else {
            ghostty_surface_deny_clipboard_request(ghosttySurface, requestState.pointer)
        }
    }
    DispatchQueue.main.async {
        TerminalClipboardConfirmationPresenter.shared.present(
            kind: kind,
            surfaceId: decision.surfaceId,
            preview: kind == .unsafePaste ? preview : nil,
            completion: decision.complete
        )
    }
}

func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard count > 0, let contents else { return }

    var clipboardContents: [(mimeType: String, text: String)] = []
    clipboardContents.reserveCapacity(count)
    for index in 0..<count {
        let item = contents[index]
        guard let mime = item.mime else { continue }
        // data is binary-safe with an explicit length, not necessarily
        // null-terminated — decode with the length, never as a C string.
        let text: String =
            if item.len > 0, let data = item.data {
                String(bytes: UnsafeRawBufferPointer(start: data, count: item.len), encoding: .utf8) ?? ""
            } else {
                ""
            }
        clipboardContents.append((String(cString: mime), text))
    }

    guard let surfaceId = callbackSurfaceId(from: userdata) else { return }
    if !confirm {
        writeTerminalClipboard(clipboardContents, to: .general)
        return
    }

    let preview = clipboardContents.first(where: { $0.mimeType.hasPrefix("text/plain") })?.text
    DispatchQueue.main.async {
        TerminalClipboardConfirmationPresenter.shared.present(
            kind: .terminalWrite,
            surfaceId: surfaceId,
            preview: preview
        ) { approved in
            guard approved else { return }
            writeTerminalClipboard(clipboardContents, to: .general)
        }
    }
}
