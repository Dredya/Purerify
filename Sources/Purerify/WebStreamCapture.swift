import Foundation
import UIKit
import WebKit

/// Fallback for when YouTube limits direct (InnerTube) streams to the first 1 MB because
/// they lack a PO token. Loads the video in a hidden, muted mobile-web YouTube player;
/// YouTube's own page code (BotGuard) creates the PO token and the final signed audio URL.
/// We catch that URL from the player's network calls and download it ourselves.
enum WebCaptureError: LocalizedError {
    case noWindow
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .noWindow:
            return "Couldn't start the web player."
        case let .timedOut(log):
            return "The web player didn't give an audio stream in time. \(log)"
        }
    }
}

@MainActor
final class WebStreamCapture: NSObject, WKScriptMessageHandler {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<URL, Error>?
    private var seen: [String] = []
    private var webmFallback: URL?
    private var lastState = "no page state"
    private var hlsManifest: URL?

    /// Returns a googlevideo audio URL (with PO token, signature and n already applied).
    static func captureAudioURL(videoID: String, timeout: TimeInterval = 35) async throws -> URL {
        let capture = WebStreamCapture()
        return try await capture.run(videoID: videoID, timeout: timeout)
    }

    private func run(videoID: String, timeout: TimeInterval) async throws -> URL {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first
        else { throw WebCaptureError.noWindow }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "purerify")
        config.userContentController.addUserScript(
            WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Must be in the window at a real size or the player won't load media; it sits
        // behind the app's UI (index 0), so it's never visible.
        let webView = WKWebView(frame: window.bounds, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
        self.webView = webView

        defer { tearDown() }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(videoID)&autoplay=1")!))

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                // WebM (Opus) isn't saved: the library stores .m4a and iOS can't play it reliably.
                var summary = self.seen.isEmpty
                    ? "No media requests seen."
                    : "Seen: " + self.seen.suffix(4).joined(separator: " | ")
                if self.webmFallback != nil { summary += " (only WebM audio offered)" }
                if self.hlsManifest != nil { summary += " (player uses HLS)" }
                summary += " State: \(self.lastState)"
                self.finish(.failure(WebCaptureError.timedOut(summary)))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "purerify")
        webView?.removeFromSuperview()
        webView = nil
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let raw = body["url"] as? String else { return }
        MainActor.assumeIsolated { handle(kind: kind, raw: raw) }
    }

    private func handle(kind: String, raw: String) {
        if kind == "state" {
            lastState = raw
            return
        }
        if raw.contains("manifest.googlevideo.com") {
            seen.append("\(kind):hls-manifest")
            hlsManifest = URL(string: raw)
            return
        }
        guard let components = URLComponents(string: raw) else {
            seen.append("\(kind):\(raw.prefix(30))")
            return
        }
        let items = components.queryItems ?? []
        let mime = items.first(where: { $0.name == "mime" })?.value ?? ""
        let isSABR = items.contains { $0.name == "sabr" && $0.value == "1" }
        seen.append("\(kind):\(isSABR ? "sabr" : (mime.isEmpty ? "?" : mime))")

        guard components.path.contains("/videoplayback"),
              !isSABR,
              mime.hasPrefix("audio/"),
              let url = Self.cleaned(components) else { return }

        if mime.hasPrefix("audio/mp4") {
            finish(.success(url))
        } else if webmFallback == nil {
            webmFallback = url
        }
    }

    /// Strip the player's per-request parameters so we can request our own byte ranges.
    private static func cleaned(_ components: URLComponents) -> URL? {
        var components = components
        let perRequest: Set<String> = ["range", "rn", "rbuf", "ump", "srfvp"]
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?
            .filter { !perRequest.contains($0.name) }
        return components.url
    }

    private static let hookScript = #"""
    (function () {
      if (window.__purerifyHooked) return;
      window.__purerifyHooked = true;
      const post = (kind, url) => {
        try { window.webkit.messageHandlers.purerify.postMessage({ kind: kind, url: String(url) }); } catch (e) {}
      };
      // Media comes from *.googlevideo.com or *.c.youtube.com (/videoplayback).
      const isMedia = (u) => typeof u === 'string' &&
        (u.indexOf('/videoplayback') !== -1 || u.indexOf('googlevideo.com') !== -1);
      const reported = {};
      const postOnce = (kind, url) => { if (!reported[url]) { reported[url] = 1; post(kind, url); } };

      // Catch-all: requests made natively (e.g. HLS by the <video> element) still show
      // up in Resource Timing even though they bypass fetch/XHR.
      setInterval(function () {
        try {
          performance.getEntriesByType('resource').forEach(function (e) {
            if (isMedia(e.name)) postOnce('perf', e.name);
          });
        } catch (e) {}
      }, 1000);

      // Media fetched inside Web Workers bypasses the hooks above: wrap classic workers
      // so they report googlevideo requests too.
      try {
        const OrigWorker = window.Worker;
        window.Worker = function (url, opts) {
          if (opts && opts.type === 'module') return new OrigWorker(url, opts);
          const abs = new URL(String(url), location.href).href;
          const prelude =
            "(function(){var f=self.fetch;self.fetch=function(i){try{var u=typeof i==='string'?i:(i&&i.url);" +
            "if(u&&(String(u).indexOf('/videoplayback')!==-1||String(u).indexOf('googlevideo.com')!==-1))self.postMessage({__purerify:String(u)});}catch(e){}" +
            "return f.apply(this,arguments);};})();importScripts(" + JSON.stringify(abs) + ");";
          let w;
          try {
            w = new OrigWorker(URL.createObjectURL(new Blob([prelude], { type: 'text/javascript' })), opts);
          } catch (e) {
            return new OrigWorker(url, opts);
          }
          w.addEventListener('message', function (ev) {
            if (ev.data && ev.data.__purerify) { ev.stopImmediatePropagation(); postOnce('worker', ev.data.__purerify); }
          });
          return w;
        };
        window.Worker.prototype = OrigWorker.prototype;
      } catch (e) {}

      // Diagnostics: what the page is doing.
      setInterval(function () {
        try {
          const v = document.querySelector('video');
          const mp = document.getElementById('movie_player');
          let res = [];
          try { res = performance.getEntriesByType('resource'); } catch (e) {}
          const hosts = {};
          res.forEach(function (e) { try { hosts[new URL(e.name).host] = 1; } catch (x) {} });
          let playability = null;
          try {
            const pr = (mp && mp.getPlayerResponse && mp.getPlayerResponse()) || window.ytInitialPlayerResponse;
            playability = pr && pr.playabilityStatus ? (pr.playabilityStatus.status + ' ' + (pr.playabilityStatus.reason || '')).trim() : null;
          } catch (e) {}
          const state = {
            page: location.host + location.pathname,
            title: (document.title || '').slice(0, 40),
            playerState: mp && mp.getPlayerState ? mp.getPlayerState() : 'n/a',
            playability: playability,
            requests: res.length,
            hosts: Object.keys(hosts).slice(-6).join(','),
            video: v ? {
              src: String(v.currentSrc || v.src || '').slice(0, 60),
              ready: v.readyState, paused: v.paused, time: Math.round(v.currentTime),
              err: v.error ? v.error.code : null
            } : null,
            mse: typeof window.MediaSource, mms: typeof window.ManagedMediaSource
          };
          post('state', JSON.stringify(state));
        } catch (e) {}
      }, 3000);

      const origFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          const u = typeof input === 'string' ? input : (input && input.url);
          if (isMedia(u)) post('fetch', u);
        } catch (e) {}
        return origFetch.apply(this, arguments);
      };

      const origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { if (isMedia(String(url))) post('xhr', String(url)); } catch (e) {}
        return origOpen.apply(this, arguments);
      };

      const srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (srcDesc && srcDesc.set) {
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          configurable: true,
          get: srcDesc.get,
          set: function (v) { try { post('src', String(v)); } catch (e) {} return srcDesc.set.call(this, v); }
        });
      }

      // Keep the (muted) player playing so it requests audio.
      setInterval(function () {
        const v = document.querySelector('video');
        // playerState 5 = "cued": YouTube's own player must be told to play.
        const mp = document.getElementById('movie_player');
        if (mp && mp.playVideo) {
          try { if (mp.mute) mp.mute(); if (mp.getPlayerState && mp.getPlayerState() !== 1) mp.playVideo(); } catch (e) {}
        }
        if (v) { v.muted = true; if (v.paused) { v.play().catch(function () {}); } }
      }, 1000);

      // Report HLS (diagnostic only; used if the player plays natively).
      setInterval(function () {
        try {
          const pr = window.ytInitialPlayerResponse;
          const hls = pr && pr.streamingData && pr.streamingData.hlsManifestUrl;
          if (hls && !window.__purerifyHls) { window.__purerifyHls = 1; post('hls', hls); }
        } catch (e) {}
      }, 1500);
    })();
    """#
}
