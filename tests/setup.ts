import { Wallet } from 'ethers';

// Global mock/patch to speed up heavy keystore encryption during tests.
// Ethers default N parameter for scrypt is 131072, which takes several seconds per wallet
// and starves the CPU in virtualized/sandbox environments. Overriding to 1024 makes it run in milliseconds.
const originalEncrypt = Wallet.prototype.encrypt;
Wallet.prototype.encrypt = function (password: any, options?: any, progressCallback?: any) {
  const lightOptions = {
    scrypt: {
      N: 1024,
      r: 8,
      p: 1,
    },
    ...options,
  };
  return originalEncrypt.call(this, password, lightOptions, progressCallback);
};
