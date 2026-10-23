package com.miyin.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.Rect
import android.media.ExifInterface
import android.os.Build
import android.content.ContentValues
import android.provider.MediaStore
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions

/** Runs bundled Chinese + Latin ML Kit OCR on a picker-owned local image. */
class MiyinAttachmentOcrMethodHandler(context: Context) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    @Volatile private var recognizer: TextRecognizer? = null
    @Volatile private var disposed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "saveTranslatedImage") {
            val encoded = call.argument<String>("dataUrl")
            if (encoded == null || !encoded.startsWith("data:image/jpeg;base64,") || encoded.length > 4_000_000) {
                result.error("image_invalid", "译图数据无效或过大。", null)
                return
            }
            executor.execute {
                try {
                    val bytes = Base64.decode(encoded.substringAfter(','), Base64.DEFAULT)
                    if (bytes.isEmpty() || bytes.size > 3_000_000) throw IOException("译图数据过大。")
                    val name = "Miyin-translation-${System.currentTimeMillis()}.jpg"
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        throw IOException("当前系统版本暂不支持保存到相册。")
                    }
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, name)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Miyin")
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    val resolver = appContext.contentResolver
                    val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        ?: throw IOException("无法创建相册图片。")
                    try {
                        resolver.openOutputStream(uri)?.use { it.write(bytes) }
                            ?: throw IOException("无法写入相册图片。")
                        resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
                        result.success(mapOf("saved" to true, "name" to name))
                    } catch (error: Exception) {
                        resolver.delete(uri, null, null)
                        throw error
                    }
                } catch (error: Exception) {
                    result.error("image_save_failed", "无法保存译图到相册。", error.message)
                }
            }
            return
        }
        if (call.method != "recognizeText") {
            result.notImplemented()
            return
        }
        if (disposed) {
            result.error("image_ocr_unavailable", "OCR is no longer available.", null)
            return
        }

        val rawPath = call.argument<String>("path")?.takeIf { it.isNotBlank() }
        if (rawPath == null) {
            result.error("image_invalid", "No local image was provided.", null)
            return
        }

        executor.execute {
            var bitmap: Bitmap? = null
            try {
                val imageFile = File(rawPath).canonicalFile
                if (!imageFile.isFile || !imageFile.canRead()) {
                    result.error("image_invalid", "The selected image is unavailable.", null)
                    return@execute
                }
                if (imageFile.length() <= 0L || imageFile.length() > MAX_IMAGE_BYTES) {
                    result.error("image_invalid", "The selected image is empty or too large.", null)
                    return@execute
                }

                val renderBitmap = decodeForRecognition(imageFile, MAX_PREVIEW_SIDE)
                bitmap = renderBitmap
                val preview = encodePreview(renderBitmap)
                val workingBitmap = if (maxOf(renderBitmap.width, renderBitmap.height) > MAX_OCR_SIDE) {
                    val scale = MAX_OCR_SIDE.toFloat() / maxOf(renderBitmap.width, renderBitmap.height)
                    Bitmap.createScaledBitmap(
                        renderBitmap,
                        maxOf(1, (renderBitmap.width * scale).toInt()),
                        maxOf(1, (renderBitmap.height * scale).toInt()),
                        true,
                    )
                } else {
                    renderBitmap
                }
                if (workingBitmap !== renderBitmap) renderBitmap.recycle()
                bitmap = workingBitmap
                val inputImage = InputImage.fromBitmap(workingBitmap, 0)
                val activeRecognizer = getRecognizer()
                activeRecognizer.process(inputImage)
                    .addOnSuccessListener { recognized ->
                        try {
                            if (disposed) {
                                result.error("image_ocr_unavailable", "OCR is no longer available.", null)
                                return@addOnSuccessListener
                            }
                            fun mappedBlock(text: String, bounds: Rect?): Map<String, Any>? {
                                if (text.isEmpty() || bounds == null) return null
                                val left = (bounds.left.toFloat() / workingBitmap.width).coerceIn(0f, 1f).toDouble()
                                val top = (bounds.top.toFloat() / workingBitmap.height).coerceIn(0f, 1f).toDouble()
                                val right = (bounds.right.toFloat() / workingBitmap.width).coerceIn(0f, 1f).toDouble()
                                val bottom = (bounds.bottom.toFloat() / workingBitmap.height).coerceIn(0f, 1f).toDouble()
                                if (right <= left || bottom <= top) return null
                                return mapOf(
                                    "text" to text,
                                    "left" to left,
                                    "top" to top,
                                    "right" to right,
                                    "bottom" to bottom,
                                )
                            }
                            // Use OCR's own short paragraph grouping where possible. Translating
                            // fragments of the same sentence separately loses word order and
                            // leaves large gaps in the rendered picture.
                            val allBlocks = recognized.textBlocks.flatMap { textBlock ->
                                val lines = textBlock.lines.mapNotNull { line ->
                                    mappedBlock(line.text.trim(), line.boundingBox)
                                }
                                val paragraphText = textBlock.text.trim().replace('\n', ' ')
                                val paragraph = mappedBlock(paragraphText, textBlock.boundingBox)
                                if (lines.size in 2..4 && paragraphText.length <= 220 && paragraph != null) {
                                    listOf(paragraph + ("segments" to lines.map { it.getValue("text") as String }))
                                } else {
                                    lines
                                }
                            }
                            val blocks = allBlocks.take(MAX_OCR_BLOCK_COUNT)
                            val omittedBlockCount = allBlocks.size - blocks.size
                            val recognizedText = blocks.joinToString("\n") {
                                it.getValue("text") as String
                            }
                            result.success(
                                mapOf(
                                    "recognizedText" to recognizedText,
                                    "previewDataUrl" to "data:image/jpeg;base64,${Base64.encodeToString(preview.bytes, Base64.NO_WRAP)}",
                                    "width" to preview.width,
                                    "height" to preview.height,
                                    "blocks" to blocks,
                                    "totalBlockCount" to allBlocks.size,
                                    "omittedBlockCount" to omittedBlockCount,
                                    "truncated" to (omittedBlockCount > 0),
                                ),
                            )
                        } catch (error: Exception) {
                            result.error("image_ocr_failed", "The recognized image could not be prepared.", error.message)
                        } finally {
                            workingBitmap.recycle()
                            bitmap = null
                        }
                    }
                    .addOnFailureListener { error ->
                        workingBitmap.recycle()
                        bitmap = null
                        result.error("image_ocr_failed", "The image could not be recognized locally.", error.message)
                    }
            } catch (error: IOException) {
                bitmap?.recycle()
                result.error("image_invalid", "The selected image could not be opened.", error.message)
            } catch (error: Exception) {
                bitmap?.recycle()
                result.error("image_ocr_failed", "The image could not be recognized locally.", error.message)
            }
        }
    }

    fun dispose() {
        disposed = true
        executor.shutdownNow()
        recognizer?.close()
        recognizer = null
    }

    private fun getRecognizer(): TextRecognizer {
        return recognizer ?: TextRecognition.getClient(
            ChineseTextRecognizerOptions.Builder().build(),
        ).also { recognizer = it }
    }

    private fun decodeForRecognition(file: File, maxSide: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IOException("The selected file is not a supported image.")
        }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxSide) {
            sample *= 2
        }
        val decoded = BitmapFactory.decodeFile(
            file.absolutePath,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: throw IOException("The selected image could not be decoded.")
        val oriented = orientBitmap(decoded, file)
        if (oriented !== decoded) decoded.recycle()
        return oriented
    }

    private fun orientBitmap(bitmap: Bitmap, file: File): Bitmap {
        val orientation = try {
            ExifInterface(file.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: IOException) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setRotate(180f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun encodePreview(bitmap: Bitmap): PreviewImage {
        var scale = minOf(1f, MAX_PREVIEW_SIDE.toFloat() / maxOf(bitmap.width, bitmap.height))
        var preview = bitmap
        var ownedPreview: Bitmap? = null
        while (true) {
            if (scale < 1f) {
                ownedPreview?.recycle()
                preview = Bitmap.createScaledBitmap(
                    bitmap,
                    maxOf(1, (bitmap.width * scale).toInt()),
                    maxOf(1, (bitmap.height * scale).toInt()),
                    true,
                )
                ownedPreview = preview
            }
            for (quality in PREVIEW_QUALITIES) {
                val output = ByteArrayOutputStream()
                preview.compress(Bitmap.CompressFormat.JPEG, quality, output)
                val bytes = output.toByteArray()
                if (bytes.size <= MAX_PREVIEW_BYTES) {
                    val previewWidth = preview.width
                    val previewHeight = preview.height
                    ownedPreview?.recycle()
                    return PreviewImage(bytes, previewWidth, previewHeight)
                }
            }
            if (scale <= MIN_PREVIEW_SCALE) {
                ownedPreview?.recycle()
                throw IOException("The image preview could not be compressed safely.")
            }
            scale = maxOf(MIN_PREVIEW_SCALE, scale * PREVIEW_SCALE_STEP)
        }
    }

    private data class PreviewImage(val bytes: ByteArray, val width: Int, val height: Int)

    private companion object {
        const val MAX_IMAGE_BYTES = 20L * 1024L * 1024L
        const val MAX_OCR_SIDE = 1920
        // Keep aligned with TranslationImageRecognition.maxBlocks in Dart.
        const val MAX_OCR_BLOCK_COUNT = 80
        const val MAX_PREVIEW_SIDE = 2560
        const val MAX_PREVIEW_BYTES = 1600 * 1024
        const val MIN_PREVIEW_SCALE = 0.35f
        const val PREVIEW_SCALE_STEP = 0.82f
        val PREVIEW_QUALITIES = intArrayOf(92, 86, 78, 68)
    }
}
