package com.abdullahhumayun.homesplash.tv

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import android.widget.Toast

/**
 * Full-screen kiosk browser for the Homesplash dashboard on Android TV.
 *
 *  MENU / SETTINGS key, or hold OK for ~1s  → change the server address and theme
 *  YELLOW key                                 → cycle theme: dark → light → auto
 *  BACK twice                                 → exit
 *  Loses the connection                       → keeps showing the last screen and retries
 *
 * Reloads are double-buffered: the new page loads in a hidden second WebView and only replaces
 * the visible one (with a short cross-fade) once the dashboard reports real content — so a
 * reload, theme change or server update never flashes a blank or loading screen.
 */
class MainActivity : Activity() {

    private lateinit var root: FrameLayout
    private lateinit var notice: TextView
    private var front: WebView? = null      // on screen
    private var back: WebView? = null       // loading behind it
    private var loadToken = 0               // identifies the newest load; older ones are ignored
    private val handler = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences(PREFS, MODE_PRIVATE) }
    private var lastBack = 0L
    private var dialogOpen = false
    private val retry = Runnable { load() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        notice = TextView(this).apply {
            setTextColor(Color.rgb(236, 230, 220))
            textSize = 22f
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(235, 11, 11, 15))
            setPadding(80, 80, 80, 80)
        }
        root.addView(notice, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        hideSystemUi()

        if (serverUrl().isEmpty()) showSetup() else load()
    }

    /** JS bridge: the dashboard calls HomesplashTV.ready() once its data is on screen. */
    private inner class Bridge(private val token: Int) {
        @JavascriptInterface fun ready() { handler.post { promote(token) } }
        @JavascriptInterface fun reload() { handler.post { load() } }
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun buildWebView(token: Int) = WebView(this).apply {
        setBackgroundColor(Color.TRANSPARENT)
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        isFocusable = true
        isFocusableInTouchMode = true
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.mediaPlaybackRequiresUserGesture = false
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        settings.cacheMode = WebSettings.LOAD_DEFAULT
        addJavascriptInterface(Bridge(token), "HomesplashTV")
        webViewClient = object : WebViewClient() {
            private var failed = false

            override fun onPageFinished(view: WebView, url: String?) {
                // Fallback if the page never calls ready() (e.g. the data API is slow):
                // promote anyway after a few seconds, as long as the page itself loaded.
                if (!failed) handler.postDelayed({ promote(token) }, 6_000)
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) { failed = true; fail(token, "${error.description}") }
            }

            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                if (request.isForMainFrame && response.statusCode >= 500) {
                    failed = true; fail(token, "HTTP ${response.statusCode}")
                }
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = false

            // A renderer crashed or was killed for memory: drop that view and load a fresh one.
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                discard(view)
                if (view === front) { front = null; load() }
                if (view === back) back = null
                return true
            }
        }
    }

    private fun serverUrl() = prefs.getString(KEY_URL, "") ?: ""

    /** "" = use display.theme from the server's config; otherwise dark / light / auto. */
    private fun theme() = prefs.getString(KEY_THEME, "") ?: ""

    private fun pageUrl(): String {
        val base = serverUrl()
        val t = theme()
        if (base.isEmpty() || t.isEmpty()) return base
        return base + (if ('?' in base) "&" else "/?") + "theme=" + t
    }

    /** Load the dashboard into a hidden WebView; it replaces the visible one once it's ready. */
    private fun load() {
        handler.removeCallbacks(retry)
        val url = serverUrl()
        if (url.isEmpty()) return showSetup()
        if (front == null) showOverlay("Homesplash\n\nConnecting to $url …")
        back?.let { discard(it) }
        val token = ++loadToken
        val view = buildWebView(token).apply { alpha = 0f }
        // stack: [front] [back (transparent, rendering)] [notice]
        root.addView(view, root.indexOfChild(notice), FrameLayout.LayoutParams(-1, -1))
        back = view
        view.loadUrl(pageUrl())
    }

    /** Cross-fade the freshly loaded view in and retire the old one. */
    private fun promote(token: Int) {
        val incoming = back ?: return
        if (token != loadToken) return
        back = null
        val outgoing = front
        front = incoming
        notice.visibility = View.GONE
        incoming.requestFocus()
        incoming.animate().alpha(1f).setDuration(350).withEndAction {
            outgoing?.let { discard(it) }
        }.start()
    }

    private fun fail(token: Int, reason: String) {
        if (token != loadToken) return
        back?.let { discard(it) }
        back = null
        handler.removeCallbacks(retry)
        handler.postDelayed(retry, 15_000)
        // Something is already on screen: keep showing it and retry quietly.
        if (front != null) return
        showOverlay("Can't reach ${serverUrl()}\n($reason)\n\nRetrying in 15 seconds.\nPress MENU or hold OK to change the server.")
    }

    private fun discard(view: WebView) {
        view.animate().cancel()
        root.removeView(view)
        view.stopLoading()
        view.loadUrl("about:blank")
        view.destroy()
    }

    private fun showOverlay(text: String) {
        notice.text = text
        notice.visibility = View.VISIBLE
        notice.bringToFront()
    }

    private fun showSetup() {
        if (dialogOpen) return
        dialogOpen = true
        val pad = (24 * resources.displayMetrics.density).toInt()
        val input = EditText(this).apply {
            setText(serverUrl().ifEmpty { "http://" })
            setSelection(text.length)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            hint = "http://192.168.1.20:8080"
        }
        val boot = CheckBox(this).apply {
            text = "Open Homesplash when the TV turns on"
            isChecked = prefs.getBoolean(KEY_BOOT, true)
        }
        val themes = listOf("" to "Theme from server config", "dark" to "Dark", "light" to "Light",
                            "auto" to "Auto — light by day, dark at night")
        val themeGroup = RadioGroup(this).apply {
            themes.forEachIndexed { i, (value, label) ->
                addView(RadioButton(this@MainActivity).apply {
                    id = 1000 + i
                    text = label
                    isChecked = theme() == value
                })
            }
        }
        val themeLabel = TextView(this).apply {
            text = "Theme"
            setPadding(0, pad / 2, 0, 0)
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, 0)
            addView(input)
            addView(boot)
            addView(themeLabel)
            addView(themeGroup)
        }
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Homesplash server")
            .setMessage("Address of the PC / LXC running Homesplash")
            .setView(box)
            .setPositiveButton("Save") { _, _ ->
                prefs.edit()
                    .putString(KEY_URL, normalise(input.text.toString()))
                    .putBoolean(KEY_BOOT, boot.isChecked)
                    .putString(KEY_THEME, themes.getOrNull(themeGroup.checkedRadioButtonId - 1000)?.first ?: theme())
                    .apply()
                load()
            }
            .setNeutralButton("Reload") { _, _ -> load() }
            .setNegativeButton("Cancel") { _, _ -> if (serverUrl().isEmpty()) showOverlay(HELP) }
            .setOnDismissListener { dialogOpen = false; hideSystemUi() }
            .show()
    }

    private fun normalise(raw: String): String {
        var url = raw.trim()
        if (url.isEmpty() || url == "http://") return ""
        if (!url.startsWith("http://") && !url.startsWith("https://")) url = "http://$url"
        return url.trimEnd('/')
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_SETTINGS, KeyEvent.KEYCODE_PROG_RED -> {
                    showSetup(); return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                    if (event.repeatCount == 15) { showSetup(); return true }  // held ~1s
                }
                KeyEvent.KEYCODE_PROG_GREEN, KeyEvent.KEYCODE_MEDIA_REWIND -> {
                    load(); return true
                }
                KeyEvent.KEYCODE_PROG_YELLOW -> {
                    val next = when (theme()) { "dark" -> "light"; "light" -> "auto"; else -> "dark" }
                    prefs.edit().putString(KEY_THEME, next).apply()
                    Toast.makeText(this, "Theme: " + next.replaceFirstChar { it.uppercase() }, Toast.LENGTH_SHORT).show()
                    load(); return true
                }
                KeyEvent.KEYCODE_BACK -> {
                    val now = System.currentTimeMillis()
                    if (now - lastBack < 2_000) finish()
                    else Toast.makeText(this, "Press BACK again to exit", Toast.LENGTH_SHORT).show()
                    lastBack = now
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    @Suppress("DEPRECATION")
    private fun hideSystemUi() {
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    override fun onResume() {
        super.onResume()
        front?.onResume()
        back?.onResume()
        front?.resumeTimers()
    }

    override fun onPause() {
        front?.onPause()
        back?.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        front?.let { discard(it) }
        back?.let { discard(it) }
        super.onDestroy()
    }

    companion object {
        const val PREFS = "homesplash"
        const val KEY_URL = "url"
        const val KEY_BOOT = "start_on_boot"
        const val KEY_THEME = "theme"
        private const val HELP = "Homesplash\n\nPress MENU (or hold OK) to set the server address."
    }
}
