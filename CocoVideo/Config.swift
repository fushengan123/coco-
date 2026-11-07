import Foundation

enum Config {

    /// 本地资源内部协议：cocoapp://local/index.html
    /// 用 WKURLSchemeHandler 提供服务，等价于安卓的 file:///android_asset，
    /// 但有真实的 Origin，localStorage / Cookie / Ajax 行为都正常。
    static let scheme = "cocoapp"
    static let host = "local"
    static let startPage = "index.html"

    /// 站点（与 H5 里 SITE 保持一致）
    static let site = "https://dutv.eu.org"

    static let brandName = "COCO影视"

    /// 原生通道与 WebView 共用同一个移动端 UA
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static var homeURL: URL {
        URL(string: "\(scheme)://\(host)/\(startPage)")!
    }

    /// 打包进 .app 的 web 目录
    static var webRoot: URL {
        if let url = Bundle.main.url(forResource: "web", withExtension: nil) {
            return url.standardizedFileURL
        }
        return Bundle.main.bundleURL
    }

    /// documentStart 注入：把安卓的 AndroidBridge 原样搬到 iOS，
    /// H5 里的 if (window.AndroidBridge && AndroidBridge.request) 一行都不用改。
    static let bridgeScript = #"""
    (function () {
      if (window.AndroidBridge) { return; }
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.coco;
      if (!h) { return; }
      function send(o) { try { h.postMessage(o); } catch (e) { } }
      window.AndroidBridge = {
        request: function (url, cb) { send({ m: 'request', url: String(url), cb: String(cb) }); },
        post: function (url, data, cb) { send({ m: 'post', url: String(url), data: String(data == null ? '' : data), cb: String(cb) }); },
        cast: function (url, title) { send({ m: 'cast', url: String(url || ''), title: String(title || '') }); },
        share: function (title, url) { send({ m: 'share', title: String(title || ''), url: String(url || '') }); },
        copy: function (text) { send({ m: 'copy', text: String(text || '') }); },
        openWeb: function (url) { send({ m: 'openWeb', url: String(url || '') }); }
      };
    })();
    """#

    /// documentEnd 注入：刘海安全区 + iOS 播放适配，不改动原有 H5 文件
    static let shimScript = #"""
    (function () {
      try {
        var mv = document.querySelector('meta[name="viewport"]');
        if (mv && mv.content.indexOf('viewport-fit') === -1) {
          mv.content = mv.content + ',viewport-fit=cover';
        }
        var style = document.createElement('style');
        style.textContent = [
          ':root{--sat:0px;--sab:0px}',
          '.topbar{padding-top:calc(12px + var(--sat)) !important}',
          '.back-head{padding-top:calc(12px + var(--sat)) !important}',
          '.search-page-bar{padding-top:calc(12px + var(--sat)) !important}',
          '.page-top{height:auto !important;min-height:calc(50px + var(--sat)) !important;padding-top:var(--sat) !important}',
          '#catTabs{top:calc(48px + var(--sat)) !important}',
          '.sub-row{top:calc(48px + var(--sat)) !important}',
          '.rank-tabs{top:calc(48px + var(--sat)) !important}',
          '.suggest-box{top:calc(62px + var(--sat)) !important}',
          'input,textarea{scroll-margin-top:calc(var(--sat) + 70px)}',
          'body{-webkit-tap-highlight-color:transparent}',
          'video::-webkit-media-controls-start-playback-button{display:none !important}',
          '::-webkit-scrollbar{display:none}'
        ].join('');
        (document.head || document.documentElement).appendChild(style);

        // env() 在 calc 里可用，但 JS 读不到；用探针量出实际安全区，供 sticky 偏移使用
        function measureInsets() {
          try {
            var p = document.createElement('div');
            p.style.cssText = 'position:fixed;left:0;top:0;width:0;height:env(safe-area-inset-top,0px);visibility:hidden;pointer-events:none';
            document.documentElement.appendChild(p);
            var sat = p.getBoundingClientRect().height || 0;
            p.remove();
            document.documentElement.style.setProperty('--sat', sat + 'px');
          } catch (e) { }
        }
        measureInsets();
        setTimeout(measureInsets, 300);

        // 输入框聚焦时 iOS 会把它顶到屏幕最上方，正好钻进灵动岛下面。
        // 键盘弹出后再校一次位置，保证光标始终在安全区内。
        document.addEventListener('focusin', function (e) {
          var t = e.target;
          if (!t || !/^(INPUT|TEXTAREA)$/.test(t.tagName)) return;
          [80, 300, 650].forEach(function (d) {
            setTimeout(function () {
              try {
                var sat = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--sat')) || 0;
                var r = t.getBoundingClientRect();
                if (r.top < sat + 10) { window.scrollBy(0, r.top - sat - 10); }
              } catch (err) { }
            }, d);
          });
        }, true);
      } catch (e) { }

      // iOS 自带 HLS：原生 <video src="x.m3u8"> 比 hls.js 的跨域 MSE 稳，
      // 而且能直接走 AirPlay。把 hls.js 关掉，让 detail.html 走原生分支。
      function useNativeHls() {
        if (window.Hls && window.Hls.isSupported) {
          try {
            Object.defineProperty(window.Hls, 'isSupported', {
              value: function () { return false; },
              configurable: true,
              writable: true
            });
          } catch (e) { }
        }
      }
      useNativeHls();
      setTimeout(useNativeHls, 300);
      setTimeout(useNativeHls, 1200);
    })();
    """#
}

/// JS 字符串安全编码（等价于 Android 的 JSONObject.quote）
enum JSUtil {
    static func quote(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [])) ?? Data("[\"\"]".utf8)
        let text = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }

    static func resp(cb: String, body: String?, err: String?) -> String {
        let b = body.map(quote) ?? "null"
        let e = err.map(quote) ?? "null"
        return "window.Coco&&Coco._nativeResp(\(quote(cb)),\(b),\(e));"
    }
}
