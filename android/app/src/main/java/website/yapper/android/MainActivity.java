/* SPDX-License-Identifier: GPL-3.0-or-later */
package website.yapper.android;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.provider.Settings;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.GeolocationPermissions;
import android.webkit.PermissionRequest;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.SslErrorHandler;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.webkit.JavaScriptReplyProxy;
import androidx.webkit.ScriptHandler;
import androidx.webkit.WebMessageCompat;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.function.Consumer;

/** Native sandbox around the original, remotely hosted Yapper interface. */
public final class MainActivity extends Activity {
    private static final int MEDIA_PERMISSION = 101;
    private static final int NOTIFICATION_PERMISSION = 102;
    private static final String CHANNEL = "yapper-local";
    private static final String SETTINGS_ACTION = "website.yapper.android.SETTINGS";
    private SharedPreferences preferences;
    private FrameLayout root;
    private WebView webView;
    private ProgressBar loading;
    private LinearLayout failure;
    private ScriptHandler documentScript;
    private ValueCallback<Uri[]> fileSelection;
    private int filePickerSequence = 1000;
    private int activeFilePicker = -1;
    private int fileRevision;
    private String fileOrigin;
    private PermissionRequest mediaRequest;
    private PermissionRequest mediaPermissionOwner;
    private AlertDialog mediaDialog;
    private String mediaOrigin;
    private int mediaRevision;
    private Consumer<Boolean> notificationCompletion;
    private int notificationRevision;
    private int notificationRequestRevision;
    private int revision;
    private String lastURL = URLPolicy.HOME;
    private int notificationID = 1;
    private Dialog popupDialog;
    private WebView popupView;
    private int insetTop, insetRight, insetBottom, insetLeft;
    private boolean closing;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private Runnable loadDeadline;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        preferences = getSharedPreferences("yapper-native", MODE_PRIVATE);
        configureWindow();
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(21, 22, 26));
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            applyInsets(insets);
            return insets; // CSS owns system-bar padding; Android never adds a second copy.
        });
        setContentView(root);
        createWebView();
        root.requestApplyInsets();
        handleIntent(getIntent(), true);
    }

    private void configureWindow() {
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);
        } else {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE |
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        getWindow().setNavigationBarColor(Color.TRANSPARENT);
        getWindow().setStatusBarContrastEnforced(false);
        getWindow().setNavigationBarContrastEnforced(false);
        WindowManager.LayoutParams attributes = getWindow().getAttributes();
        attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        getWindow().setAttributes(attributes);
        if (Build.VERSION.SDK_INT >= 33) getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
            android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::onBackPressed);
    }

    private void applyInsets(WindowInsets insets) {
        int keyboard = 0;
        if (Build.VERSION.SDK_INT >= 30) {
            Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            insetTop = bars.top; insetRight = bars.right; insetBottom = bars.bottom; insetLeft = bars.left;
            if (insets.isVisible(WindowInsets.Type.ime())) {
                keyboard = insets.getInsets(WindowInsets.Type.ime()).bottom;
                insetBottom = 0;
            }
        } else {
            insetTop = insets.getSystemWindowInsetTop();
            insetRight = insets.getSystemWindowInsetRight();
            insetLeft = insets.getSystemWindowInsetLeft();
            // Android 10 adjustResize already shrinks the view when the keyboard opens.
            insetBottom = insets.getSystemWindowInsetBottom() > insets.getStableInsetBottom() + dp(100)
                ? 0 : insets.getStableInsetBottom();
            if (insets.getDisplayCutout() != null) {
                insetTop = Math.max(insetTop, insets.getDisplayCutout().getSafeInsetTop());
                insetRight = Math.max(insetRight, insets.getDisplayCutout().getSafeInsetRight());
                insetLeft = Math.max(insetLeft, insets.getDisplayCutout().getSafeInsetLeft());
            }
        }
        if (webView != null && Build.VERSION.SDK_INT >= 30) {
            FrameLayout.LayoutParams layout = (FrameLayout.LayoutParams) webView.getLayoutParams();
            if (layout.bottomMargin != keyboard) { layout.bottomMargin = keyboard; webView.setLayoutParams(layout); }
        }
        if (failure != null) failure.setPadding(dp(24) + insetLeft, dp(24) + insetTop, dp(24) + insetRight, dp(24) + insetBottom);
        updateInsets();
    }

    private String insetJSON() {
        double density = getResources().getDisplayMetrics().density;
        return "{\"top\":" + insetTop / density + ",\"right\":" + insetRight / density +
            ",\"bottom\":" + insetBottom / density + ",\"left\":" + insetLeft / density + "}";
    }

    private void updateInsets() {
        if (webView != null && URLPolicy.trusted(webView.getUrl()))
            webView.evaluateJavascript("window.__yapperAndroidInsets=" + insetJSON() + ";window.__yapperAndroidApplyInsets?.();", null);
    }

    private void configureWebSettings(WebView view) {
        WebSettings settings = view.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        // Uploads receive only picker-selected content URIs. Top-level content:
        // navigation is blocked and this app holds no broad storage permission.
        settings.setAllowContentAccess(true);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSafeBrowsingEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setSupportMultipleWindows(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setUserAgentString(settings.getUserAgentString() + " YapperAndroid/1.1.0");
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false);
        view.setBackgroundColor(Color.TRANSPARENT);
        view.setOverScrollMode(View.OVER_SCROLL_NEVER);
        view.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_YES);
    }

    private void createWebView() {
        webView = new WebView(this);
        configureWebSettings(webView);
        WebView.setWebContentsDebuggingEnabled(false);
        root.addView(webView, 0, new FrameLayout.LayoutParams(-1, -1));
        loading = new ProgressBar(this);
        FrameLayout.LayoutParams spinner = new FrameLayout.LayoutParams(dp(40), dp(40), Gravity.CENTER);
        root.addView(loading, spinner);
        webView.setWebViewClient(new MainWebClient());
        webView.setWebChromeClient(new MainChromeClient());
        webView.setDownloadListener((url, userAgent, disposition, mime, size) -> {
            if (!URLPolicy.trusted(webView.getUrl()) || !URLPolicy.external(url)) {
                toast("This download must be saved from Yapper in your browser."); return;
            }
            new AlertDialog.Builder(this).setTitle("Download attachment")
                .setMessage("Open this download in your browser? Your in-app login is not sent to other apps.")
                .setPositiveButton("Open browser", (dialog, which) -> openExternal(url))
                .setNegativeButton("Cancel", null).show();
        });
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) ||
            !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            showFailure("Update Android System WebView or Chrome, then reload. This build requires an origin-scoped bridge and document-start support.");
            return;
        }
        WebViewCompat.addWebMessageListener(webView, "yapperNative", URLPolicy.ORIGINS,
            (view, message, sourceOrigin, isMainFrame, replyProxy) -> receive(view, message, sourceOrigin, isMainFrame, replyProxy));
        try { installDocumentScript(); }
        catch (Exception error) { showFailure("A bundled component is missing. Reinstall this Yapinplugger build."); return; }
        webView.loadUrl(lastURL);
    }

    private String readAsset(String name) throws Exception {
        try (InputStream input = getAssets().open(name); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[16384]; int count;
            while ((count = input.read(buffer)) != -1) bytes.write(buffer, 0, count);
            return bytes.toString(StandardCharsets.UTF_8.name());
        }
    }

    private void installDocumentScript() throws Exception {
        if (documentScript != null) documentScript.remove();
        StringBuilder script = new StringBuilder("(()=>{'use strict';try{const u=new URL(location.href);if(top!==self||u.protocol!=='https:'||u.username||u.password||(u.port&&u.port!=='443')||!");
        script.append("['www.yapper.website','yapper.website','www.yapin.gg','yapin.gg'].includes(u.hostname))return;}catch{return;}\n");
        script.append("window.__yapperAndroidInsets=").append(insetJSON()).append(";\n");
        script.append(readAsset("NativeBridge.js")).append('\n').append(readAsset("AndroidViewport.js"));
        script.append("\nconst ready=()=>{\n");
        if (preferences.getBoolean("enhancedProfileLayoutEnabled", true)) script.append(readAsset("YapperAppearance.js")).append('\n');
        if (preferences.getBoolean("yapperCordEnabled", false)) script.append(readAsset("YapperCord.js")).append('\n');
        script.append("};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();})();");
        documentScript = WebViewCompat.addDocumentStartJavaScript(webView, script.toString(), URLPolicy.ORIGINS);
    }

    private void receive(WebView view, WebMessageCompat message, Uri origin, boolean isMainFrame, JavaScriptReplyProxy proxy) {
        // Android supplies this origin/frame identity; page-provided fields cannot override it.
        if (!isMainFrame || origin == null || !URLPolicy.trusted(origin.toString()) ||
            !URLPolicy.sameOrigin(origin.toString(), view.getUrl())) return;
        try {
            String data = message.getData();
            if (data == null || data.length() > 8192) return;
            JSONObject request = new JSONObject(data);
            String id = request.optString("id", "");
            if (!id.matches("[0-9]{1,16}")) return;
            String method = request.optString("method", "");
            JSONObject args = request.optJSONObject("args");
            if (args == null) return;
            int sourceRevision = revision;
            String sourceURL = view.getUrl();
            Consumer<Object> respond = result -> {
                if (closing || sourceRevision != revision || !URLPolicy.sameOrigin(sourceURL, webView.getUrl())) return;
                try { proxy.postMessage(new JSONObject().put("id", id).put("result", result).toString()); }
                catch (Exception ignored) { /* The sending document may have closed. */ }
            };
            switch (method) {
                case "getSettings":
                    respond.accept(new JSONObject().put("platform", "android").put("nativeNotifications", notificationsEnabled())); break;
                case "setSettings":
                    if (!(args.opt("nativeNotifications") instanceof Boolean)) { respond.accept(false); break; }
                    boolean enabled = args.getBoolean("nativeNotifications");
                    setNotifications(enabled, allowed -> respond.accept(allowed == enabled)); break;
                case "notify": respond.accept(notifyLocal(args)); break;
                case "setBadge": respond.accept(false); break;
                case "openSettings": showSettings(); respond.accept(true); break;
                default: respond.accept(false);
            }
        } catch (Exception ignored) { /* Malformed input has no native effect. */ }
    }

    private boolean notificationsEnabled() {
        return preferences.getBoolean("nativeNotifications", false) &&
            (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            getSystemService(NotificationManager.class).areNotificationsEnabled();
    }

    private void setNotifications(boolean enabled, Consumer<Boolean> complete) {
        notificationRevision++;
        if (!enabled) {
            preferences.edit().putBoolean("nativeNotifications", false).apply();
            getSystemService(NotificationManager.class).cancelAll(); complete.accept(false); return;
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            if (notificationCompletion != null) { complete.accept(false); return; }
            notificationCompletion = complete;
            notificationRequestRevision = notificationRevision;
            requestPermissions(new String[]{ Manifest.permission.POST_NOTIFICATIONS }, NOTIFICATION_PERMISSION);
        } else {
            boolean allowed = getSystemService(NotificationManager.class).areNotificationsEnabled();
            preferences.edit().putBoolean("nativeNotifications", allowed).apply(); complete.accept(allowed);
        }
    }

    private boolean notifyLocal(JSONObject args) {
        if (!notificationsEnabled()) return false;
        try {
            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.createNotificationChannel(new NotificationChannel(CHANNEL, "Yapper local notifications", NotificationManager.IMPORTANCE_DEFAULT));
            String title = args.optString("title", "Yapper");
            String body = args.optString("body", "");
            title = title.substring(0, Math.min(title.length(), 180));
            body = body.substring(0, Math.min(body.length(), 2000));
            Intent intent = new Intent(this, MainActivity.class).setAction(Intent.ACTION_VIEW)
                .putExtra("notificationURL", URLPolicy.notificationURL(args.optString("url", "/")));
            int id = notificationID++;
            PendingIntent tap = PendingIntent.getActivity(this, id, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            Notification notification = new Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_email)
                .setContentTitle(title).setContentText(body).setStyle(new Notification.BigTextStyle().bigText(body))
                .setContentIntent(tap).setAutoCancel(true).build();
            manager.notify(id, notification); return true;
        } catch (Exception denied) { return false; }
    }

    private void requestMedia(PermissionRequest request) {
        if (mediaRequest != null || mediaPermissionOwner != null || !URLPolicy.sameOrigin(request.getOrigin().toString(), webView.getUrl())) { request.deny(); return; }
        Set<String> resources = new HashSet<>(Arrays.asList(request.getResources()));
        if (resources.isEmpty() || !new HashSet<>(Arrays.asList(PermissionRequest.RESOURCE_AUDIO_CAPTURE, PermissionRequest.RESOURCE_VIDEO_CAPTURE)).containsAll(resources)) {
            request.deny(); return;
        }
        mediaRequest = request; mediaOrigin = request.getOrigin().toString(); mediaRevision = revision;
        String devices = resources.contains(PermissionRequest.RESOURCE_AUDIO_CAPTURE) ? "microphone" : "camera";
        if (resources.size() == 2) devices = "microphone and camera";
        final int ownerRevision = revision;
        mediaDialog = new AlertDialog.Builder(this).setTitle("Allow Yapper to use your " + devices + "?")
            .setMessage("Requested by " + URLPolicy.origin(mediaOrigin) + ". Android also asks for device permission. Access lasts only for this web session.")
            .setPositiveButton("Continue", (dialog, which) -> {
                if (mediaRequest != request || revision != ownerRevision || !mediaStillTrusted()) return;
                List<String> missing = new ArrayList<>();
                if (resources.contains(PermissionRequest.RESOURCE_AUDIO_CAPTURE) && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) missing.add(Manifest.permission.RECORD_AUDIO);
                if (resources.contains(PermissionRequest.RESOURCE_VIDEO_CAPTURE) && checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) missing.add(Manifest.permission.CAMERA);
                if (missing.isEmpty()) grantMedia(request);
                else { mediaPermissionOwner = request; requestPermissions(missing.toArray(new String[0]), MEDIA_PERMISSION); }
            }).setNegativeButton("Deny", (dialog, which) -> { if (mediaRequest == request) denyMedia(); })
            .setOnCancelListener(dialog -> { if (mediaRequest == request) denyMedia(); }).create();
        mediaDialog.show();
    }

    private boolean mediaStillTrusted() {
        return mediaRequest != null && mediaRevision == revision && URLPolicy.sameOrigin(mediaOrigin, webView.getUrl());
    }
    private void grantMedia(PermissionRequest owner) {
        if (owner != mediaRequest) return;
        if (!mediaStillTrusted()) { denyMedia(); return; }
        PermissionRequest request = mediaRequest;
        mediaRequest = null;
        request.grant(request.getResources());
    }
    private void denyMedia() {
        if (mediaRequest != null) { PermissionRequest request = mediaRequest; mediaRequest = null; request.deny(); }
        if (mediaDialog != null) { AlertDialog dialog = mediaDialog; mediaDialog = null; dialog.dismiss(); }
    }

    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(code, permissions, grants);
        if (code == NOTIFICATION_PERMISSION && notificationCompletion != null) {
            Consumer<Boolean> complete = notificationCompletion; notificationCompletion = null;
            boolean allowed = notificationRevision == notificationRequestRevision && grants.length == 1 && grants[0] == PackageManager.PERMISSION_GRANTED;
            preferences.edit().putBoolean("nativeNotifications", allowed).apply(); complete.accept(allowed);
        } else if (code == MEDIA_PERMISSION) {
            PermissionRequest owner = mediaPermissionOwner; mediaPermissionOwner = null;
            boolean allowed = grants.length > 0;
            for (int grant : grants) allowed &= grant == PackageManager.PERMISSION_GRANTED;
            if (owner == mediaRequest) { if (allowed) grantMedia(owner); else denyMedia(); }
        }
    }

    private void openExternal(String value) {
        if (!URLPolicy.external(value)) return;
        try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(value)).addCategory(Intent.CATEGORY_BROWSABLE)); }
        catch (ActivityNotFoundException missing) { toast("No app can open this link."); }
    }

    private void handleIntent(Intent intent, boolean first) {
        if (intent == null) return;
        if (SETTINGS_ACTION.equals(intent.getAction())) { root.post(this::showSettings); return; }
        String notification = intent.getStringExtra("notificationURL");
        if (notification != null && URLPolicy.trusted(notification)) { lastURL = notification; reload(); return; }
        Uri input = intent.getData();
        String target = input == null ? null : URLPolicy.deepLink(input.toString());
        if ("settings".equals(target)) root.post(this::showSettings);
        else if (target != null) { lastURL = target; reload(); }
    }

    @Override public void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent, false); }

    private void showSettings() {
        if (closing || isFinishing()) return;
        LinearLayout content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); content.setPadding(dp(22), dp(12), dp(22), dp(8));
        CheckBox appearance = new CheckBox(this); appearance.setText("Enhanced profile layout"); appearance.setChecked(preferences.getBoolean("enhancedProfileLayoutEnabled", true)); content.addView(appearance);
        CheckBox plugins = new CheckBox(this); plugins.setText("Enable Yapinplugger"); plugins.setChecked(preferences.getBoolean("yapperCordEnabled", false)); content.addView(plugins);
        CheckBox notifications = new CheckBox(this); notifications.setText("Local notifications"); notifications.setChecked(notificationsEnabled()); content.addView(notifications);
        TextView note = new TextView(this); note.setText("Six independent plugin adaptations are available. 161 public Vencord plugins still need a Yapper-specific port. This build has no background push service, screen sharing, global hotkeys or app detection.\n\nChanges to plugins or appearance reload Yapper. Your login stays in this app's private WebView store."); note.setPadding(0, dp(12), 0, dp(12)); content.addView(note);
        Button manager = new Button(this); manager.setText("Open Plugin Manager"); manager.setEnabled(preferences.getBoolean("yapperCordEnabled", false)); content.addView(manager);
        Button permissions = new Button(this); permissions.setText("Android permissions"); content.addView(permissions);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.addView(content);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Yapinplugger App Settings").setView(scroll)
            .setPositiveButton("Save", (alert, which) -> {
                boolean changed = appearance.isChecked() != preferences.getBoolean("enhancedProfileLayoutEnabled", true) || plugins.isChecked() != preferences.getBoolean("yapperCordEnabled", false);
                preferences.edit().putBoolean("enhancedProfileLayoutEnabled", appearance.isChecked()).putBoolean("yapperCordEnabled", plugins.isChecked()).apply();
                if (notifications.isChecked() != notificationsEnabled()) setNotifications(notifications.isChecked(), allowed -> { if (notifications.isChecked() && !allowed) toast("Notifications were not enabled."); });
                if (changed) { try { installDocumentScript(); reload(); } catch (Exception missing) { showFailure("A bundled component is missing. Reinstall this build."); } }
            }).setNeutralButton("Reload", (alert, which) -> reload()).setNegativeButton("Done", null).create();
        manager.setOnClickListener(view -> {
            if (!URLPolicy.trusted(webView.getUrl())) return;
            dialog.dismiss(); webView.evaluateJavascript("window.Yapinplugger?.open?.();", null);
        });
        permissions.setOnClickListener(view -> startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))));
        dialog.show();
    }

    private void reload() {
        if (failure != null) { root.removeView(failure); failure = null; }
        if (documentScript == null) {
            try { installDocumentScript(); }
            catch (Exception error) { showFailure("Update Android System WebView or reinstall this build, then try again."); return; }
        }
        loading.setVisibility(View.VISIBLE); webView.loadUrl(lastURL);
    }
    private void showFailure(String message) {
        if (closing) return;
        cancelLoadDeadline();
        loading.setVisibility(View.GONE);
        if (failure != null) root.removeView(failure);
        failure = new LinearLayout(this); failure.setOrientation(LinearLayout.VERTICAL); failure.setGravity(Gravity.CENTER);
        failure.setBackgroundColor(Color.rgb(21, 22, 26)); failure.setPadding(dp(24) + insetLeft, dp(24) + insetTop, dp(24) + insetRight, dp(24) + insetBottom);
        TextView title = new TextView(this); title.setText("Yapper is unavailable"); title.setTextSize(24); title.setTextColor(Color.WHITE); title.setGravity(Gravity.CENTER); failure.addView(title);
        TextView reason = new TextView(this); reason.setText(message); reason.setTextSize(16); reason.setTextColor(Color.LTGRAY); reason.setGravity(Gravity.CENTER); reason.setPadding(0, dp(16), 0, dp(16)); failure.addView(reason);
        Button retry = new Button(this); retry.setText("Retry"); retry.setOnClickListener(view -> reload()); failure.addView(retry);
        Button browser = new Button(this); browser.setText("Open in browser"); browser.setOnClickListener(view -> openExternal(URLPolicy.HOME)); failure.addView(browser);
        Button settings = new Button(this); settings.setText("App Settings"); settings.setOnClickListener(view -> showSettings()); failure.addView(settings);
        root.addView(failure, new FrameLayout.LayoutParams(-1, -1));
    }

    private final class MainWebClient extends WebViewClient {
        @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            String url = request.getUrl().toString();
            if (!request.isForMainFrame()) return !(url.startsWith("https://") || url.startsWith("about:") || url.startsWith("blob:"));
            if (URLPolicy.trusted(url)) return false;
            String target = URLPolicy.deepLink(url);
            if ("settings".equals(target)) showSettings();
            else if (target != null) { lastURL = target; view.loadUrl(target); }
            else if (request.hasGesture() && URLPolicy.external(url)) openExternal(url);
            return true;
        }
        @Override public void onPageStarted(WebView view, String url, android.graphics.Bitmap icon) {
            revision++; denyMedia(); loading.setVisibility(View.VISIBLE);
            cancelFileSelection();
            if (URLPolicy.trusted(url)) lastURL = url;
            else { view.stopLoading(); showFailure("This address is outside the trusted Yapper app."); }
            cancelLoadDeadline();
            final int sourceRevision = revision;
            loadDeadline = () -> { if (!closing && sourceRevision == revision && loading.getVisibility() == View.VISIBLE) {
                view.stopLoading(); showFailure("Check your internet connection, then try again.");
            } };
            mainHandler.postDelayed(loadDeadline, 30000);
        }
        @Override public void onPageFinished(WebView view, String url) { cancelLoadDeadline(); loading.setVisibility(View.GONE); updateInsets(); CookieManager.getInstance().flush(); }
        @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (request.isForMainFrame()) showFailure("Check your internet connection, then try again.");
        }
        @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
            if (request.isForMainFrame() && response.getStatusCode() >= 400) showFailure("Yapper returned an error. Try again in a moment.");
        }
        @Override public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) { handler.cancel(); showFailure("The server's secure connection could not be verified."); }
        @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            revision++; denyMedia(); cancelFileSelection(); documentScript = null;
            if (failure != null) { root.removeView(failure); failure = null; }
            root.removeView(view); view.destroy(); root.removeView(loading); createWebView();
            toast("Yapper reloaded after its web process stopped."); return true;
        }
    }

    private final class MainChromeClient extends WebChromeClient {
        @Override public void onPermissionRequest(PermissionRequest request) { runOnUiThread(() -> requestMedia(request)); }
        @Override public void onPermissionRequestCanceled(PermissionRequest request) { if (mediaRequest == request) denyMedia(); }
        @Override public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback callback) { callback.invoke(origin, false, false); }
        @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
            if (!URLPolicy.trusted(view.getUrl())) { callback.onReceiveValue(null); return true; }
            cancelFileSelection();
            fileSelection = callback;
            fileRevision = revision; fileOrigin = URLPolicy.origin(view.getUrl());
            activeFilePicker = filePickerSequence++;
            if (filePickerSequence > 32000) filePickerSequence = 1000;
            Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
            List<String> types = new ArrayList<>();
            for (String type : params.getAcceptTypes()) if (type != null && type.matches("[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_*-]+")) types.add(type);
            if (!types.isEmpty()) picker.putExtra(Intent.EXTRA_MIME_TYPES, types.toArray(new String[0]));
            picker.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
            try { startActivityForResult(picker, activeFilePicker); }
            catch (ActivityNotFoundException missing) { cancelFileSelection(); toast("No system file picker is available."); }
            return true;
        }
        @Override public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message result) {
            if (!isUserGesture || !URLPolicy.trusted(view.getUrl()) || popupView != null) return false;
            popupView = new WebView(MainActivity.this); configureWebSettings(popupView);
            // This separate WebView has no native message listener and no injected scripts.
            popupView.setWebViewClient(new WebViewClient() {
                @Override public boolean shouldOverrideUrlLoading(WebView popup, WebResourceRequest request) { return !URLPolicy.popup(request.getUrl().toString()); }
                @Override public void onReceivedSslError(WebView popup, SslErrorHandler handler, SslError error) { handler.cancel(); }
            });
            popupView.setWebChromeClient(new WebChromeClient() {
                @Override public void onPermissionRequest(PermissionRequest request) { request.deny(); }
                @Override public void onCloseWindow(WebView window) { closePopup(); }
            });
            LinearLayout content = new LinearLayout(MainActivity.this); content.setOrientation(LinearLayout.VERTICAL);
            Button close = new Button(MainActivity.this); close.setText("Close import window"); close.setOnClickListener(button -> closePopup()); content.addView(close);
            content.addView(popupView, new LinearLayout.LayoutParams(-1, 0, 1));
            popupDialog = new Dialog(MainActivity.this); popupDialog.setContentView(content); popupDialog.setOnDismissListener(dialog -> closePopup()); popupDialog.show();
            popupDialog.getWindow().setLayout(-1, -1);
            ((WebView.WebViewTransport) result.obj).setWebView(popupView); result.sendToTarget(); return true;
        }
    }

    private void closePopup() {
        WebView view = popupView; popupView = null;
        Dialog dialog = popupDialog; popupDialog = null;
        if (dialog != null) dialog.dismiss();
        if (view != null) view.destroy();
    }

    @Override public void onActivityResult(int code, int result, Intent intent) {
        super.onActivityResult(code, result, intent);
        if (code != activeFilePicker || fileSelection == null) return;
        List<Uri> selected = new ArrayList<>();
        if (result == RESULT_OK && intent != null && fileRevision == revision && fileOrigin.equals(URLPolicy.origin(webView.getUrl()))) {
            if (intent.getClipData() != null) {
                for (int i = 0; i < Math.min(100, intent.getClipData().getItemCount()); i++) selected.add(intent.getClipData().getItemAt(i).getUri());
            } else if (intent.getData() != null) selected.add(intent.getData());
        }
        // Only user-selected content URIs; never arbitrary file paths or provider text.
        selected.removeIf(uri -> uri == null || !"content".equals(uri.getScheme()));
        ValueCallback<Uri[]> complete = fileSelection; fileSelection = null; activeFilePicker = -1;
        complete.onReceiveValue(selected.isEmpty() ? null : selected.toArray(new Uri[0]));
    }

    private void cancelFileSelection() {
        ValueCallback<Uri[]> previous = fileSelection; fileSelection = null; activeFilePicker = -1;
        if (previous != null) previous.onReceiveValue(null);
    }

    private void cancelLoadDeadline() {
        if (loadDeadline != null) { mainHandler.removeCallbacks(loadDeadline); loadDeadline = null; }
    }

    private void lifecycle(String state) {
        if (webView != null && URLPolicy.trusted(webView.getUrl())) webView.evaluateJavascript("window.__yapperNativeEvent?.('lifecycle',{state:" + JSONObject.quote(state) + "});", null);
    }
    @Override public void onResume() { super.onResume(); if (webView != null) webView.onResume(); lifecycle("active"); }
    @Override public void onPause() { lifecycle("inactive"); if (webView != null) webView.onPause(); CookieManager.getInstance().flush(); super.onPause(); }
    @Override public void onStop() { lifecycle("background"); super.onStop(); }
    @Override public void onBackPressed() {
        if (popupView != null) { closePopup(); return; }
        if (webView.canGoBack()) { webView.goBack(); return; }
        new AlertDialog.Builder(this).setTitle("Yapinplugger").setPositiveButton("Stay", null)
            .setNeutralButton("App Settings", (dialog, which) -> showSettings()).setNegativeButton("Close app", (dialog, which) -> finish()).show();
    }
    @Override public boolean onKeyUp(int keyCode, KeyEvent event) { if (keyCode == KeyEvent.KEYCODE_MENU) { showSettings(); return true; } return super.onKeyUp(keyCode, event); }
    @Override public void onDestroy() {
        closing = true; revision++; denyMedia(); closePopup();
        cancelLoadDeadline();
        cancelFileSelection(); mediaPermissionOwner = null;
        if (notificationCompletion != null) { notificationCompletion.accept(false); notificationCompletion = null; }
        if (documentScript != null) documentScript.remove();
        if (webView != null) { root.removeView(webView); webView.destroy(); }
        super.onDestroy();
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }
}
