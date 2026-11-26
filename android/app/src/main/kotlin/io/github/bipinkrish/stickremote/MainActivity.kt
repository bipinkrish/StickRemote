package io.github.bipinkrish.stickremote

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.ByteString.Companion.toByteString
import java.io.IOException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

class MainActivity : FlutterActivity() {
    private val preferences by lazy { getSharedPreferences("pairings", MODE_PRIVATE) }
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    private var voice: WebSocket? = null

    // Each receiver presents a LAN address. Trust exclusively the Turnstile anchor.
    private val receiverClient by lazy {
        val cert = assets.open("flutter_assets/assets/turnstile.der").use {
            CertificateFactory.getInstance("X.509").generateCertificate(it)
        }
        val anchors = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("turnstile", cert)
        }
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            .apply { init(anchors) }.trustManagers
        val tls = SSLContext.getInstance("TLS").apply { init(null, managers, null) }
        OkHttpClient.Builder()
            .sslSocketFactory(tls.socketFactory, managers.filterIsInstance<X509TrustManager>().single())
            .hostnameVerifier { _, _ -> true }
            .followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .callTimeout(5, TimeUnit.SECONDS).build()
    }

    private fun storageKey(): SecretKey {
        val alias = "stickremote.pairings"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build()
        return KeyGenerator.getInstance("AES", "AndroidKeyStore").apply { init(spec) }.generateKey()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "stickremote/receiver")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "read" -> {
                            val saved = preferences.getString("devices", null)
                            result.success(saved?.let {
                                val bytes = Base64.decode(it, Base64.NO_WRAP)
                                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                                cipher.init(Cipher.DECRYPT_MODE, storageKey(), GCMParameterSpec(128, bytes, 0, 12))
                                String(cipher.doFinal(bytes, 12, bytes.size - 12), Charsets.UTF_8)
                            })
                        }
                        "write" -> {
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.ENCRYPT_MODE, storageKey())
                            val encrypted = cipher.iv + cipher.doFinal(call.arguments.toString().toByteArray(Charsets.UTF_8))
                            check(preferences.edit().putString("devices", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
                            result.success(null)
                        }
                        "request", "openVoice" -> {
                            val host = requireNotNull(call.argument<String>("host"))
                            val streaming = call.method == "openVoice"
                            val path = if (streaming) "/" else requireNotNull(call.argument<String>("path"))
                            val port = if (streaming) 9090 else 8080
                            val url = "https://$host:$port$path"
                            val builder = Request.Builder().url(url)
                            call.argument<Map<String, String>>("headers")?.forEach { (k, v) -> builder.header(k, v) }
                            if (streaming) {
                                voice?.cancel()
                                voice = receiverClient.newWebSocket(builder.build(), object : WebSocketListener() {
                                    var opened = false
                                    override fun onOpen(webSocket: WebSocket, response: Response) {
                                        opened = true
                                        result.success(null)
                                    }
                                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                                        if (!opened) result.error("voice", "Could not open the voice connection.", null)
                                    }
                                })
                            } else {
                                if (call.argument<String>("method") == "POST") {
                                    builder.post((call.argument<String>("body") ?: "").toRequestBody(jsonType))
                                }
                                receiverClient.newCall(builder.build()).enqueue(object : Callback {
                                    override fun onFailure(call: Call, e: IOException) {
                                        val timedOut = e is java.io.InterruptedIOException
                                        val message = if (timedOut) "Timed out waiting for Fire TV." else "The connection to Fire TV failed."
                                        result.error("connection", message, e.javaClass.simpleName)
                                    }
                                    override fun onResponse(call: Call, response: Response) {
                                        response.use {
                                            try {
                                                result.success(mapOf("status" to it.code, "body" to (it.body?.string() ?: "")))
                                            } catch (e: IOException) {
                                                result.error("connection", "Incomplete Fire TV response.", null)
                                            }
                                        }
                                    }
                                })
                            }
                        }
                        "audio" -> {
                            check(voice?.send((call.arguments as ByteArray).toByteString()) == true)
                            result.success(null)
                        }
                        "closeVoice" -> { voice?.close(1000, null); voice = null; result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("receiver", "Could not complete ${call.method}.", null)
                }
            }
    }

    override fun onDestroy() {
        voice?.cancel()
        super.onDestroy()
    }
}
