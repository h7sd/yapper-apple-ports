/* SPDX-License-Identifier: GPL-3.0-or-later */
package website.yapper.android;

import java.net.URI;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/** Pure Java policy: shared by navigation, document scripts, media and IPC. */
public final class URLPolicy {
    public static final String HOME = "https://www.yapper.website/";
    public static final Set<String> HOSTS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "www.yapper.website", "yapper.website", "www.yapin.gg", "yapin.gg")));
    public static final Set<String> ORIGINS;
    static {
        Set<String> values = new HashSet<>();
        for (String host : HOSTS) values.add("https://" + host);
        ORIGINS = Collections.unmodifiableSet(values);
    }
    private URLPolicy() {}
    private static URI parse(String value) {
        if (value == null || value.length() > 8192 || value.indexOf('\\') >= 0) return null;
        for (int i = 0; i < value.length(); i++) if (Character.isISOControl(value.charAt(i))) return null;
        try { return new URI(value); } catch (Exception ignored) { return null; }
    }
    public static boolean trusted(String value) {
        URI url = parse(value);
        return url != null && "https".equalsIgnoreCase(url.getScheme()) && url.getRawUserInfo() == null &&
            (url.getPort() == -1 || url.getPort() == 443) && url.getHost() != null &&
            HOSTS.contains(url.getHost().toLowerCase(Locale.ROOT));
    }
    public static String origin(String value) {
        if (!trusted(value)) return "";
        return "https://" + parse(value).getHost().toLowerCase(Locale.ROOT);
    }
    public static boolean sameOrigin(String first, String second) {
        return trusted(first) && trusted(second) && origin(first).equals(origin(second));
    }
    public static boolean external(String value) {
        URI url = parse(value);
        if (url == null || url.getRawUserInfo() != null) return false;
        String scheme = url.getScheme() == null ? "" : url.getScheme().toLowerCase(Locale.ROOT);
        return ((scheme.equals("https") || scheme.equals("http")) && url.getHost() != null) ||
            (scheme.equals("mailto") && !url.getRawSchemeSpecificPart().isEmpty());
    }
    public static String deepLink(String value) {
        URI input = parse(value);
        if (input == null || !"yapper".equalsIgnoreCase(input.getScheme()) || input.getRawUserInfo() != null ||
            input.getPort() != -1 || input.getHost() == null) return null;
        if (input.getHost().equalsIgnoreCase("app-settings")) return "settings";
        String path = "/" + input.getHost() + (input.getRawPath() == null ? "" : input.getRawPath());
        String output = HOME.substring(0, HOME.length() - 1) + path;
        if (input.getRawQuery() != null) output += "?" + input.getRawQuery();
        if (input.getRawFragment() != null) output += "#" + input.getRawFragment();
        return trusted(output) ? output : null;
    }
    public static String notificationURL(String path) {
        if (path == null || !path.startsWith("/") || path.startsWith("//") || path.indexOf('\\') >= 0) return HOME;
        String result = HOME.substring(0, HOME.length() - 1) + path;
        return trusted(result) ? result : HOME;
    }
    public static boolean popup(String value) {
        if (trusted(value) || "about:blank".equals(value)) return true;
        URI url = parse(value);
        return url != null && "https".equalsIgnoreCase(url.getScheme()) && "discord.com".equalsIgnoreCase(url.getHost()) &&
            url.getRawUserInfo() == null && (url.getPort() == -1 || url.getPort() == 443);
    }
}
