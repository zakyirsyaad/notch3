import { Wallet, encryptKeystoreJson } from 'ethers';

/**
 * Keystore result containing address and encrypted Web3 v3 JSON.
 */
export interface KeystoreResult {
  address: string;
  keystoreJson: string;
}

/**
 * Generates a new cryptographically secure random agent wallet
 * and exports it as an encrypted Web3 v3 JSON keystore string.
 *
 * @param passphrase The passphrase used to encrypt the keystore
 * @returns Object containing the wallet's Ethereum address and the keystore JSON string
 */
export async function generateAgentKeystore(passphrase: string): Promise<KeystoreResult> {
  if (!passphrase || typeof passphrase !== 'string' || passphrase.trim().length === 0) {
    throw new Error('Passphrase cannot be empty');
  }

  const wallet = Wallet.createRandom();
  const keystoreJson = await encryptKeystoreJson(wallet as any, passphrase);

  return {
    address: wallet.address,
    keystoreJson,
  };
}
