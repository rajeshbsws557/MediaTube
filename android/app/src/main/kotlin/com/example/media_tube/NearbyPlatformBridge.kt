package com.example.media_tube

import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap

private data class NearbyPeer(
    val endpointId: String,
    val endpointName: String,
)

class NearbyPlatformBridge(
    private val activity: FlutterFragmentActivity,
    flutterEngine: FlutterEngine,
) : EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL_NAME = "com.rajesh.mediatube/nearby"
        private const val EVENT_CHANNEL_NAME = "com.rajesh.mediatube/nearby_events"

        private const val SERVICE_ID = "com.rajesh.mediatube.offline.share"
        private val STRATEGY = Strategy.P2P_STAR

        private const val EVENT_PEER_FOUND = "peerFound"
        private const val EVENT_PEER_LOST = "peerLost"
        private const val EVENT_CONNECTION_INITIATED = "connectionInitiated"
        private const val EVENT_CONNECTION_RESULT = "connectionResult"
        private const val EVENT_DISCONNECTED = "disconnected"
        private const val EVENT_TRANSFER_UPDATE = "transferUpdate"
        private const val EVENT_FILE_RECEIVED = "fileReceived"
        private const val EVENT_ERROR = "error"
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

    private val connectionsClient: ConnectionsClient = Nearby.getConnectionsClient(activity)

    private val discoveredPeers = ConcurrentHashMap<String, NearbyPeer>()
    private val pendingConnections = ConcurrentHashMap<String, ConnectionInfo>()
    private val connectedPeers = ConcurrentHashMap.newKeySet<String>()
    private val incomingFilePayloads = ConcurrentHashMap<Long, Payload.File>()
    private val outgoingPayloadNames = ConcurrentHashMap<Long, String>()

    private var endpointName: String = defaultEndpointName()
    private var radarRunning: Boolean = false

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            discoveredPeers[endpointId] = NearbyPeer(
                endpointId = endpointId,
                endpointName = info.endpointName,
            )

            emit(
                mapOf(
                    "event" to EVENT_PEER_FOUND,
                    "endpointId" to endpointId,
                    "endpointName" to info.endpointName,
                ),
            )
        }

        override fun onEndpointLost(endpointId: String) {
            discoveredPeers.remove(endpointId)
            emit(
                mapOf(
                    "event" to EVENT_PEER_LOST,
                    "endpointId" to endpointId,
                ),
            )
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            pendingConnections[endpointId] = info
            emit(
                mapOf(
                    "event" to EVENT_CONNECTION_INITIATED,
                    "endpointId" to endpointId,
                    "endpointName" to info.endpointName,
                    "authenticationToken" to info.authenticationToken,
                    "isIncomingConnection" to info.isIncomingConnection,
                ),
            )
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            pendingConnections.remove(endpointId)
            val statusCode = resolution.status.statusCode
            val isSuccess = statusCode == ConnectionsStatusCodes.STATUS_OK

            if (isSuccess) {
                connectedPeers.add(endpointId)
            } else {
                connectedPeers.remove(endpointId)
            }

            emit(
                mapOf(
                    "event" to EVENT_CONNECTION_RESULT,
                    "endpointId" to endpointId,
                    "statusCode" to statusCode,
                    "connected" to isSuccess,
                ),
            )
        }

        override fun onDisconnected(endpointId: String) {
            connectedPeers.remove(endpointId)
            emit(
                mapOf(
                    "event" to EVENT_DISCONNECTED,
                    "endpointId" to endpointId,
                ),
            )
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            if (payload.type == Payload.Type.FILE) {
                incomingFilePayloads[payload.id] = payload.asFile() ?: return
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            val outgoingName = outgoingPayloadNames[update.payloadId]
            emit(
                mapOf(
                    "event" to EVENT_TRANSFER_UPDATE,
                    "endpointId" to endpointId,
                    "payloadId" to update.payloadId,
                    "status" to update.status,
                    "bytesTransferred" to update.bytesTransferred,
                    "totalBytes" to update.totalBytes,
                    "fileName" to outgoingName,
                ),
            )

            if (update.status == PayloadTransferUpdate.Status.SUCCESS) {
                val incoming = incomingFilePayloads.remove(update.payloadId)
                val filePath = incoming?.asJavaFile()?.absolutePath
                if (!filePath.isNullOrBlank()) {
                    emit(
                        mapOf(
                            "event" to EVENT_FILE_RECEIVED,
                            "endpointId" to endpointId,
                            "payloadId" to update.payloadId,
                            "filePath" to filePath,
                        ),
                    )
                }
                outgoingPayloadNames.remove(update.payloadId)
            }

            if (update.status == PayloadTransferUpdate.Status.FAILURE ||
                update.status == PayloadTransferUpdate.Status.CANCELED
            ) {
                incomingFilePayloads.remove(update.payloadId)
                outgoingPayloadNames.remove(update.payloadId)
            }
        }
    }

    init {
        eventChannel.setStreamHandler(this)

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startRadar" -> {
                    endpointName = call.argument<String>("endpointName")?.takeIf { it.isNotBlank() }
                        ?: defaultEndpointName()
                    startRadar()
                    result.success(null)
                }

                "stopRadar" -> {
                    stopRadar()
                    result.success(null)
                }

                "requestConnection" -> {
                    val endpointId = call.argument<String>("endpointId")
                    if (endpointId.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(requestConnection(endpointId))
                    }
                }

                "acceptConnection" -> {
                    val endpointId = call.argument<String>("endpointId")
                    if (endpointId.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(acceptConnection(endpointId))
                    }
                }

                "rejectConnection" -> {
                    val endpointId = call.argument<String>("endpointId")
                    if (endpointId.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        connectionsClient.rejectConnection(endpointId)
                        pendingConnections.remove(endpointId)
                        result.success(true)
                    }
                }

                "disconnectPeer" -> {
                    val endpointId = call.argument<String>("endpointId")
                    if (endpointId.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        connectionsClient.disconnectFromEndpoint(endpointId)
                        connectedPeers.remove(endpointId)
                        result.success(true)
                    }
                }

                "sendFile" -> {
                    val endpointId = call.argument<String>("endpointId")
                    val filePath = call.argument<String>("filePath")
                    if (endpointId.isNullOrBlank() || filePath.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(sendFile(endpointId, filePath))
                    }
                }

                "getPeers" -> {
                    result.success(
                        discoveredPeers.values.map {
                            mapOf(
                                "endpointId" to it.endpointId,
                                "endpointName" to it.endpointName,
                                "isConnected" to connectedPeers.contains(it.endpointId),
                                "isPending" to pendingConnections.containsKey(it.endpointId),
                            )
                        },
                    )
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun startRadar() {
        if (radarRunning) {
            return
        }

        radarRunning = true

        connectionsClient.startAdvertising(
            endpointName,
            SERVICE_ID,
            connectionLifecycleCallback,
            AdvertisingOptions.Builder().setStrategy(STRATEGY).build(),
        ).addOnFailureListener {
            emitError("Advertising failed: ${it.message ?: "unknown"}")
        }

        connectionsClient.startDiscovery(
            SERVICE_ID,
            endpointDiscoveryCallback,
            DiscoveryOptions.Builder().setStrategy(STRATEGY).build(),
        ).addOnFailureListener {
            emitError("Discovery failed: ${it.message ?: "unknown"}")
        }
    }

    private fun stopRadar() {
        radarRunning = false
        connectionsClient.stopAdvertising()
        connectionsClient.stopDiscovery()
        connectionsClient.stopAllEndpoints()

        discoveredPeers.clear()
        pendingConnections.clear()
        connectedPeers.clear()
        incomingFilePayloads.clear()
        outgoingPayloadNames.clear()
    }

    private fun requestConnection(endpointId: String): Boolean {
        connectionsClient.requestConnection(endpointName, endpointId, connectionLifecycleCallback)
            .addOnFailureListener {
                emitError("Connection request failed: ${it.message ?: "unknown"}")
            }
        return true
    }

    private fun acceptConnection(endpointId: String): Boolean {
        connectionsClient.acceptConnection(endpointId, payloadCallback)
            .addOnFailureListener {
                emitError("Accept connection failed: ${it.message ?: "unknown"}")
            }
        return true
    }

    private fun sendFile(endpointId: String, filePath: String): Boolean {
        val file = File(filePath)
        if (!file.exists()) {
            emitError("Cannot send missing file")
            return false
        }

        val payload = Payload.fromFile(file)
        outgoingPayloadNames[payload.id] = file.name
        connectionsClient.sendPayload(endpointId, payload)
            .addOnFailureListener {
                outgoingPayloadNames.remove(payload.id)
                emitError("Failed to send file: ${it.message ?: "unknown"}")
            }
        return true
    }

    private fun defaultEndpointName(): String {
        val model = Build.MODEL?.trim().orEmpty()
        return if (model.isNotBlank()) {
            "MediaTube-$model"
        } else {
            "MediaTube-Android"
        }
    }

    private fun emitError(message: String) {
        emit(
            mapOf(
                "event" to EVENT_ERROR,
                "message" to message,
            ),
        )
    }

    private fun emit(payload: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    fun dispose() {
        stopRadar()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
