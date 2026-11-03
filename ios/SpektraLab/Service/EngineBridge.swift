//  EngineBridge.swift — the render engine's C ABI, in Swift.
//
//  The engine is C++ compiled into this app (see ios/Tools/gen-project.py) and
//  reached through the `extern "C"` surface in `engine/include/spektrafilm/
//  spk_engine.h`. Nothing here is iOS-specific: the same calls drive the macOS
//  app. What is iOS-specific is *where the pixels come from* and *where they
//  go* — a Photos-picker image in, a Photos-library image out.
//
//  Three rules from the header that this file keeps:
//
//  1. Nothing throws across the boundary. Every entry point is `noexcept`, so
//     a failure is a negative status plus a message from `spk_last_error`.
//     Every call below turns that pair into a Swift `Error`.
//  2. Ownership never crosses. The engine owns what it allocates; the caller
//     owns the device and the pixels. The one exception is `spk_result.texture`,
//     which the engine hands over **+1** — `takeRetainedValue()` here, and
//     `spk_result_free` must NOT be called afterwards.
//  3. Parameters are JSON. A slider is a key in a delta object, not a struct
//     field, so adding a control never changes this boundary.
//
//  The engine's own header is the authority on every signature here; this file
//  only adds the ergonomics Swift needs.

import Foundation
import Metal

// MARK: - Errors

/// What the engine said, in the engine's own words.
enum EngineError: Error, CustomStringConvertible {
    /// `spk_status` was negative. `status` is the raw code; `message` is
    /// `spk_last_error`, which is never NULL.
    case failed(status: Int32, message: String)
    /// The engine's resources are not where they should be. On iOS this means
    /// the bundle is missing `Resources/engine` — almost always a build that
    /// skipped the metallib step.
    case noResources(String)
    /// The device could not be created, or refused the engine's buffers.
    case noDevice
    /// A JSON reply from the engine did not decode.
    case badReply(String)

    var description: String {
        switch self {
        case .failed(let status, let message):
            message.isEmpty ? "engine error \(status)" : "engine error \(status): \(message)"
        case .noResources(let path):
            "the engine's resources are missing at \(path)"
        case .noDevice:
            "this device has no Metal device"
        case .badReply(let s):
            "bad reply from the engine: \(s)"
        }
    }
}

/// The engine's status codes, named. From `spk_engine.h`.
enum EngineStatus {
    static let ok: Int32 = 0
}

// MARK: - The engine handle

/// One engine, and the session opened on it.
///
/// Not an `actor`: the C API is called from the main actor in this app (the
/// engine locks per session and the calls are short), and an actor would put
/// a `await` between every step of a render for no gain. The macOS app uses an
/// actor because it also drives a scheduler; iOS renders on demand instead.
final class SpektraEngine {
    private let engine: OpaquePointer
    /// The engine retains the device, so the app keeps its own reference too.
    let device: MTLDevice

    /// Where the baked constants, the film profiles and the metallib live.
    ///
    /// On iOS this is `Bundle.main.resourceURL/engine` — the folder reference
    /// `Resources/engine` puts in the bundle. The engine resolves every asset
    /// relative to this path, so it must be the directory *containing*
    /// `spektrafilm_constants.bin`, not the file.
    let resources: URL

    /// Creates the engine on `device`.
    ///
    /// - Throws: `EngineError.noResources` when the baked constants are not
    ///   where they should be, `EngineError.noDevice` when Metal is
    ///   unavailable, `EngineError.failed` when the engine refuses to start.
    init(device: MTLDevice, resources: URL? = nil) throws {
        self.device = device
        let dir = resources ?? SpektraEngine.defaultResources()
        self.resources = dir

        let constants = dir.appendingPathComponent("spektrafilm_constants.bin")
        guard FileManager.default.fileExists(atPath: constants.path) else {
            throw EngineError.noResources(dir.path)
        }

        var handle: OpaquePointer?
        let created = dir.path.withCString { path in
            spk_engine_create(path, Unmanaged.passUnretained(device).toOpaque())
        }
        guard let created else {
            // `spk_last_error(NULL)` is the only way to read the error of an
            // engine that never came up: the handle we would ask is the one
            // that does not exist.
            throw EngineError.failed(status: -1, message: String(cString: spk_last_error(nil)))
        }
        self.engine = created
    }

    deinit {
        // The session goes first: `spk_session_release` hands it back to the
        // engine that made it, and `~spk_engine` frees the GPU behind both.
        // That order is deliberate on the C++ side too.
        if let session { spk_session_release(session) }
        spk_engine_destroy(engine)
    }

    private var session: OpaquePointer?

    /// Where the engine's baked resources live in the app bundle.
    ///
    /// The Xcode project carries `ios/SpektraLab/Resources` as a folder
    /// reference, so everything under it lands in the bundle at
    /// `Resources/`. The engine's assets sit in `Resources/engine/`, and the
    /// engine resolves every one of them relative to that directory — so this
    /// is the *directory*, not the constants file.
    ///
    /// `Bundle.main` is right here: this is the app, not a test bundle (the
    /// macOS app uses `Bundle(for:)` because its unit-test target is
    /// standalone and `Bundle.main` is the test agent there).
    static func defaultResources() -> URL {
        if let env = ProcessInfo.processInfo.environment["SPEKTRAFILM_ENGINE_RESOURCES"],
           !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.url(forResource: "spektrafilm_constants",
                                         withExtension: "bin", subdirectory: "Resources/engine") {
            return bundled.deletingLastPathComponent()
        }
        // A build that skipped `ios/Tools/build-engine.sh bundle` lands here,
        // and the error the caller reports names this path.
        return Bundle.main.bundleURL.appending(path: "Resources/engine")
    }

    /// The engine's own last error on this thread. Never NULL.
    private var lastError: String {
        String(cString: spk_last_error(engine))
    }

    /// The `capabilities` block, verbatim — the engine's own statement of what
    /// it is, not a re-encoding of it.
    var capabilitiesJSON: String { String(cString: spk_capabilities(engine)) }

    /// The engine's parameter schema, verbatim.
    var paramsSchemaJSON: String { String(cString: spk_params_schema(engine)) }

    /// Build identity: version, math mode, and whether the fast-math probe
    /// agreed with it. Worth showing in About: a metallib built without
    /// safe-math is a silent correctness problem, and the engine refuses to
    /// start on one.
    static var buildInfo: String { String(cString: spk_build_info()) }

    // MARK: JSON helpers

    /// Take ownership of a `char*` the engine allocated, decode it, free it.
    private func decode<R: Decodable>(_ buffer: UnsafeMutablePointer<CChar>?, as type: R.Type) throws -> R {
        guard let buffer else { throw EngineError.badReply("no reply") }
        defer { spk_string_free(buffer) }
        let data = Data(bytes: buffer, count: strlen(buffer))
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw EngineError.badReply(String(decoding: data.prefix(400), as: UTF8.self))
        }
    }

    private func encode(_ value: [String: ParamValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: - sessions

    /// Open one frame.
    ///
    /// `pixels` is the decoded frame: tightly packed float32, top row first,
    /// three channels. The engine copies what it keeps, so the caller's buffer
    /// may be released the moment this returns.
    ///
    /// - Parameter delta: applied on open, so the first frame already has its
    ///   film and paper rather than rendering once to find out.
    @discardableResult
    func open(pixels: EnginePixels, params delta: [String: ParamValue] = [:]) throws -> OpenReply {
        // One session at a time: `open` on a new frame replaces the old one.
        if let session { spk_session_release(session) }
        session = nil

        let json = try encode(delta)
        var reply: UnsafeMutablePointer<CChar>?
        var image = spk_image(data: pixels.data, width: UInt32(pixels.width),
                              height: UInt32(pixels.height), channels: 3)
        let handle: OpaquePointer? = json.withCString { deltaPtr in
            withUnsafePointer(to: &image) { spk_open(engine, $0, deltaPtr, &reply) }
        }
        guard let handle else { throw EngineError.failed(status: -1, message: lastError) }
        session = handle
        return try decode(reply, as: OpenReply.self)
    }

    /// Open a frame whose pixels are already on the GPU.
    ///
    /// The engine borrows the buffer for the call and keeps nothing, which
    /// saves a host copy the engine would otherwise repeat: at 45 MP that copy
    /// is 727 MB and ~235 ms. The buffer must be on *this* engine's device, or
    /// the engine refuses it with a message.
    @discardableResult
    func open(devicePixels: DevicePixels, params delta: [String: ParamValue] = [:]) throws -> OpenReply {
        if let session { spk_session_release(session) }
        session = nil

        let json = try encode(delta)
        var reply: UnsafeMutablePointer<CChar>?
        var image = spk_device_image(buffer: devicePixels.buffer, width: UInt32(devicePixels.width),
                                     height: UInt32(devicePixels.height), channels: 3)
        let handle: OpaquePointer? = json.withCString { deltaPtr in
            withUnsafePointer(to: &image) { spk_open_device(engine, $0, deltaPtr, &reply) }
        }
        guard let handle else { throw EngineError.failed(status: -1, message: lastError) }
        session = handle
        return try decode(reply, as: OpenReply.self)
    }

    /// Apply a parameter delta. Cheap for the fields the engine can change in
    /// place; anything outside that rebuilds the pipeline, and the engine says
    /// so in the reply.
    @discardableResult
    func setParams(_ delta: [String: ParamValue]) throws -> SetParamsReply {
        guard let session else { throw EngineError.failed(status: -1, message: "no session is open") }
        let json = try encode(delta)
        var out: UnsafeMutablePointer<CChar>?
        guard json.withCString({ spk_set_params(session, $0, &out) }) == EngineStatus.ok else {
            throw EngineError.failed(status: -1, message: lastError)
        }
        return try decode(out, as: SetParamsReply.self)
    }

    /// The session's current parameters.
    func getParams() throws -> [String: ParamValue] {
        guard let session else { throw EngineError.failed(status: -1, message: "no session is open") }
        var out: UnsafeMutablePointer<CChar>?
        guard spk_get_params(session, &out) == EngineStatus.ok else {
            throw EngineError.failed(status: -1, message: lastError)
        }
        guard let out else { return [:] }
        defer { spk_string_free(out) }
        let data = Data(bytes: out, count: strlen(out))
        // The reply is `{"params": {...}}`; the caller wants the inner object.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = obj["params"] as? [String: Any] else { return [:] }
        var result: [String: ParamValue] = [:]
        for (key, value) in params {
            if let v = value as? Bool { result[key] = .bool(v) }
            else if let v = value as? NSNumber { result[key] = .number(v.doubleValue) }
            else if let v = value as? String { result[key] = .string(v) }
        }
        return result
    }

    /// Compute the enlarger's print exposure and filter pack.
    ///
    /// **This must run before the first render.** Without it the print uses
    /// defaults and the highlights blow out — which looks exactly like a
    /// rendering bug and is not one.
    @discardableResult
    func solve(target: String = "both") throws -> SolveReply {
        guard let session else { throw EngineError.failed(status: -1, message: "no session is open") }
        var out: UnsafeMutablePointer<CChar>?
        guard target.withCString({ spk_solve(session, $0, &out) }) == EngineStatus.ok else {
            throw EngineError.failed(status: -1, message: lastError)
        }
        return try decode(out, as: SolveReply.self)
    }

    /// Pay the fixed per-stock-pair setup before the user is looking, so the
    /// first preview is not the slow one. Idempotent.
    func warmUp(filmStock: String, printStock: String) throws {
        var out: UnsafeMutablePointer<CChar>?
        guard filmStock.withCString({ film in
            printStock.withCString { paper in
                spk_warm_up(engine, film, paper, &out)
            }
        }) == EngineStatus.ok else {
            throw EngineError.failed(status: -1, message: lastError)
        }
        if let out { spk_string_free(out) }
    }

    // MARK: - rendering

    /// Render one tier.
    ///
    /// - Parameter tier: `"live"` for the interactive preview, `"preview"` for
    ///   the middle size, `"full"` for the original resolution.
    /// - Parameter reprints: `true` reuses the cached negative and only reruns
    ///   the print (fast — this is what a slider change wants); `false` forces
    ///   the film side to run again.
    ///
    /// The returned texture is **owned by the caller** (`takeRetainedValue`),
    /// because the engine hands over its only reference: the app caches live
    /// textures so switching frames is instant, and a texture the engine
    /// reused would silently become a different photograph.
    func render(tier: String = "live", reprint: Bool = true) throws -> RenderResult {
        guard let session else { throw EngineError.failed(status: -1, message: "no session is open") }
        var result = spk_result()
        let status = tier.withCString { tierPtr in
            reprint ? spk_reprint(session, tierPtr, &result) : spk_render(session, tierPtr, &result)
        }
        guard status == EngineStatus.ok else {
            throw EngineError.failed(status: status, message: lastError)
        }
        // `+1`: the engine gave away its only reference, ARC owns it now.
        // `spk_result_free` must NOT be called on a result whose texture we
        // took — it would free the pixels out from under the canvas.
        let texture = result.texture.map { Unmanaged<MTLTexture>.fromOpaque($0).takeRetainedValue() }
        let progressID = withUnsafeBytes(of: result.progress_id) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return RenderResult(texture: texture,
                            width: Int(result.width),
                            height: Int(result.height),
                            rowStridePx: Int(result.row_stride_px),
                            elapsedMs: result.elapsed_ms,
                            reprint: result.reprint != 0,
                            negativeWasCached: result.negative_was_cached != 0,
                            progressID: progressID)
    }

    /// Ask the engine to stop a render in flight. Safe from another thread;
    /// the render unwinds at the next node boundary.
    func cancel(progressID: String? = nil) {
        guard let session else { return }
        if let progressID {
            progressID.withCString { spk_cancel(session, $0) }
        } else {
            spk_cancel(session, nil)
        }
    }

    /// The engine's own memory accounting, as JSON. Useful in a diagnostics
    /// screen: the engine's holding is `pool.total_bytes + persistent.bytes`.
    var memoryReportJSON: String { String(cString: spk_memory_report(engine)) }
}

// MARK: - Pixel carriers

/// A decoded frame in host memory: tightly packed float32, top row first,
/// three channels (RGB).
///
/// The engine copies what it keeps, so this can be freed right after `open`.
struct EnginePixels {
    let data: UnsafePointer<Float>
    let width: Int
    let height: Int
}

/// A decoded frame already in GPU-visible memory.
struct DevicePixels {
    /// An `MTLBuffer` on the engine's own device.
    let buffer: UnsafeMutableRawPointer
    let width: Int
    let height: Int
}

/// What a render left behind.
struct RenderResult {
    /// The rendered pixels. Owned by the caller.
    let texture: MTLTexture?
    let width: Int
    let height: Int
    /// Row pitch of the texture's pixels, **in pixels** — `width` rounded up to
    /// the device's linear-texture alignment.
    ///
    /// This is the trap the Android port fell into: each pixel is four uint16
    /// (RGBA), so the byte offset of row `y` is `y * rowStridePx * 4` uint16s,
    /// not `y * rowStridePx`. Getting that wrong makes the export striped.
    let rowStridePx: Int
    let elapsedMs: Double
    /// Whether the negative was reused rather than re-rendered.
    let reprint: Bool
    let negativeWasCached: Bool
    let progressID: String
}

// MARK: - Replies

/// The engine's replies, decoded. Only the fields this app reads are modelled;
/// the engine sends more, and `JSONDecoder` ignores what it does not know.
struct OpenReply: Decodable {
    struct Meta: Decodable {
        let width: Int?
        let height: Int?
        let megapixels: Double?
        let source: String?
    }
    struct DetectedInput: Decodable {
        let inputColorSpace: String?
        // The engine emits this as a JSON *boolean* (`params.io.input_cctf_
        // decoding` is a C++ `bool`), so decoding it as `String?` throws and
        // takes the whole `open` reply down with it.
        let inputCctfDecoding: Bool?
        enum CodingKeys: String, CodingKey {
            case inputColorSpace = "input_color_space"
            case inputCctfDecoding = "input_cctf_decoding"
        }
    }
    let sessionID: String?
    let meta: Meta?
    let detectedInput: DetectedInput?
    // `capabilities` is the full capabilities schema whose values are nested
    // objects, not scalars, so `[String: ParamValue]` cannot decode it and the
    // whole `open` reply would throw. The app never reads it (it re-fetches
    // `spk_capabilities` separately), so drop it and let JSONDecoder ignore
    // the key.

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case meta
        case detectedInput = "detected_input"
    }
}

struct SetParamsReply: Decodable {
    let invalidated: Bool?
    let params: [String: ParamValue]?
}

struct SolveReply: Decodable {
    let autoExposureEV: Double?
    let filterPack: [String: ParamValue]?
    enum CodingKeys: String, CodingKey {
        case autoExposureEV = "auto_exposure_ev"
        case filterPack = "filter_pack"
    }
}
