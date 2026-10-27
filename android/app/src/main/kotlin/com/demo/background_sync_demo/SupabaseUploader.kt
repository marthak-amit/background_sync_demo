package com.demo.background_sync_demo

import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/** Uploads an image to Supabase Storage over its REST API (no SDK) and returns the public URL. */
object SupabaseUploader {
    private const val TAG = "SupabaseUploader"

    val isConfigured: Boolean
        get() = !SupabaseConfig.URL.contains("YOUR_") && !SupabaseConfig.ANON_KEY.contains("YOUR_")

    /** @return public URL on success, null on any failure (the caller keeps the post queued and retries). */
    fun upload(file: File, objectPath: String): String? {
        val base = SupabaseConfig.URL.trimEnd('/')
        val conn = URL("$base/storage/v1/object/${SupabaseConfig.BUCKET}/$objectPath").openConnection() as HttpURLConnection
        return try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 15_000
            conn.readTimeout = (Config.UPLOAD_TIMEOUT_S * 1000).toInt()
            conn.setFixedLengthStreamingMode(file.length())
            conn.setRequestProperty("apikey", SupabaseConfig.ANON_KEY)
            conn.setRequestProperty("Authorization", "Bearer ${SupabaseConfig.ANON_KEY}")
            conn.setRequestProperty("Content-Type", "image/jpeg")
            conn.setRequestProperty("x-upsert", "true") // retries overwrite the same object instead of failing with 409
            file.inputStream().use { input -> conn.outputStream.use { input.copyTo(it) } }
            val code = conn.responseCode
            if (code in 200..299) {
                "$base/storage/v1/object/public/${SupabaseConfig.BUCKET}/$objectPath"
            } else {
                Log.w(TAG, "upload failed $code: ${conn.errorStream?.bufferedReader()?.readText()}")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "upload error: ${e.javaClass.simpleName} ${e.message}")
            null
        } finally {
            conn.disconnect()
        }
    }
}
