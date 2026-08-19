import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Wallet, encryptKeystoreJson } from 'ethers';
import { generateAgentKeystore, AgentSession } from '../src/wallet/index.js';
import * as keystoreModule from '../src/wallet/keystore.js';

describe('Agent Keystore & Session', () => {
  let keystoreSpy: any;

  beforeEach(() => {
    keystoreSpy = vi.spyOn(keystoreModule, 'generateAgentKeystore').mockImplementation(async (passphrase) => {
      if (!passphrase || typeof passphrase !== 'string' || passphrase.trim().length === 0) {
        throw new Error('Passphrase cannot be empty');
      }
      const wallet = Wallet.createRandom();
      const keystoreJson = await encryptKeystoreJson(wallet as any, passphrase, { scrypt: { N: 1024 } });
      return { address: wallet.address, keystoreJson };
    });
  });

  afterEach(() => {
    keystoreSpy.mockRestore();
  });

  it('creates encrypted keystore and unlocks signer in session', async () => {
    const mockAuthKey = 'example-user-input-key';
    const { address, keystoreJson } = await generateAgentKeystore(mockAuthKey);
    expect(address).toMatch(/^0x[a-fA-F0-9]{40}$/);

    const session = new AgentSession();
    expect(session.isUnlocked()).toBe(false);

    const unlockedAddress = await session.unlock(keystoreJson, mockAuthKey);
    expect(session.isUnlocked()).toBe(true);
    expect(session.getAddress()).toBe(address);
    expect(unlockedAddress).toBe(address);

    const signer = session.getSigner();
    expect(signer.address).toBe(address);

    session.lock();
    expect(session.isUnlocked()).toBe(false);
    expect(() => session.getSigner()).toThrow(/Agent wallet is locked/);
    expect(() => session.getAddress()).toThrow(/Agent wallet is locked/);
  });

  it('rejects unlocking with incorrect passphrase', async () => {
    const mockAuthKey = 'correct-passphrase';
    const { keystoreJson } = await generateAgentKeystore(mockAuthKey);

    const session = new AgentSession();
    await expect(session.unlock(keystoreJson, 'wrong-passphrase')).rejects.toThrow();
    expect(session.isUnlocked()).toBe(false);
  });

  it('rejects unlocking with corrupted keystore JSON', async () => {
    const session = new AgentSession();
    await expect(session.unlock('invalid json', 'passphrase')).rejects.toThrow();
    expect(session.isUnlocked()).toBe(false);
  });

  it('rejects empty passphrase when generating keystore or unlocking', async () => {
    await expect(generateAgentKeystore('')).rejects.toThrow(/Passphrase cannot be empty/);

    const session = new AgentSession();
    await expect(session.unlock('{}', '')).rejects.toThrow(/Passphrase cannot be empty/);
  });

  it('allows signing messages when unlocked and supports relocking and unlocking again', async () => {
    const passphrase1 = 'passphrase-one';
    const passphrase2 = 'passphrase-two';
    const wallet1 = await generateAgentKeystore(passphrase1);
    const wallet2 = await generateAgentKeystore(passphrase2);

    const session = new AgentSession();

    // Unlock wallet 1
    await session.unlock(wallet1.keystoreJson, passphrase1);
    expect(session.getAddress()).toBe(wallet1.address);

    const signer1 = session.getSigner();
    const message = 'Sign this authorization payload';
    const sig1 = await signer1.signMessage(message);
    expect(sig1).toMatch(/^0x[a-fA-F0-9]+$/);

    // Lock session
    session.lock();
    expect(session.isUnlocked()).toBe(false);
    expect(() => session.getSigner()).toThrow(/Agent wallet is locked/);

    // Unlock wallet 2
    await session.unlock(wallet2.keystoreJson, passphrase2);
    expect(session.isUnlocked()).toBe(true);
    expect(session.getAddress()).toBe(wallet2.address);

    const signer2 = session.getSigner();
    const sig2 = await signer2.signMessage(message);
    expect(sig2).toMatch(/^0x[a-fA-F0-9]+$/);
    expect(sig2).not.toBe(sig1);
  });

  it('enforces secure production KDF parameters (N=131072) when generateAgentKeystore is called normally', async () => {
    // Restore spy to invoke real production implementation
    keystoreSpy.mockRestore();

    const { keystoreJson } = await generateAgentKeystore('production-passphrase');
    const parsed = JSON.parse(keystoreJson);
    
    // Verify parameters are strong (N=131072)
    const kdfparams = parsed.Crypto?.kdfparams || parsed.crypto?.kdfparams;
    expect(kdfparams.n).toBe(131072);
  });
});
