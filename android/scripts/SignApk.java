/* SPDX-License-Identifier: MIT
 * Thin command-line wrapper around the official Apache-2.0 Android apksig API.
 */
import com.android.apksig.ApkSigner;
import com.android.apksig.ApkVerifier;
import java.io.File;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.util.Collections;

public final class SignApk {
    public static void main(String[] args) throws Exception {
        if (args.length == 5 && args[0].equals("sign")) {
            char[] password = Files.readString(Path.of(args[4])).trim().toCharArray();
            KeyStore store = KeyStore.getInstance("PKCS12");
            try (FileInputStream input = new FileInputStream(args[3])) { store.load(input, password); }
            PrivateKey key = (PrivateKey) store.getKey("distribution", password);
            X509Certificate cert = (X509Certificate) store.getCertificate("distribution");
            ApkSigner.SignerConfig signer = new ApkSigner.SignerConfig.Builder("Yapinplugger", key, Collections.singletonList(cert)).build();
            new ApkSigner.Builder(Collections.singletonList(signer)).setInputApk(new File(args[1])).setOutputApk(new File(args[2]))
                .setMinSdkVersion(29).setV1SigningEnabled(true).setV2SigningEnabled(true).setV3SigningEnabled(true)
                .setV4SigningEnabled(false).setDebuggableApkPermitted(false).setAlignmentPreserved(false)
                .setCreatedBy("Yapinplugger apksig 9.5.0").build().sign();
            java.util.Arrays.fill(password, '\0');
        } else if (!(args.length == 2 && args[0].equals("verify"))) {
            throw new IllegalArgumentException("sign input.apk output.apk keystore.p12 password-file | verify output.apk");
        }
        File apk = new File(args[args[0].equals("sign") ? 2 : 1]);
        ApkVerifier.Result result = new ApkVerifier.Builder(apk).setMinCheckedPlatformVersion(29).build().verify();
        // Android 29+ uses v3; verify the included compatibility signatures in
        // their own platform ranges rather than assuming v3 verification also
        // reports a v2/v1 verification that those Android versions never use.
        ApkVerifier.Result v2 = new ApkVerifier.Builder(apk).setMinCheckedPlatformVersion(24).setMaxCheckedPlatformVersion(27).build().verify();
        ApkVerifier.Result v1 = new ApkVerifier.Builder(apk).setMinCheckedPlatformVersion(21).setMaxCheckedPlatformVersion(23).build().verify();
        if (!result.isVerified() || !v2.isVerified() || !v2.isVerifiedUsingV2Scheme() || !result.isVerifiedUsingV3Scheme() || !result.getErrors().isEmpty())
            throw new SecurityException("APK signature verification failed: " + result.getAllErrors());
        X509Certificate cert = result.getSignerCertificates().get(0);
        StringBuilder fingerprint = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(cert.getEncoded())) fingerprint.append(String.format("%02x", value & 255));
        System.out.println("{\"verified\":true,\"v1\":" + v1.isVerifiedUsingV1Scheme() + ",\"v2\":" + v2.isVerifiedUsingV2Scheme() +
            ",\"v3\":" + result.isVerifiedUsingV3Scheme() + ",\"certificateSha256\":\"" + fingerprint + "\",\"warnings\":" + result.getWarnings().size() + "}");
        for (Object warning : result.getWarnings()) System.err.println(warning);
    }
}
