/* Synthetic WebCrypto interoperability vector for the observed yapper-e2ee wire format.
 * These deliberately fixed test keys are never used by the app or a real account. */
const { webcrypto, createECDH } = require('node:crypto');
(async () => {
    const curve = byte => {
        const key = createECDH('prime256v1');
        key.setPrivateKey(Buffer.alloc(32, byte));
        return key;
    };
    const sender = curve(1), recipient = curve(2);
    const exported = key => ({
        kty: 'EC', crv: 'P-256',
        x: key.getPublicKey().subarray(1, 33).toString('base64url'),
        y: key.getPublicKey().subarray(33, 65).toString('base64url'),
        d: key.getPrivateKey().toString('base64url'), ext: false,
    });
    const privateKey = await webcrypto.subtle.importKey('jwk', exported(sender), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveKey']);
    const publicKey = await webcrypto.subtle.importKey('raw', recipient.getPublicKey(), { name: 'ECDH', namedCurve: 'P-256' }, false, []);
    const wrappingKey = await webcrypto.subtle.deriveKey({ name: 'ECDH', public: publicKey }, privateKey, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
    const nonce = Buffer.alloc(12, 4), mediaKey = Buffer.alloc(32, 3);
    const from = '11111111-1111-4111-8111-111111111111', to = '22222222-2222-4222-8222-222222222222', index = 7;
    const ciphertext = await webcrypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: Buffer.from(`${from}|${to}|${index}`) }, wrappingKey, mediaKey);
    const publicKeys = [sender.getPublicKey().toString('base64'), recipient.getPublicKey().toString('base64')].sort();
    const digest = Buffer.from(await webcrypto.subtle.digest('SHA-256', Buffer.from(publicKeys.join('\n'))));
    const safetyCode = Array.from({ length: 6 }, (_, i) => String(digest.readUInt32BE(i * 4) % 100000).padStart(5, '0')).join(' ');
    process.stdout.write(JSON.stringify({ senderPublicKey: sender.getPublicKey().toString('base64'), recipientPublicKey: recipient.getPublicKey().toString('base64'), packet: { i: index, iv: nonce.toString('base64'), ct: Buffer.from(ciphertext).toString('base64'), k: sender.getPublicKey().toString('base64') }, safetyCode }) + '\n');
})().catch(error => { process.stderr.write(String(error)); process.exitCode = 1; });
