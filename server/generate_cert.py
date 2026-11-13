from pathlib import Path
from datetime import datetime, timedelta, timezone
import socket

from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import ipaddress

base = Path(__file__).resolve().parent
key_path = base / "key.pem"
cert_path = base / "cert.pem"

# Collect candidate SANs: localhost, loopback, and non-loopback IPv4 addresses.
sans = [x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
try:
    hostname = socket.gethostname()
    for info in socket.getaddrinfo(hostname, None):
        ip = info[4][0]
        if ":" in ip:
            continue
        addr = ipaddress.ip_address(ip)
        if addr.is_loopback:
            continue
        if x509.IPAddress(addr) not in sans:
            sans.append(x509.IPAddress(addr))
except Exception:
    pass

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

subject = issuer = x509.Name([
    x509.NameAttribute(NameOID.COMMON_NAME, "localhost"),
])

cert = (
    x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.now(timezone.utc))
    .not_valid_after(datetime.now(timezone.utc) + timedelta(days=3650))
    .add_extension(x509.SubjectAlternativeName(sans), critical=False)
    .sign(key, hashes.SHA256())
)

key_path.write_bytes(
    key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )
)
cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
print(f"Wrote {key_path} and {cert_path}")
print("SANs:", [str(s.value) for s in sans])
PY