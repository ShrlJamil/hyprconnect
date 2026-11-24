package io.github.shrljamil.hyprconnect_mobile

import org.apache.sshd.common.file.nativefs.NativeFileSystemFactory
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.password.PasswordAuthenticator
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import java.security.SecureRandom
import java.security.Security
import org.bouncycastle.jce.provider.BouncyCastleProvider

/// The embedded SFTP server behind the sftp plugin. When a
/// paired desktop asks to browse this phone
/// (kdeconnect.sftp.request), this server serves the device
/// filesystem with a one-session random password, and
/// MainActivity reports the parameters back for the
/// kdeconnect.sftp packet, exactly like the stock app's flow.
/// Implemented with Apache MINA SSHD, the same library the
/// stock app uses. The desktop mounts the shared storage path
/// out of the parameter packet, so no filesystem jail is
/// configured; the random per-session password is the gate.
object SftpServer {
    private const val USER = "kdeconnect"
    private const val FIRST_PORT = 1739
    private const val LAST_PORT = 1764

    private var server: SshServer? = null

    data class Info(val port: Int, val user: String, val password: String)

    @Synchronized
    fun start(): Info? {
        stopLocked()
        ensureFullCryptoProvider()
        val candidate = randomPassword()
        for (port in FIRST_PORT..LAST_PORT) {
            var sshd: SshServer? = null
            try {
                sshd = SshServer.setUpDefaultServer()
                sshd.port = port
                val hostKey = SimpleGeneratorHostKeyProvider()
                hostKey.algorithm = "RSA"
                sshd.keyPairProvider = hostKey
                sshd.passwordAuthenticator =
                    PasswordAuthenticator { username, pass, _ ->
                        username == USER && pass == candidate
                    }
                sshd.subsystemFactories = listOf(SftpSubsystemFactory())
                sshd.fileSystemFactory = NativeFileSystemFactory()
                sshd.start()
                server = sshd
                return Info(port, USER, candidate)
            } catch (e: Exception) {
                try {
                    sshd?.stop(true)
                } catch (_: Exception) {
                }
            }
        }
        return null
    }

    @Synchronized
    fun stop() = stopLocked()

    private fun stopLocked() {
        try {
            server?.stop(true)
        } catch (_: Exception) {
        }
        server = null
    }

    /// Android ships a stripped BouncyCastle under the same
    /// provider name; MINA's algorithm negotiation wants the
    /// full one, so swap it in once.
    private var providerSwapped = false
    private fun ensureFullCryptoProvider() {
        if (providerSwapped) return
        providerSwapped = true
        try {
            Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
            Security.addProvider(BouncyCastleProvider())
        } catch (_: Exception) {
            // The platform provider stays; the common
            // algorithms still negotiate through it.
        }
    }

    private fun randomPassword(): String {
        val alphabet =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        val random = SecureRandom()
        return (1..28)
            .map { alphabet[random.nextInt(alphabet.length)] }
            .joinToString("")
    }
}
