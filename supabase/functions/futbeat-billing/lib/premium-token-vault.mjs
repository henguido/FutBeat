import { Buffer } from 'node:buffer';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

export function createPremiumTokenVault({ key, authOrigin, packageName }) {
  if (!Buffer.isBuffer(key) || key.length !== 32 || !authOrigin || !packageName) {
    throw new Error('Premium token vault requires a 32-byte key and scope');
  }
  const aad = (row) => Buffer.from(JSON.stringify([
    'futbeat-premium-v1', authOrigin, packageName, row.account_id,
    row.token_hash, row.product_id,
  ]));
  return {
    seal(token, row) {
      const nonce = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', key, nonce);
      cipher.setAAD(aad(row));
      const ciphertext = Buffer.concat([cipher.update(token, 'utf8'), cipher.final()]);
      return Buffer.concat([nonce, cipher.getAuthTag(), ciphertext]);
    },
    open(sealed, row) {
      const data = Buffer.from(sealed);
      const decipher = createDecipheriv('aes-256-gcm', key, data.subarray(0, 12));
      decipher.setAAD(aad(row));
      decipher.setAuthTag(data.subarray(12, 28));
      return Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString('utf8');
    },
  };
}
