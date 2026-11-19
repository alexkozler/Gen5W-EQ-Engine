import com.android.apksig.ApkSigner;
import com.android.apksig.ApkVerifier;
import java.io.File;
import java.io.FileInputStream;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.util.Collections;

/** verify <apk> <sdk>  |  sign <in> <out> <keystore> <alias> <pass> <minSdk> */
public class ApkTool {
    public static void main(String[] a) throws Exception {
        if (a[0].equals("verify")) {
            int sdk = Integer.parseInt(a[2]);
            ApkVerifier.Result r = new ApkVerifier.Builder(new File(a[1]))
                    .setMinCheckedPlatformVersion(sdk).setMaxCheckedPlatformVersion(sdk).build().verify();
            System.out.println(a[1] + " on API " + sdk + ": verified=" + r.isVerified() + " v1=" + r.isVerifiedUsingV1Scheme());
            for (ApkVerifier.IssueWithParams e : r.getErrors()) System.out.println("  ERROR " + e);
            for (ApkVerifier.Result.V1SchemeSignerInfo s : r.getV1SchemeSigners()) {
                for (ApkVerifier.IssueWithParams e : s.getErrors()) System.out.println("  V1 ERROR " + e);
                for (ApkVerifier.IssueWithParams w : s.getWarnings()) System.out.println("  V1 warning " + w);
            }
            for (ApkVerifier.IssueWithParams w : r.getWarnings()) System.out.println("  warning " + w);
        } else {
            KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
            try (FileInputStream in = new FileInputStream(a[3])) { ks.load(in, a[5].toCharArray()); }
            PrivateKey key = (PrivateKey) ks.getKey(a[4], a[5].toCharArray());
            X509Certificate cert = (X509Certificate) ks.getCertificate(a[4]);
            ApkSigner.SignerConfig sc = new ApkSigner.SignerConfig.Builder("EQTEST", key, Collections.singletonList(cert)).build();
            new ApkSigner.Builder(Collections.singletonList(sc))
                    .setInputApk(new File(a[1])).setOutputApk(new File(a[2]))
                    .setMinSdkVersion(Integer.parseInt(a[6]))
                    .setV1SigningEnabled(true).setV2SigningEnabled(false).setV3SigningEnabled(false).setV4SigningEnabled(false)
                    .build().sign();
            System.out.println("signed " + a[2]);
        }
    }
}
