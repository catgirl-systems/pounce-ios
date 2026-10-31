# Vendored swift-nio-ssh

This is [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) at tag **0.15.0**, vendored so pounce can patch in RSA support. Upstream has no extension point for extra key algorithms.

Upstream ships no `NOTICE.txt` at 0.15.0, so only `LICENSE.txt` (Apache 2.0) is kept.

## What was removed

Tests, Benchmarks, the example and tool targets (`NIOSSHClient`, `NIOSSHServer`, `NIOSSHPerformanceTester`), `Docs.docc`, `dev/`, CI configuration and other repository metadata. `Package.swift` now declares only the `NIOSSH` library, with the same dependencies upstream declares (swift-nio, swift-crypto, swift-atomics) and the `MemberImportVisibility` upcoming feature.

## Patches: RSA keys (Darwin only)

Everything below is behind `#if canImport(Darwin)` and uses only the Security framework.

- Public API: `NIOSSHPrivateKey(rsaKey: SecKey) throws`.
- Client user authentication with RSA keys uses the `rsa-sha2-512` algorithm (RFC 8332). The key blob stays `ssh-rsa`, e, n (RFC 4253).
- Client host key verification accepts RSA host keys through `rsa-sha2-512` and `rsa-sha2-256`. These come last in the preference list, after Ed25519 and ECDSA.
- `NIOSSHPublicKey(openSSHPublicKey:)` and `String(openSSHPublicKey:)` handle `ssh-rsa` keys.
- RSA keys can't be server host keys, and a NIOSSH server doesn't accept RSA user authentication.

Patched files (under `Sources/NIOSSH/`):

| File | Change |
| --- | --- |
| `Keys And Signatures/RSAKeys.swift` | New. RSA public key (e, n, PKCS #1 DER encoding and parsing), SecKey-backed private key, RSA signature types, wire-format readers and writers. |
| `Keys And Signatures/NIOSSHPrivateKey.swift` | `init(rsaKey:)`, `.rsa` backing key, signing with PKCS #1 v1.5 SHA-512, no host key algorithms. |
| `Keys And Signatures/NIOSSHPublicKey.swift` | `.rsa` backing key, `ssh-rsa` parsing and serialization, signature verification, `userAuthAlgorithmName` and `supportsHostKeyAlgorithm(_:)`. |
| `Keys And Signatures/NIOSSHSignature.swift` | `.rsa` backing signature, reads and writes `rsa-sha2-256` and `rsa-sha2-512` signature blobs. |
| `Keys And Signatures/NIOSSHCertifiedPublicKey.swift` | `ssh-rsa-cert-v01@openssh.com` key prefix so the exhaustive switch covers RSA. RSA certificates aren't parsed. |
| `Key Exchange/SSHKeyExchangeStateMachine.swift` | AES-GCM no longer needs a MAC in common with the server (as in OpenSSH), and the client offers ETM MAC names, so servers that allow only ETM MACs work. Adds `rsa-sha2-512` and `rsa-sha2-256` to the end of the client host key algorithms. Accepts an `ssh-rsa` host key for those algorithms and requires the signature to use the negotiated one. |
| `SSHMessages.swift` | USERAUTH_REQUEST writes `userAuthAlgorithmName` instead of `keyPrefix`. |
| `User Authentication/UserAuthSignablePayload.swift` | The signed payload uses `userAuthAlgorithmName` instead of `keyPrefix`. |

## Patch: keepalives

`NIOSSHHandler.sendKeepAlive(promise:)` (in `NIOSSHHandler.swift`, marked `pounce patch`) sends a `keepalive@openssh.com` global request and succeeds on any reply, including the usual refusal. pounce uses it to keep connections alive while the app is in the background.
