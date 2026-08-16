import { Wallet, type HDNodeWallet } from 'ethers';

/**
 * Manages the in-memory lifecycle of an unlocked agent wallet signer.
 * Holds the active signer when unlocked and securely clears references
 * when locked.
 */
export class AgentSession {
  private _signer: HDNodeWallet | Wallet | null = null;
  private _address: string | null = null;

  /**
   * Returns true if the agent session is currently unlocked with an active signer.
   */
  public isUnlocked(): boolean {
    return this._signer !== null;
  }

  /**
   * Returns the address of the unlocked agent wallet.
   * Throws if the session is locked.
   */
  public getAddress(): string {
    if (!this._signer || !this._address) {
      throw new Error('Agent wallet is locked. Please unlock the agent wallet before accessing.');
    }
    return this._address;
  }

  /**
   * Returns the active ethers signer for transaction signing and message signing.
   * Throws if the session is locked.
   */
  public getSigner(): HDNodeWallet | Wallet {
    if (!this._signer) {
      throw new Error('Agent wallet is locked. Please unlock the agent wallet before accessing.');
    }
    return this._signer;
  }

  /**
   * Unlocks an encrypted Web3 v3 JSON keystore using the provided passphrase
   * and loads the signer into this active session.
   *
   * @param keystoreJson The Web3 v3 encrypted JSON string
   * @param passphrase The passphrase used to decrypt the keystore
   * @returns The unlocked agent address
   */
  public async unlock(keystoreJson: string, passphrase: string): Promise<string> {
    if (!keystoreJson || typeof keystoreJson !== 'string' || keystoreJson.trim().length === 0) {
      throw new Error('Keystore JSON cannot be empty');
    }
    if (!passphrase || typeof passphrase !== 'string' || passphrase.trim().length === 0) {
      throw new Error('Passphrase cannot be empty');
    }

    // Attempt decryption
    const wallet = await Wallet.fromEncryptedJson(keystoreJson, passphrase);
    this._signer = wallet;
    this._address = wallet.address;

    return this._address;
  }

  /**
   * Locks the agent session and clears all signer references from memory.
   */
  public lock(): void {
    this._signer = null;
    this._address = null;
  }
}
