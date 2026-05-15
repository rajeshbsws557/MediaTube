package com.example.media_tube

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Xml
import androidx.mediarouter.media.MediaControlIntent
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.images.WebImage
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URL
import java.net.URLEncoder
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.xmlpull.v1.XmlPullParser

private data class CastTarget(
    val id: String,
    val name: String,
    val type: String,
    val location: String? = null,
    val route: MediaRouter.RouteInfo? = null,
    val dlnaControlUrl: String? = null,
    val rokuHost: String? = null,
)

class CastPlatformBridge(
    private val activity: FlutterFragmentActivity,
    flutterEngine: FlutterEngine,
) : EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL_NAME = "com.rajesh.mediatube/cast"
        private const val EVENT_CHANNEL_NAME = "com.rajesh.mediatube/cast_events"

        private const val EVENT_DEVICES_UPDATED = "devicesUpdated"
        private const val EVENT_CONNECTION_CHANGED = "connectionChanged"
        private const val EVENT_ERROR = "error"

        private const val TYPE_CHROMECAST = "chromecast"
        private const val TYPE_DLNA = "dlna"
        private const val TYPE_ROKU = "roku"
    }

    private val methodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        METHOD_CHANNEL_NAME,
    )
    private val eventChannel = EventChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        EVENT_CHANNEL_NAME,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var isDiscovering = false
    private var connectedDeviceId: String? = null

    private val mediaRouter: MediaRouter = MediaRouter.getInstance(activity)
    private val routeSelector: MediaRouteSelector = MediaRouteSelector.Builder()
        .addControlCategory(
            CastMediaControlIntent.categoryForCast(
                CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID,
            ),
        )
        .addControlCategory(MediaControlIntent.CATEGORY_REMOTE_PLAYBACK)
        .build()

    private var castContext: CastContext? = null

    private val targets = ConcurrentHashMap<String, CastTarget>()
    private val ssdpExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    @Volatile
    private var ssdpRunning = false

    private val mediaRouterCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) {
            addOrUpdateRoute(route)
        }

        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) {
            addOrUpdateRoute(route)
        }

        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) {
            targets.remove(route.id)
            if (connectedDeviceId == route.id) {
                connectedDeviceId = null
                emitConnectionChanged()
            }
            emitDevicesUpdated()
        }

        override fun onRouteSelected(
            router: MediaRouter,
            route: MediaRouter.RouteInfo,
            reason: Int,
        ) {
            if (route.id != router.defaultRoute.id) {
                connectedDeviceId = route.id
                emitConnectionChanged()
            }
        }

        override fun onRouteUnselected(
            router: MediaRouter,
            route: MediaRouter.RouteInfo,
            reason: Int,
        ) {
            if (connectedDeviceId == route.id) {
                connectedDeviceId = null
                emitConnectionChanged()
            }
        }
    }

    init {
        eventChannel.setStreamHandler(this)
        castContext = runCatching { CastContext.getSharedInstance(activity) }.getOrNull()

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDiscovery" -> {
                    startDiscovery()
                    result.success(null)
                }

                "stopDiscovery" -> {
                    stopDiscovery()
                    result.success(null)
                }

                "getDevices" -> {
                    result.success(targets.values.map { it.toMap(it.id == connectedDeviceId) })
                }

                "connectToDevice" -> {
                    val deviceId = call.argument<String>("deviceId")
                    if (deviceId.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(connectToDevice(deviceId))
                    }
                }

                "disconnect" -> {
                    disconnectCurrent()
                    result.success(null)
                }

                "castMedia" -> {
                    val deviceId = call.argument<String>("deviceId")
                    val mediaUrl = call.argument<String>("mediaUrl")
                    val title = call.argument<String>("title") ?: "MediaTube"
                    val subtitle = call.argument<String>("subtitle") ?: ""
                    val mimeType = call.argument<String>("mimeType") ?: "video/mp4"
                    val imageUrl = call.argument<String>("imageUrl")
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L

                    if (mediaUrl.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(
                            castMedia(
                                preferredDeviceId = deviceId,
                                mediaUrl = mediaUrl,
                                title = title,
                                subtitle = subtitle,
                                mimeType = mimeType,
                                imageUrl = imageUrl,
                                positionMs = positionMs,
                            ),
                        )
                    }
                }

                "getConnectedDeviceId" -> {
                    result.success(connectedDeviceId)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun addOrUpdateRoute(route: MediaRouter.RouteInfo) {
        val defaultRouteId = mediaRouter.defaultRoute.id
        if (route.id == defaultRouteId || !route.isEnabled) {
            return
        }

        val routeName = route.name?.toString()?.trim().orEmpty().ifBlank {
            "Remote Display"
        }

        targets[route.id] = CastTarget(
            id = route.id,
            name = routeName,
            type = TYPE_CHROMECAST,
            route = route,
        )

        emitDevicesUpdated()
    }

    private fun startDiscovery() {
        if (isDiscovering) {
            return
        }

        isDiscovering = true
        mediaRouter.addCallback(
            routeSelector,
            mediaRouterCallback,
            MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY,
        )

        mediaRouter.routes.forEach { route ->
            addOrUpdateRoute(route)
        }

        startSsdpDiscovery()
        emitDevicesUpdated()
    }

    private fun stopDiscovery() {
        if (!isDiscovering) {
            return
        }

        isDiscovering = false
        mediaRouter.removeCallback(mediaRouterCallback)
        stopSsdpDiscovery()
    }

    private fun startSsdpDiscovery() {
        if (ssdpRunning) {
            return
        }

        ssdpRunning = true
        ssdpExecutor.execute {
            while (ssdpRunning) {
                runCatching { performSsdpScan() }
                    .onFailure { emitError("Device discovery failed: ${it.message ?: "unknown"}") }

                Thread.sleep(2500)
            }
        }
    }

    private fun stopSsdpDiscovery() {
        ssdpRunning = false
    }

    private fun performSsdpScan() {
        val socket = DatagramSocket().apply {
            soTimeout = 1000
            broadcast = true
        }

        try {
            val targetsToQuery = listOf(
                "urn:schemas-upnp-org:device:MediaRenderer:1",
                "roku:ecp",
                "ssdp:all",
            )

            for (st in targetsToQuery) {
                val request = buildSsdpRequest(st)
                val packet = DatagramPacket(
                    request.toByteArray(Charsets.UTF_8),
                    request.length,
                    InetSocketAddress("239.255.255.250", 1900),
                )
                socket.send(packet)
            }

            val buffer = ByteArray(4096)
            val scanEndAt = System.currentTimeMillis() + 1500
            while (System.currentTimeMillis() < scanEndAt) {
                val responsePacket = DatagramPacket(buffer, buffer.size)
                runCatching { socket.receive(responsePacket) }
                    .onFailure { break }
                    .onSuccess {
                        val text = String(responsePacket.data, 0, responsePacket.length)
                        processSsdpResponse(text)
                    }
            }
        } finally {
            socket.close()
        }
    }

    private fun buildSsdpRequest(st: String): String {
        return "M-SEARCH * HTTP/1.1\r\n" +
            "HOST:239.255.255.250:1900\r\n" +
            "MAN:\"ssdp:discover\"\r\n" +
            "MX:2\r\n" +
            "ST:$st\r\n" +
            "\r\n"
    }

    private fun processSsdpResponse(raw: String) {
        val lines = raw.split("\r\n")
        val headers = mutableMapOf<String, String>()
        for (line in lines) {
            val idx = line.indexOf(':')
            if (idx <= 0) {
                continue
            }

            val key = line.substring(0, idx).trim().lowercase(Locale.US)
            val value = line.substring(idx + 1).trim()
            headers[key] = value
        }

        val location = headers["location"] ?: return
        val st = headers["st"]?.lowercase(Locale.US).orEmpty()
        val usn = headers["usn"] ?: UUID.randomUUID().toString()
        val server = headers["server"]?.lowercase(Locale.US).orEmpty()

        val isRoku = st.contains("roku:ecp") || server.contains("roku")
        if (isRoku) {
            val host = runCatching { Uri.parse(location).host }.getOrNull() ?: return
            val deviceId = "roku:$host"
            val friendlyName = fetchRokuName(host)

            targets[deviceId] = CastTarget(
                id = deviceId,
                name = friendlyName,
                type = TYPE_ROKU,
                location = location,
                rokuHost = host,
            )
            emitDevicesUpdated()
            return
        }

        val stIsRenderer = st.contains("mediarenderer") || st.contains("upnp")
        if (!stIsRenderer) {
            return
        }

        val details = fetchDlnaDetails(location) ?: return
        val deviceId = "dlna:${details.udn.ifBlank { usn }}"

        targets[deviceId] = CastTarget(
            id = deviceId,
            name = details.name,
            type = TYPE_DLNA,
            location = location,
            dlnaControlUrl = details.controlUrl,
        )
        emitDevicesUpdated()
    }

    private fun fetchRokuName(host: String): String {
        val url = URL("http://$host:8060/query/device-info")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = 2000
            readTimeout = 2000
            requestMethod = "GET"
        }

        return runCatching {
            conn.inputStream.use { stream ->
                val xml = stream.bufferedReader().use(BufferedReader::readText)
                val marker = "<user-device-name>"
                val start = xml.indexOf(marker)
                if (start == -1) {
                    return@use "Roku"
                }
                val end = xml.indexOf("</user-device-name>", start)
                if (end == -1) {
                    "Roku"
                } else {
                    xml.substring(start + marker.length, end).ifBlank { "Roku" }
                }
            }
        }.getOrDefault("Roku")
    }

    private data class DlnaDetails(
        val udn: String,
        val name: String,
        val controlUrl: String,
    )

    private fun fetchDlnaDetails(location: String): DlnaDetails? {
        val locationUrl = URL(location)
        val conn = (locationUrl.openConnection() as HttpURLConnection).apply {
            connectTimeout = 3000
            readTimeout = 3000
            requestMethod = "GET"
        }

        val baseUrl = "${locationUrl.protocol}://${locationUrl.host}:${if (locationUrl.port == -1) locationUrl.defaultPort else locationUrl.port}"
        val xml = conn.inputStream.use { stream ->
            BufferedReader(InputStreamReader(stream)).use(BufferedReader::readText)
        }

        val parser = Xml.newPullParser()
        parser.setInput(xml.reader())

        var eventType = parser.eventType
        var currentTag: String? = null
        var friendlyName = "DLNA Device"
        var udn = ""
        var insideAvTransportService = false
        var controlUrl: String? = null

        while (eventType != XmlPullParser.END_DOCUMENT) {
            when (eventType) {
                XmlPullParser.START_TAG -> {
                    currentTag = parser.name
                    if (currentTag == "service") {
                        insideAvTransportService = false
                    }
                }

                XmlPullParser.TEXT -> {
                    val value = parser.text?.trim().orEmpty()
                    if (value.isEmpty()) {
                        eventType = parser.next()
                        continue
                    }

                    when (currentTag) {
                        "friendlyName" -> friendlyName = value
                        "UDN" -> udn = value
                        "serviceType" -> {
                            insideAvTransportService = value.contains(
                                "urn:schemas-upnp-org:service:AVTransport",
                                ignoreCase = true,
                            )
                        }

                        "controlURL" -> {
                            if (insideAvTransportService) {
                                controlUrl = toAbsoluteUrl(baseUrl, value)
                            }
                        }
                    }
                }

                XmlPullParser.END_TAG -> {
                    if (parser.name == "service") {
                        insideAvTransportService = false
                    }
                    currentTag = null
                }
            }

            eventType = parser.next()
        }

        val finalControlUrl = controlUrl ?: return null
        return DlnaDetails(
            udn = udn,
            name = friendlyName,
            controlUrl = finalControlUrl,
        )
    }

    private fun toAbsoluteUrl(baseUrl: String, value: String): String {
        return if (value.startsWith("http://") || value.startsWith("https://")) {
            value
        } else {
            val normalized = if (value.startsWith('/')) value else "/$value"
            "$baseUrl$normalized"
        }
    }

    private fun connectToDevice(deviceId: String): Boolean {
        val target = targets[deviceId] ?: return false
        return when (target.type) {
            TYPE_CHROMECAST -> {
                val route = target.route ?: return false
                mediaRouter.selectRoute(route)
                connectedDeviceId = target.id
                emitConnectionChanged()
                true
            }

            TYPE_DLNA,
            TYPE_ROKU,
            -> {
                connectedDeviceId = target.id
                emitConnectionChanged()
                true
            }

            else -> false
        }
    }

    private fun disconnectCurrent() {
        val id = connectedDeviceId ?: return
        val target = targets[id]
        if (target?.type == TYPE_CHROMECAST) {
            mediaRouter.selectRoute(mediaRouter.defaultRoute)
            val castSession = castContext?.sessionManager?.currentCastSession
            castSession?.remoteMediaClient?.stop()
            castContext?.sessionManager?.endCurrentSession(true)
        }

        connectedDeviceId = null
        emitConnectionChanged()
    }

    private fun castMedia(
        preferredDeviceId: String?,
        mediaUrl: String,
        title: String,
        subtitle: String,
        mimeType: String,
        imageUrl: String?,
        positionMs: Long,
    ): Boolean {
        val deviceId = preferredDeviceId ?: connectedDeviceId
        val target = if (deviceId != null) targets[deviceId] else null

        if (target == null) {
            emitError("No cast target connected")
            return false
        }

        return when (target.type) {
            TYPE_CHROMECAST -> castToChromecast(
                mediaUrl = mediaUrl,
                title = title,
                subtitle = subtitle,
                mimeType = mimeType,
                imageUrl = imageUrl,
                positionMs = positionMs,
            )

            TYPE_DLNA -> castToDlna(target, mediaUrl)
            TYPE_ROKU -> castToRoku(target, mediaUrl)
            else -> false
        }
    }

    private fun castToChromecast(
        mediaUrl: String,
        title: String,
        subtitle: String,
        mimeType: String,
        imageUrl: String?,
        positionMs: Long,
    ): Boolean {
        val session = castContext?.sessionManager?.currentCastSession
        val remoteClient: RemoteMediaClient = session?.remoteMediaClient ?: run {
            emitError("Chromecast session not ready")
            return false
        }

        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
            putString(MediaMetadata.KEY_TITLE, title)
            putString(MediaMetadata.KEY_SUBTITLE, subtitle)
            if (!imageUrl.isNullOrBlank()) {
                addImage(WebImage(Uri.parse(imageUrl)))
            }
        }

        val mediaInfo = MediaInfo.Builder(mediaUrl)
            .setContentType(mimeType)
            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
            .setMetadata(metadata)
            .build()

        val request = MediaLoadRequestData.Builder()
            .setMediaInfo(mediaInfo)
            .setAutoplay(true)
            .setCurrentTime(positionMs)
            .build()

        remoteClient.load(request)
        return true
    }

    private fun castToDlna(target: CastTarget, mediaUrl: String): Boolean {
        val controlUrl = target.dlnaControlUrl ?: return false

        val setUriBody = """
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>${escapeXml(mediaUrl)}</CurrentURI>
              <CurrentURIMetaData></CurrentURIMetaData>
            </u:SetAVTransportURI>
        """.trimIndent()

        val playBody = """
            <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <Speed>1</Speed>
            </u:Play>
        """.trimIndent()

        val setUriSuccess = sendSoapAction(
            controlUrl = controlUrl,
            action = "SetAVTransportURI",
            body = setUriBody,
        )
        if (!setUriSuccess) {
            emitError("DLNA target rejected stream URL")
            return false
        }

        val playSuccess = sendSoapAction(
            controlUrl = controlUrl,
            action = "Play",
            body = playBody,
        )
        if (!playSuccess) {
            emitError("DLNA target failed to start playback")
        }
        return playSuccess
    }

    private fun castToRoku(target: CastTarget, mediaUrl: String): Boolean {
        val host = target.rokuHost ?: return false
        val encodedUrl = URLEncoder.encode(mediaUrl, Charsets.UTF_8.name())
        val requestUrl = URL("http://$host:8060/input/15985?t=p&u=$encodedUrl")
        val conn = (requestUrl.openConnection() as HttpURLConnection).apply {
            connectTimeout = 3000
            readTimeout = 3000
            requestMethod = "POST"
            doOutput = true
            outputStream.use { }
        }

        return runCatching {
            conn.responseCode in 200..299
        }.getOrElse {
            emitError("Roku playback request failed: ${it.message ?: "unknown"}")
            false
        }
    }

    private fun sendSoapAction(
        controlUrl: String,
        action: String,
        body: String,
    ): Boolean {
        val envelope = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope
              xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
              s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                $body
              </s:Body>
            </s:Envelope>
        """.trimIndent()

        val conn = (URL(controlUrl).openConnection() as HttpURLConnection).apply {
            connectTimeout = 4000
            readTimeout = 4000
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"")
            setRequestProperty(
                "SOAPACTION",
                "\"urn:schemas-upnp-org:service:AVTransport:1#$action\"",
            )
        }

        return runCatching {
            conn.outputStream.use { stream ->
                stream.write(envelope.toByteArray(Charsets.UTF_8))
            }
            conn.responseCode in 200..299
        }.getOrElse {
            emitError("DLNA action $action failed: ${it.message ?: "unknown"}")
            false
        }
    }

    private fun escapeXml(raw: String): String {
        return raw
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;")
    }

    private fun CastTarget.toMap(isConnected: Boolean): Map<String, Any?> {
        return mapOf(
            "id" to id,
            "name" to name,
            "type" to type,
            "isConnected" to isConnected,
            "location" to location,
        )
    }

    private fun emitDevicesUpdated() {
        val payload = mapOf(
            "event" to EVENT_DEVICES_UPDATED,
            "devices" to targets.values
                .sortedBy { it.name.lowercase(Locale.US) }
                .map { it.toMap(it.id == connectedDeviceId) },
        )

        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    private fun emitConnectionChanged() {
        val payload = mapOf(
            "event" to EVENT_CONNECTION_CHANGED,
            "connectedDeviceId" to connectedDeviceId,
        )

        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    private fun emitError(message: String) {
        val payload = mapOf(
            "event" to EVENT_ERROR,
            "message" to message,
        )

        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    fun dispose() {
        stopDiscovery()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        ssdpExecutor.shutdownNow()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emitDevicesUpdated()
        emitConnectionChanged()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
