#!/usr/bin/env swift
// Generates an Ed25519 keypair for signing NotchDeck license receipts.
//
//   swift Scripts/license-keygen.swift
//
// - Public key (base64, 32 raw bytes) → LICENSE_PUBLIC_KEY in Config/NotchDeck.xcconfig
// - Private key (JWK)                  → SIGNING_KEY_JWK secret of the license proxy
//                                        (`wrangler secret put SIGNING_KEY_JWK`)
// Never commit the private key.
import CryptoKit
import Foundation

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let key = Curve25519.Signing.PrivateKey()
let publicRaw = key.publicKey.rawRepresentation
let jwk = #"{"kty":"OKP","crv":"Ed25519","d":"\#(base64url(key.rawRepresentation))","x":"\#(base64url(publicRaw))"}"#

print("LICENSE_PUBLIC_KEY=\(publicRaw.base64EncodedString())")
print("SIGNING_KEY_JWK=\(jwk)")
