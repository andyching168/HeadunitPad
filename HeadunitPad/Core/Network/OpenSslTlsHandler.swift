//
//  OpenSslTlsHandler.swift
//  HeadunitPad
//
//  TLS implementation using OpenSSL
//  Mirrors Android's AapSslNative approach using native OpenSSL
//

import Foundation
import OpenSSL

struct OpenSslHandshakeStep {
    let outgoingData: Data
    let isComplete: Bool
}

enum OpenSslTlsError: Error {
    case contextCreationFailed
    case handshakeFailed(String)
    case connectionFailed
    case sslError(Int32)
    case timeout
    case invalidState
    case bioError(String)
}

class OpenSslTlsHandler {
    private static let bioSetWriteBufSizeCmd: Int32 = 136 // BIO_C_SET_WRITE_BUF_SIZE

    private var sslContext: OpaquePointer?
    private var ssl: OpaquePointer?
    private var readBio: OpaquePointer?
    private var writeBio: OpaquePointer?
    private(set) var isHandshakeComplete = false
    private var clientCertificate: OpaquePointer?
    private var clientPrivateKey: OpaquePointer?
    private var certPath: String?
    private var keyPath: String?

    init() {}

    func setup() -> Bool {
        OPENSSL_init_ssl(0, nil)

        sslContext = SSL_CTX_new(TLS_client_method())
        guard sslContext != nil else {
            print("OpenSslTlsHandler: Failed to create SSL context")
            return false
        }

        SSL_CTX_set_verify(sslContext, SSL_VERIFY_NONE, nil)

        print("OpenSslTlsHandler: SSL context created")
        return true
    }

    func loadCertificate(certPath: String, keyPath: String) -> Bool {
        guard sslContext != nil else { return false }

        let result = SSL_CTX_use_certificate_file(sslContext, certPath, SSL_FILETYPE_PEM)
        guard result == 1 else {
            print("OpenSslTlsHandler: Failed to load certificate: \(result)")
            return false
        }

        let keyResult = SSL_CTX_use_PrivateKey_file(sslContext, keyPath, SSL_FILETYPE_PEM)
        guard keyResult == 1 else {
            print("OpenSslTlsHandler: Failed to load private key: \(keyResult)")
            return false
        }

        let verifyResult = SSL_CTX_check_private_key(sslContext)
        guard verifyResult == 1 else {
            print("OpenSslTlsHandler: Private key does not match certificate")
            return false
        }

        self.certPath = certPath
        self.keyPath = keyPath

        loadClientIdentityIntoMemory(certPath: certPath, keyPath: keyPath)

        print("OpenSslTlsHandler: Certificate and key loaded")
        return true
    }

    func hasClientIdentity() -> Bool {
        return certPath != nil && keyPath != nil
    }

    func startHandshakeSession() throws -> OpenSslHandshakeStep {
        guard sslContext != nil else {
            throw OpenSslTlsError.contextCreationFailed
        }
        guard certPath != nil, keyPath != nil else {
            throw OpenSslTlsError.handshakeFailed("Client certificate/key not loaded")
        }

        releaseSessionOnly()
        isHandshakeComplete = false

        ssl = SSL_new(sslContext)
        guard ssl != nil else {
            throw OpenSslTlsError.contextCreationFailed
        }

        if let cert = clientCertificate {
            let certSetResult = SSL_use_certificate(ssl, cert)
            print("OpenSslTlsHandler: SSL_use_certificate result=\(certSetResult)")
        }
        if let pkey = clientPrivateKey {
            let keySetResult = SSL_use_PrivateKey(ssl, pkey)
            print("OpenSslTlsHandler: SSL_use_PrivateKey result=\(keySetResult)")
        }

        // Fallback: if in-memory identity is unavailable, bind cert/key from PEM files per session.
        if SSL_get_certificate(ssl) == nil {
            if let certPath = certPath {
                let certFileResult = SSL_use_certificate_file(ssl, certPath, SSL_FILETYPE_PEM)
                print("OpenSslTlsHandler: SSL_use_certificate_file result=\(certFileResult)")
            }
            if let keyPath = keyPath {
                let keyFileResult = SSL_use_PrivateKey_file(ssl, keyPath, SSL_FILETYPE_PEM)
                print("OpenSslTlsHandler: SSL_use_PrivateKey_file result=\(keyFileResult)")
            }
        }

        let sessionKeyCheck = SSL_check_private_key(ssl)
        print("OpenSslTlsHandler: SSL_check_private_key(session) result=\(sessionKeyCheck)")
        let sslCert = SSL_get_certificate(ssl)
        print("OpenSslTlsHandler: Session cert present=\(sslCert != nil)")

        readBio = BIO_new(BIO_s_mem())
        writeBio = BIO_new(BIO_s_mem())
        guard readBio != nil && writeBio != nil else {
            throw OpenSslTlsError.bioError("Failed to create BIO")
        }

        setBioWriteBufferSize(readBio, size: AapMessage.DEF_BUFFER_LENGTH)
        setBioWriteBufferSize(writeBio, size: AapMessage.DEF_BUFFER_LENGTH)

        SSL_set0_rbio(ssl, readBio)
        SSL_set0_wbio(ssl, writeBio)
        SSL_set_connect_state(ssl)
        SSL_set_verify(ssl, SSL_VERIFY_NONE, nil)

        print("OpenSslTlsHandler: Handshake session prepared")
        return try runHandshakeStep()
    }

    func continueHandshake(with incomingTlsData: Data) throws -> OpenSslHandshakeStep {
        guard !isHandshakeComplete else {
            return OpenSslHandshakeStep(outgoingData: Data(), isComplete: true)
        }
        guard readBio != nil else {
            throw OpenSslTlsError.invalidState
        }

        if !incomingTlsData.isEmpty {
            let written = BIO_write(readBio, (incomingTlsData as NSData).bytes, Int32(incomingTlsData.count))
            if written <= 0 {
                throw OpenSslTlsError.bioError("BIO_write failed while feeding handshake data")
            }
            print("OpenSslTlsHandler: Fed \(written) handshake bytes into read BIO")
        }

        return try runHandshakeStep()
    }

    private func runHandshakeStep() throws -> OpenSslHandshakeStep {
        guard let ssl = ssl else {
            throw OpenSslTlsError.invalidState
        }

        var outgoing = Data()
        var iterations = 0

        while iterations < 8 {
            let result = SSL_do_handshake(ssl)
            drainWriteBio(into: &outgoing)

            if result == 1 {
                isHandshakeComplete = true
                print("OpenSslTlsHandler: Handshake complete")
                return OpenSslHandshakeStep(outgoingData: outgoing, isComplete: true)
            }

            let err = SSL_get_error(ssl, result)
            print("OpenSslTlsHandler: SSL_do_handshake result=\(result) err=\(err)")

            if err == SSL_ERROR_WANT_READ {
                return OpenSslHandshakeStep(outgoingData: outgoing, isComplete: false)
            }
            if err == SSL_ERROR_WANT_WRITE {
                iterations += 1
                continue
            }

            throw OpenSslTlsError.sslError(err)
        }

        return OpenSslHandshakeStep(outgoingData: outgoing, isComplete: false)
    }

    private func drainWriteBio(into output: inout Data) {
        guard let writeBio = writeBio else { return }

        while true {
            let pending = BIO_ctrl_pending(writeBio)
            if pending <= 0 {
                return
            }

            var buffer = [UInt8](repeating: 0, count: Int(pending))
            let read = BIO_read(writeBio, &buffer, Int32(pending))
            if read <= 0 {
                return
            }
            output.append(contentsOf: buffer[0..<Int(read)])
        }
    }

    private func setBioWriteBufferSize(_ bio: OpaquePointer?, size: Int) {
        guard let bio = bio else { return }
        let ret = BIO_ctrl(bio, OpenSslTlsHandler.bioSetWriteBufSizeCmd, size, nil)
        if ret <= 0 {
            print("OpenSslTlsHandler: Failed to set BIO write buffer size to \(size)")
        }
    }

    func encrypt(data: Data) -> Data? {
        guard let ssl = ssl, isHandshakeComplete else { return nil }

        let written = SSL_write(ssl, (data as NSData).bytes, Int32(data.count))
        guard written > 0 else { return nil }

        var encrypted = Data()
        let pending = BIO_ctrl_pending(writeBio)
        if pending > 0 {
            var buffer = [UInt8](repeating: 0, count: Int(pending))
            let read = BIO_read(writeBio, &buffer, Int32(pending))
            if read > 0 {
                encrypted.append(contentsOf: buffer[0..<Int(read)])
            }
        }

        return encrypted.isEmpty ? nil : encrypted
    }

    func decrypt(data: Data) -> Data? {
        guard let ssl = ssl, isHandshakeComplete else { return nil }

        let written = BIO_write(readBio, (data as NSData).bytes, Int32(data.count))
        guard written > 0 else { return nil }

        var decrypted = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)

        while true {
            let read = SSL_read(ssl, &buffer, Int32(buffer.count))
            if read > 0 {
                decrypted.append(contentsOf: buffer[0..<Int(read)])
                continue
            }

            let err = SSL_get_error(ssl, read)
            if err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE {
                break
            }
            if read <= 0 {
                break
            }
        }

        return decrypted.isEmpty ? nil : decrypted
    }

    func postHandshakeReset() {
    }

    func release() {
        releaseSessionOnly()
        isHandshakeComplete = false

        if let cert = clientCertificate {
            X509_free(cert)
            clientCertificate = nil
        }
        if let pkey = clientPrivateKey {
            EVP_PKEY_free(pkey)
            clientPrivateKey = nil
        }

        if let ctx = sslContext {
            SSL_CTX_free(ctx)
            sslContext = nil
        }
    }

    func releaseSessionOnly() {
        if let ssl = ssl {
            SSL_free(ssl)
        }
        ssl = nil
        readBio = nil
        writeBio = nil
        isHandshakeComplete = false
    }

    private func loadClientIdentityIntoMemory(certPath: String, keyPath: String) {
        if let cert = clientCertificate {
            X509_free(cert)
            clientCertificate = nil
        }
        if let pkey = clientPrivateKey {
            EVP_PKEY_free(pkey)
            clientPrivateKey = nil
        }

        guard let certData = try? Data(contentsOf: URL(fileURLWithPath: certPath)) else {
            print("OpenSslTlsHandler: Failed to read certificate data from path")
            return
        }
        guard let keyData = try? Data(contentsOf: URL(fileURLWithPath: keyPath)) else {
            print("OpenSslTlsHandler: Failed to read private key data from path")
            return
        }

        let certBio = BIO_new_mem_buf((certData as NSData).bytes, Int32(certData.count))
        guard certBio != nil else {
            print("OpenSslTlsHandler: Failed to create certificate BIO")
            return
        }
        defer { BIO_free(certBio) }

        let keyBio = BIO_new_mem_buf((keyData as NSData).bytes, Int32(keyData.count))
        guard keyBio != nil else {
            print("OpenSslTlsHandler: Failed to create key BIO")
            return
        }
        defer { BIO_free(keyBio) }

        var certOut: OpaquePointer?
        let cert = PEM_read_bio_X509_AUX(certBio, &certOut, nil, nil)
        guard cert != nil else {
            print("OpenSslTlsHandler: PEM_read_bio_X509_AUX failed")
            return
        }

        var keyOut: OpaquePointer?
        let pkey = PEM_read_bio_PrivateKey(keyBio, &keyOut, nil, nil)
        guard pkey != nil else {
            print("OpenSslTlsHandler: PEM_read_bio_PrivateKey failed")
            X509_free(cert)
            return
        }

        clientCertificate = cert
        clientPrivateKey = pkey
        print("OpenSslTlsHandler: Loaded client identity into memory")
    }
}