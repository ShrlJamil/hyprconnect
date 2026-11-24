# The embedded SFTP server (Apache MINA SSHD) and its crypto
# provider (BouncyCastle) wire their algorithms up by class
# name at runtime, which R8 cannot trace. Keep both whole;
# shrinking them saves little and breaks negotiation in ways
# only a real sshfs mount would reveal.
-keep class org.apache.sshd.** { *; }
-keep class org.bouncycastle.** { *; }
-keep class net.i2p.crypto.eddsa.** { *; }

# MINA references JMX types that do not exist on Android.
-dontwarn javax.management.**
-dontwarn java.rmi.RemoteException
-dontwarn java.rmi.ServerException
-dontwarn javax.naming.NamingEnumeration
-dontwarn javax.naming.NamingException
-dontwarn javax.naming.directory.Attribute
-dontwarn javax.naming.directory.Attributes
-dontwarn javax.naming.directory.DirContext
-dontwarn javax.naming.directory.InitialDirContext
-dontwarn javax.naming.directory.SearchControls
-dontwarn javax.naming.directory.SearchResult
-dontwarn javax.security.auth.callback.NameCallback
-dontwarn javax.security.auth.login.AppConfigurationEntry$LoginModuleControlFlag
-dontwarn javax.security.auth.login.AppConfigurationEntry
-dontwarn javax.security.auth.login.Configuration
-dontwarn javax.security.auth.login.CredentialException
-dontwarn javax.security.auth.login.FailedLoginException
-dontwarn javax.security.auth.login.LoginContext
-dontwarn org.apache.tomcat.jni.Error
-dontwarn org.apache.tomcat.jni.File
-dontwarn org.apache.tomcat.jni.Library
-dontwarn org.apache.tomcat.jni.Local
-dontwarn org.apache.tomcat.jni.Pool
-dontwarn org.apache.tomcat.jni.Socket
-dontwarn org.bouncycastle.openssl.PEMDecryptorProvider
-dontwarn org.bouncycastle.openssl.PEMEncryptedKeyPair
-dontwarn org.bouncycastle.openssl.PEMKeyPair
-dontwarn org.bouncycastle.openssl.PEMParser
-dontwarn org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter
-dontwarn org.bouncycastle.openssl.jcajce.JcaPEMWriter
-dontwarn org.bouncycastle.openssl.jcajce.JcePEMDecryptorProviderBuilder
-dontwarn org.bouncycastle.operator.InputDecryptorProvider
-dontwarn org.bouncycastle.pkcs.PKCS8EncryptedPrivateKeyInfo
-dontwarn org.bouncycastle.pkcs.PKCSException
-dontwarn org.bouncycastle.pkcs.jcajce.JcePKCSPBEInputDecryptorProviderBuilder
-dontwarn org.ietf.jgss.GSSContext
-dontwarn org.ietf.jgss.GSSCredential
-dontwarn org.ietf.jgss.GSSException
-dontwarn org.ietf.jgss.GSSManager
-dontwarn org.ietf.jgss.GSSName
-dontwarn org.ietf.jgss.MessageProp
-dontwarn org.ietf.jgss.Oid
-dontwarn sun.security.x509.X509Key
