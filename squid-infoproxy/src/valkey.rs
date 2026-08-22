//! Minimal blocking Valkey/Redis (RESP) client -- just enough for the Squid
//! Info Proxy helper.
//!
//! We hand-roll the tiny slice of RESP we need (`AUTH`, `SELECT`, `SMEMBERS`)
//! rather than pull in the `redis` crate, because that crate's rustls feature
//! selects the aws_lc_rs provider by default, which would collide with the
//! workspace-wide `ring`-only policy (two providers -> runtime panic). Driving a
//! blocking `rustls::StreamOwned` ourselves keeps the whole workspace on `ring`.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::{ClientConfig, ClientConnection, RootCertStore, SignatureScheme, StreamOwned};
use rustls_pki_types::{CertificateDer, ServerName, UnixTime};

/// Connection settings parsed from a `redis(s)://` URL.
#[derive(Clone, Debug)]
pub struct ValkeyConfig {
	pub tls: bool,
	pub tls_insecure: bool,
	pub host: String,
	pub port: u16,
	pub username: Option<String>,
	pub password: Option<String>,
	pub db: Option<u32>,
}

impl ValkeyConfig {
	/// Parse `redis://` / `rediss://[user[:pass]@]host[:port][/db]`.
	pub fn parse(url: &str, tls_insecure: bool) -> Result<Self, String> {
		let (scheme, rest) = url
			.split_once("://")
			.ok_or_else(|| format!("invalid valkey url: {url}"))?;
		let tls = match scheme {
			"rediss" | "valkeys" => true,
			"redis" | "valkey" => false,
			other => return Err(format!("unsupported scheme: {other}")),
		};

		// Optional userinfo before an '@'.
		let (userinfo, hostpart) = match rest.rsplit_once('@') {
			Some((u, h)) => (Some(u), h),
			None => (None, rest),
		};
		let (username, password) = match userinfo {
			None => (None, None),
			Some(ui) => match ui.split_once(':') {
				Some((u, p)) => (
					(!u.is_empty()).then(|| u.to_string()),
					Some(p.to_string()),
				),
				None => (Some(ui.to_string()), None),
			},
		};

		// host[:port][/db]
		let (hostport, db) = match hostpart.split_once('/') {
			Some((hp, d)) => (
				hp,
				if d.is_empty() { None } else { Some(d.parse::<u32>().map_err(|_| "bad db")?) },
			),
			None => (hostpart, None),
		};
		let (host, port) = match hostport.rsplit_once(':') {
			Some((h, p)) => (h.to_string(), p.parse::<u16>().map_err(|_| "bad port")?),
			None => (hostport.to_string(), 6379),
		};
		if host.is_empty() {
			return Err("empty host".into());
		}

		Ok(Self { tls, tls_insecure, host, port, username, password, db })
	}
}

/// Either a plain TCP stream or a rustls session over TCP. Both are blocking.
enum Transport {
	Plain(TcpStream),
	Tls(Box<StreamOwned<ClientConnection, TcpStream>>),
}

impl Read for Transport {
	fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
		match self {
			Transport::Plain(s) => s.read(buf),
			Transport::Tls(s) => s.read(buf),
		}
	}
}

impl Write for Transport {
	fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
		match self {
			Transport::Plain(s) => s.write(buf),
			Transport::Tls(s) => s.write(buf),
		}
	}
	fn flush(&mut self) -> io::Result<()> {
		match self {
			Transport::Plain(s) => s.flush(),
			Transport::Tls(s) => s.flush(),
		}
	}
}

/// A live, authenticated RESP connection.
struct RespConn {
	reader: BufReader<Transport>,
}

/// A RESP reply value (only the subset we ever receive).
#[derive(Debug)]
#[allow(dead_code)] // some variants are parsed for protocol sync but not inspected
enum Value {
	Simple(String),
	Error(String),
	Int(i64),
	Bulk(Option<Vec<u8>>),
	Array(Vec<Value>),
}

impl RespConn {
	fn send(&mut self, args: &[&[u8]]) -> io::Result<()> {
		let mut buf = Vec::with_capacity(32);
		buf.extend_from_slice(format!("*{}\r\n", args.len()).as_bytes());
		for a in args {
			buf.extend_from_slice(format!("${}\r\n", a.len()).as_bytes());
			buf.extend_from_slice(a);
			buf.extend_from_slice(b"\r\n");
		}
		let w = self.reader.get_mut();
		w.write_all(&buf)?;
		w.flush()
	}

	fn read_line(&mut self) -> io::Result<String> {
		let mut buf = Vec::new();
		let n = self.reader.read_until(b'\n', &mut buf)?;
		if n == 0 {
			return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "valkey closed connection"));
		}
		while matches!(buf.last(), Some(b'\n') | Some(b'\r')) {
			buf.pop();
		}
		Ok(String::from_utf8_lossy(&buf).into_owned())
	}

	fn read_value(&mut self) -> io::Result<Value> {
		let line = self.read_line()?;
		let mut chars = line.chars();
		let kind = chars
			.next()
			.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "empty RESP line"))?;
		let rest = &line[1..];
		match kind {
			'+' => Ok(Value::Simple(rest.to_string())),
			'-' => Ok(Value::Error(rest.to_string())),
			':' => Ok(Value::Int(rest.parse().unwrap_or(0))),
			'_' => Ok(Value::Bulk(None)), // RESP3 null
			'$' => {
				let len: i64 = rest.parse().map_err(bad_data)?;
				if len < 0 {
					return Ok(Value::Bulk(None));
				}
				let mut data = vec![0u8; len as usize + 2]; // + CRLF
				self.reader.read_exact(&mut data)?;
				data.truncate(len as usize);
				Ok(Value::Bulk(Some(data)))
			}
			'*' | '~' | '>' => {
				let n: i64 = rest.parse().map_err(bad_data)?;
				if n < 0 {
					return Ok(Value::Array(Vec::new()));
				}
				let mut items = Vec::with_capacity(n as usize);
				for _ in 0..n {
					items.push(self.read_value()?);
				}
				Ok(Value::Array(items))
			}
			'%' => {
				// RESP3 map: 2*n values; flatten (unused, but parse to stay in sync).
				let n: i64 = rest.parse().map_err(bad_data)?;
				let mut items = Vec::with_capacity((n.max(0) as usize) * 2);
				for _ in 0..(n.max(0) * 2) {
					items.push(self.read_value()?);
				}
				Ok(Value::Array(items))
			}
			other => Err(io::Error::new(
				io::ErrorKind::InvalidData,
				format!("unexpected RESP type byte '{other}'"),
			)),
		}
	}

	fn expect_ok(&mut self) -> io::Result<()> {
		match self.read_value()? {
			Value::Simple(_) => Ok(()),
			Value::Error(e) => Err(io::Error::new(io::ErrorKind::PermissionDenied, e)),
			v => Err(io::Error::new(io::ErrorKind::InvalidData, format!("expected +OK, got {v:?}"))),
		}
	}
}

fn bad_data<E: std::fmt::Display>(e: E) -> io::Error {
	io::Error::new(io::ErrorKind::InvalidData, e.to_string())
}

/// A reconnecting Valkey client. Holds settings + TLS config and lazily
/// (re)establishes an authenticated connection on demand.
pub struct Valkey {
	cfg: ValkeyConfig,
	tls_config: Option<Arc<ClientConfig>>,
	conn: Option<RespConn>,
}

impl Valkey {
	pub fn new(cfg: ValkeyConfig) -> Result<Self, String> {
		let tls_config = if cfg.tls {
			Some(Arc::new(build_tls_config(cfg.tls_insecure)))
		} else {
			None
		};
		Ok(Self { cfg, tls_config, conn: None })
	}

	fn connect(&mut self) -> io::Result<RespConn> {
		let sock = TcpStream::connect((self.cfg.host.as_str(), self.cfg.port))?;
		sock.set_nodelay(true).ok();
		let transport = match &self.tls_config {
			Some(config) => {
				let name: ServerName<'static> = ServerName::try_from(self.cfg.host.clone())
					.map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e.to_string()))?;
				let client = ClientConnection::new(config.clone(), name)
					.map_err(|e| io::Error::other(e.to_string()))?;
				Transport::Tls(Box::new(StreamOwned::new(client, sock)))
			}
			None => Transport::Plain(sock),
		};
		let mut conn = RespConn { reader: BufReader::new(transport) };

		// AUTH (ACL user optional) then SELECT db.
		if let Some(pass) = &self.cfg.password {
			match &self.cfg.username {
				Some(user) => conn.send(&[b"AUTH", user.as_bytes(), pass.as_bytes()])?,
				None => conn.send(&[b"AUTH", pass.as_bytes()])?,
			}
			conn.expect_ok()?;
		}
		if let Some(db) = self.cfg.db {
			conn.send(&[b"SELECT", db.to_string().as_bytes()])?;
			conn.expect_ok()?;
		}
		Ok(conn)
	}

	fn ensure(&mut self) -> io::Result<&mut RespConn> {
		if self.conn.is_none() {
			self.conn = Some(self.connect()?);
		}
		Ok(self.conn.as_mut().unwrap())
	}

	/// `SMEMBERS key`. Reconnects once on a transport error before giving up.
	pub fn smembers(&mut self, key: &str) -> io::Result<Vec<String>> {
		match self.smembers_once(key) {
			Ok(v) => Ok(v),
			Err(e) if e.kind() != io::ErrorKind::PermissionDenied => {
				self.conn = None; // force reconnect
				self.smembers_once(key)
			}
			Err(e) => Err(e),
		}
	}

	fn smembers_once(&mut self, key: &str) -> io::Result<Vec<String>> {
		let conn = self.ensure()?;
		conn.send(&[b"SMEMBERS", key.as_bytes()])?;
		match conn.read_value()? {
			Value::Array(items) => Ok(items
				.into_iter()
				.filter_map(|v| match v {
					Value::Bulk(Some(b)) => Some(String::from_utf8_lossy(&b).into_owned()),
					Value::Simple(s) => Some(s),
					_ => None,
				})
				.collect()),
			Value::Error(e) => Err(io::Error::other(e)),
			Value::Bulk(None) => Ok(Vec::new()),
			v => Err(io::Error::new(io::ErrorKind::InvalidData, format!("unexpected SMEMBERS reply: {v:?}"))),
		}
	}

	/// `HGET key field`. Reconnects once on a transport error before giving up.
	/// A missing key or field yields `Ok(None)`.
	pub fn hget(&mut self, key: &str, field: &str) -> io::Result<Option<String>> {
		match self.hget_once(key, field) {
			Ok(v) => Ok(v),
			Err(e) if e.kind() != io::ErrorKind::PermissionDenied => {
				self.conn = None; // force reconnect
				self.hget_once(key, field)
			}
			Err(e) => Err(e),
		}
	}

	fn hget_once(&mut self, key: &str, field: &str) -> io::Result<Option<String>> {
		let conn = self.ensure()?;
		conn.send(&[b"HGET", key.as_bytes(), field.as_bytes()])?;
		match conn.read_value()? {
			Value::Bulk(Some(b)) => Ok(Some(String::from_utf8_lossy(&b).into_owned())),
			Value::Bulk(None) => Ok(None),
			Value::Simple(s) => Ok(Some(s)),
			Value::Error(e) => Err(io::Error::other(e)),
			v => Err(io::Error::new(io::ErrorKind::InvalidData, format!("unexpected HGET reply: {v:?}"))),
		}
	}
}

/// Build a rustls `ClientConfig` on the ring provider. When `insecure`, chain
/// validation is skipped (handshake signatures are still verified).
fn build_tls_config(insecure: bool) -> ClientConfig {
	let provider = Arc::new(rustls::crypto::ring::default_provider());
	let builder = ClientConfig::builder_with_provider(provider.clone())
		.with_safe_default_protocol_versions()
		.expect("ring provider supports safe defaults");

	if insecure {
		builder
			.dangerous()
			.with_custom_certificate_verifier(Arc::new(SkipServerVerification(provider)))
			.with_no_client_auth()
	} else {
		let mut roots = RootCertStore::empty();
		roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
		builder.with_root_certificates(roots).with_no_client_auth()
	}
}

/// A [`ServerCertVerifier`] that skips X.509 chain validation but still
/// cryptographically verifies handshake signatures. Only used with
/// `--tls-insecure` (self-signed dev Valkey). Mirrors the gateway's verifier.
#[derive(Debug)]
struct SkipServerVerification(Arc<rustls::crypto::CryptoProvider>);

impl ServerCertVerifier for SkipServerVerification {
	fn verify_server_cert(
		&self,
		_end_entity: &CertificateDer<'_>,
		_intermediates: &[CertificateDer<'_>],
		_server_name: &ServerName<'_>,
		_ocsp_response: &[u8],
		_now: UnixTime,
	) -> Result<ServerCertVerified, rustls::Error> {
		Ok(ServerCertVerified::assertion())
	}

	fn verify_tls12_signature(
		&self,
		message: &[u8],
		cert: &CertificateDer<'_>,
		dss: &rustls::DigitallySignedStruct,
	) -> Result<HandshakeSignatureValid, rustls::Error> {
		rustls::crypto::verify_tls12_signature(
			message,
			cert,
			dss,
			&self.0.signature_verification_algorithms,
		)
	}

	fn verify_tls13_signature(
		&self,
		message: &[u8],
		cert: &CertificateDer<'_>,
		dss: &rustls::DigitallySignedStruct,
	) -> Result<HandshakeSignatureValid, rustls::Error> {
		rustls::crypto::verify_tls13_signature(
			message,
			cert,
			dss,
			&self.0.signature_verification_algorithms,
		)
	}

	fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
		self.0.signature_verification_algorithms.supported_schemes()
	}
}
