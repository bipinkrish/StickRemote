import Flutter
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let receiver = ReceiverBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      FlutterMethodChannel(name: "stickremote/receiver", binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler(receiver.handle)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

private final class ReceiverBridge: NSObject, URLSessionTaskDelegate {
  private var voice: URLSessionWebSocketTask?
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 8
    config.httpShouldSetCookies = false
    config.urlCache = nil
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()
  private lazy var anchor: SecCertificate? = {
    let key = FlutterDartProject.lookupKey(forAsset: "assets/turnstile.der")
    guard let url = Bundle.main.url(forResource: key, withExtension: nil),
          let bytes = try? Data(contentsOf: url) else { return nil }
    return SecCertificateCreateWithData(nil, bytes as CFData)
  }()
  private let keychain: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "io.github.bipinkrish.stickremote",
    kSecAttrAccount as String: "paired-devices"
  ]

  func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust, let root = anchor,
          SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil)) == errSecSuccess,
          SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
          SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
          SecTrustEvaluateWithError(trust, nil) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let failed = FlutterError(code: "receiver", message: "Could not complete \(call.method).", details: nil)
    switch call.method {
    case "read":
      var query = keychain
      query[kSecReturnData as String] = true
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { result(nil) }
      else if status == errSecSuccess, let data = item as? Data {
        result(String(data: data, encoding: .utf8))
      } else { result(failed) }
    case "write":
      guard let value = call.arguments as? String else { result(failed); return }
      let data = Data(value.utf8)
      var status = SecItemUpdate(keychain as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if status == errSecItemNotFound {
        var item = keychain
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = SecItemAdd(item as CFDictionary, nil)
      }
      if status == errSecSuccess { result(nil) } else { result(failed) }
    case "request", "openVoice":
      guard let args = call.arguments as? [String: Any], let host = args["host"] as? String else {
        result(failed); return
      }
      let streaming = call.method == "openVoice"
      let address = streaming ? "wss://\(host):9090/" : "https://\(host):8080\(args["path"] as? String ?? "")"
      guard let url = URL(string: address) else { result(failed); return }
      var request = URLRequest(url: url)
      request.allHTTPHeaderFields = args["headers"] as? [String: String]
      if streaming {
        voice?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: request)
        voice = task
        task.resume()
        task.sendPing { error in
          if error != nil { result(failed) } else { result(nil) }
        }
      } else {
        request.httpMethod = args["method"] as? String
        if request.httpMethod == "POST" { request.httpBody = Data((args["body"] as? String ?? "").utf8) }
        session.dataTask(with: request) { data, response, error in
          guard error == nil, let http = response as? HTTPURLResponse else { result(failed); return }
          result(["status": http.statusCode, "body": String(data: data ?? Data(), encoding: .utf8) ?? ""])
        }.resume()
      }
    case "audio":
      guard let audio = call.arguments as? FlutterStandardTypedData, let socket = voice else {
        result(failed); return
      }
      socket.send(.data(audio.data)) { error in
        if error != nil { result(failed) } else { result(nil) }
      }
    case "closeVoice":
      voice?.cancel(with: .normalClosure, reason: nil)
      voice = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
