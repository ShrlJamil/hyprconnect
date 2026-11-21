//! TLS for the KDE Connect LAN protocol.
//!
//! Role quirk of the protocol: on the primary connection, the side that
//! OPENS the TCP connection acts as the TLS server, and the side that
//! ACCEPTS it acts as the TLS client. Certificates are self-signed and
//! accepted on a trust-on-first-use basis; trust decisions (pairing and
//! stored certificates) are enforced by the daemon, not the handshake.

use anyhow::{Context, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, WebPkiSupportedAlgorithms};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, Error as TlsError, SignatureScheme};
use std::sync::Arc;
use tokio::net::TcpStream;
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::identity::LocalIdentity;

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

#[derive(Debug)]
struct AcceptAnyServerCert {
    algs: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for AcceptAnyServerCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.algs,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls13_signature(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algs.supported_schemes()
    }
}

#[derive(Debug)]
struct AcceptAnyClientCert {
    algs: WebPkiSupportedAlgorithms,
}

impl ClientCertVerifier for AcceptAnyClientCert {
    fn root_hint_subjects(&self) -> &[rustls::DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, TlsError> {
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls12_signature(message, cert, dss, &self.algs)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls13_signature(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algs.supported_schemes()
    }
}

fn load_key(identity: &LocalIdentity) -> Result<PrivateKeyDer<'static>> {
    let mut reader = std::io::BufReader::new(identity.key_pem.as_bytes());
    let item = rustls_pemfile::read_one(&mut reader)?
        .context("no key in key PEM")?;
    match item {
        rustls_pemfile::Item::Pkcs8Key(k) => Ok(PrivateKeyDer::Pkcs8(k)),
        rustls_pemfile::Item::Sec1Key(k) => Ok(PrivateKeyDer::Sec1(k)),
        rustls_pemfile::Item::Pkcs1Key(k) => Ok(PrivateKeyDer::Pkcs1(k)),
        _ => anyhow::bail!("unsupported key format"),
    }
}

/// We opened the TCP connection, so we act as the TLS server.
/// Returns the TLS stream and the peer certificate DER.
pub async fn handshake_as_server(
    tcp: TcpStream,
    identity: &LocalIdentity,
) -> Result<(tokio_rustls::server::TlsStream<TcpStream>, Vec<u8>)> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let certs = vec![CertificateDer::from(identity.cert_der.clone())];
    let key = load_key(identity)?;
    let verifier = Arc::new(AcceptAnyClientCert {
        algs: provider().signature_verification_algorithms,
    });
    let config = rustls::ServerConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()?
        .with_client_cert_verifier(verifier)
        .with_single_cert(certs, key)?;
    let acceptor = TlsAcceptor::from(Arc::new(config));
    let stream = acceptor.accept(tcp).await.context("TLS accept")?;
    let peer = stream
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certs| certs.first().cloned())
        .context("peer presented no certificate")?;
    Ok((stream, peer.to_vec()))
}

/// We accepted the TCP connection, so we act as the TLS client.
/// `server_name` is the expected peer device id when known (used as SNI,
/// as KDE Connect does), otherwise our own device id.
pub async fn handshake_as_client(
    tcp: TcpStream,
    identity: &LocalIdentity,
    server_name: &str,
) -> Result<(tokio_rustls::client::TlsStream<TcpStream>, Vec<u8>)> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let certs = vec![CertificateDer::from(identity.cert_der.clone())];
    let key = load_key(identity)?;
    let verifier = Arc::new(AcceptAnyServerCert {
        algs: provider().signature_verification_algorithms,
    });
    let config = rustls::ClientConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(certs, key)?;
    let connector = TlsConnector::from(Arc::new(config));
    let name = ServerName::try_from(server_name.to_string())
        .unwrap_or_else(|_| ServerName::try_from(identity.device_id.clone()).unwrap());
    let stream = connector
        .connect(name, tcp)
        .await
        .context("TLS connect")?;
    let peer = stream
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certs| certs.first().cloned())
        .context("peer presented no certificate")?;
    Ok((stream, peer.to_vec()))
}
