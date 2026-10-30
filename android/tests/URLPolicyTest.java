/* SPDX-License-Identifier: MIT */
package website.yapper.android;

import org.junit.Test;
import static org.junit.Assert.*;

public class URLPolicyTest {
    @Test public void exactAppOriginsOnly() {
        for (String host : URLPolicy.HOSTS) {
            assertTrue(URLPolicy.trusted("https://" + host + "/"));
            assertTrue(URLPolicy.trusted("https://" + host + ":443/login?next=%2F#account"));
        }
        assertEquals(4, URLPolicy.ORIGINS.size());
        assertTrue(URLPolicy.trusted("HTTPS://WWW.YAPPER.WEBSITE/path"));
    }
    @Test public void deceptiveOrInsecureAddressesRejected() {
        for (String input : new String[]{ null, "", "about:blank", "file:///tmp/page.html", "content://files/page", "javascript:alert(1)",
            "http://www.yapper.website/", "https://www.yapper.website:8443/", "https://www.yapper.website.attacker.test/",
            "https://attacker.test/www.yapper.website", "https://user@www.yapper.website/", "https://user:pass@www.yapper.website/",
            "https://www.yapper.website@attacker.test/", "https://www.yapper.website./", "https://www.yapper.website\\@attacker.test/",
            "https://www.yapper.website/%\n", "https://www.yapper.website\u0000/", "https://www.yapper.website%2F.attacker.test/",
            "https://rt.yapper.website/", "https://lk.yapper.website/", "https://www.yapper.website/" + "a".repeat(8192) }) {
            assertFalse(String.valueOf(input), URLPolicy.trusted(input));
        }
    }
    @Test public void originsNormalizeOnlyDefaultHttpsPort() {
        assertTrue(URLPolicy.sameOrigin("https://www.yapper.website/path", "https://WWW.YAPPER.WEBSITE:443/other"));
        assertFalse(URLPolicy.sameOrigin("https://yapin.gg/", "https://www.yapin.gg/"));
        assertFalse(URLPolicy.sameOrigin("https://yapin.gg:8443/", "https://yapin.gg/"));
        assertFalse(URLPolicy.sameOrigin(null, null));
    }
    @Test public void deepLinksRemainOnYapper() {
        assertEquals("https://www.yapper.website/invite/code?x=1#join", URLPolicy.deepLink("yapper://invite/code?x=1#join"));
        assertEquals("settings", URLPolicy.deepLink("yapper://app-settings"));
        for (String input : new String[]{"https://attacker.test/", "yapper://user@invite/code", "yapper://invite:443/code", "yapper:javascript:alert(1)", "yapper://invite\\attacker.test/"})
            assertNull(input, URLPolicy.deepLink(input));
    }
    @Test public void notificationDestinationsCannotBecomeExternalUrls() {
        assertEquals("https://www.yapper.website/?channel=hello#latest", URLPolicy.notificationURL("/?channel=hello#latest"));
        for (String input : new String[]{null, "", "//attacker.test/", "https://attacker.test/", "/\\attacker.test/", "/x\r\ny"})
            assertEquals(String.valueOf(input), URLPolicy.HOME, URLPolicy.notificationURL(input));
    }
    @Test public void externalLinksExcludeIntentsAndCredentials() {
        for (String input : new String[]{"https://example.org/file.zip", "http://example.org/", "mailto:hello@example.org"}) assertTrue(input, URLPolicy.external(input));
        for (String input : new String[]{"intent://scan", "tel:123", "file:///private/file", "content://private/file", "javascript:alert(1)", "https://user:pass@example.org/", "http:///broken", null}) assertFalse(String.valueOf(input), URLPolicy.external(input));
    }
    @Test public void popupAllowlistNeverGrantsNativePrivileges() {
        for (String input : new String[]{"about:blank", "https://discord.com/oauth2/authorize", "https://www.yapin.gg/"}) assertTrue(input, URLPolicy.popup(input));
        for (String input : new String[]{"https://discord.com.attacker.test/", "http://discord.com/", "https://discord.com:8443/", "https://user@discord.com/", "file:///tmp/x"}) assertFalse(input, URLPolicy.popup(input));
    }
}
