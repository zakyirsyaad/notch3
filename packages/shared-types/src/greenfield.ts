/**
 * BNB Greenfield Decentralized Storage Data Models & Type Guards
 */

export interface GreenfieldUploadParams {
  bucket: string;
  objectName: string;
  content: string;
  contentType?: string;
  isPrivate?: boolean;
}

export interface GreenfieldUploadResult {
  objectId: string;
  bucket: string;
  objectName: string;
  url: string;
  contentHash?: string;
  size?: number;
  isPrivate?: boolean;
  timestamp?: number;
}

export interface GreenfieldObjectResult {
  bucket: string;
  objectName: string;
  content: string;
  contentType?: string;
  contentHash?: string;
  size?: number;
  isPrivate?: boolean;
  timestamp?: number;
}

export interface GreenfieldObjectMetadata {
  objectId?: string;
  bucket: string;
  objectName: string;
  size: number;
  contentType?: string;
  contentHash?: string;
  isPrivate?: boolean;
  createdAt?: number;
  updatedAt?: number;
}

export interface GreenfieldBucketMetadata {
  bucketName: string;
  owner: string;
  visibility?: 'public' | 'private' | string;
  createdAt?: number;
}

export interface GreenfieldBackupParams {
  sessionId: string;
  encryptedData: string;
}

export interface GreenfieldBackupResult {
  objectId: string;
  url: string;
  sessionId?: string;
  timestamp?: number;
}

function isRecord(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val);
}

/**
 * Validates whether an unknown object conforms to GreenfieldUploadParams
 */
export function isGreenfieldUploadParams(val: unknown): val is GreenfieldUploadParams {
  if (!isRecord(val)) return false;
  if (typeof val['bucket'] !== 'string') return false;
  if (typeof val['objectName'] !== 'string') return false;
  if (typeof val['content'] !== 'string') return false;
  if ('contentType' in val && val['contentType'] !== undefined && typeof val['contentType'] !== 'string') {
    return false;
  }
  if ('isPrivate' in val && val['isPrivate'] !== undefined && typeof val['isPrivate'] !== 'boolean') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to GreenfieldUploadResult
 */
export function isGreenfieldUploadResult(val: unknown): val is GreenfieldUploadResult {
  if (!isRecord(val)) return false;
  if (typeof val['objectId'] !== 'string') return false;
  if (typeof val['bucket'] !== 'string') return false;
  if (typeof val['objectName'] !== 'string') return false;
  if (typeof val['url'] !== 'string') return false;
  if ('contentHash' in val && val['contentHash'] !== undefined && typeof val['contentHash'] !== 'string') {
    return false;
  }
  if ('size' in val && val['size'] !== undefined && typeof val['size'] !== 'number') {
    return false;
  }
  if ('isPrivate' in val && val['isPrivate'] !== undefined && typeof val['isPrivate'] !== 'boolean') {
    return false;
  }
  if ('timestamp' in val && val['timestamp'] !== undefined && typeof val['timestamp'] !== 'number') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to GreenfieldObjectResult
 */
export function isGreenfieldObjectResult(val: unknown): val is GreenfieldObjectResult {
  if (!isRecord(val)) return false;
  if (typeof val['bucket'] !== 'string') return false;
  if (typeof val['objectName'] !== 'string') return false;
  if (typeof val['content'] !== 'string') return false;
  if ('contentType' in val && val['contentType'] !== undefined && typeof val['contentType'] !== 'string') {
    return false;
  }
  if ('contentHash' in val && val['contentHash'] !== undefined && typeof val['contentHash'] !== 'string') {
    return false;
  }
  if ('size' in val && val['size'] !== undefined && typeof val['size'] !== 'number') {
    return false;
  }
  if ('isPrivate' in val && val['isPrivate'] !== undefined && typeof val['isPrivate'] !== 'boolean') {
    return false;
  }
  if ('timestamp' in val && val['timestamp'] !== undefined && typeof val['timestamp'] !== 'number') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to GreenfieldObjectMetadata
 */
export function isGreenfieldObjectMetadata(val: unknown): val is GreenfieldObjectMetadata {
  if (!isRecord(val)) return false;
  if (typeof val['bucket'] !== 'string') return false;
  if (typeof val['objectName'] !== 'string') return false;
  if (typeof val['size'] !== 'number') return false;
  if ('objectId' in val && val['objectId'] !== undefined && typeof val['objectId'] !== 'string') {
    return false;
  }
  if ('contentType' in val && val['contentType'] !== undefined && typeof val['contentType'] !== 'string') {
    return false;
  }
  if ('contentHash' in val && val['contentHash'] !== undefined && typeof val['contentHash'] !== 'string') {
    return false;
  }
  if ('isPrivate' in val && val['isPrivate'] !== undefined && typeof val['isPrivate'] !== 'boolean') {
    return false;
  }
  if ('createdAt' in val && val['createdAt'] !== undefined && typeof val['createdAt'] !== 'number') {
    return false;
  }
  if ('updatedAt' in val && val['updatedAt'] !== undefined && typeof val['updatedAt'] !== 'number') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to GreenfieldBucketMetadata
 */
export function isGreenfieldBucketMetadata(val: unknown): val is GreenfieldBucketMetadata {
  if (!isRecord(val)) return false;
  if (typeof val['bucketName'] !== 'string') return false;
  if (typeof val['owner'] !== 'string') return false;
  if ('visibility' in val && val['visibility'] !== undefined && typeof val['visibility'] !== 'string') {
    return false;
  }
  if ('createdAt' in val && val['createdAt'] !== undefined && typeof val['createdAt'] !== 'number') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to GreenfieldBackupParams
 */
export function isGreenfieldBackupParams(val: unknown): val is GreenfieldBackupParams {
  if (!isRecord(val)) return false;
  if (typeof val['sessionId'] !== 'string') return false;
  if (typeof val['encryptedData'] !== 'string') return false;
  return true;
}

/**
 * Validates whether an unknown object conforms to GreenfieldBackupResult
 */
export function isGreenfieldBackupResult(val: unknown): val is GreenfieldBackupResult {
  if (!isRecord(val)) return false;
  if (typeof val['objectId'] !== 'string') return false;
  if (typeof val['url'] !== 'string') return false;
  if ('sessionId' in val && val['sessionId'] !== undefined && typeof val['sessionId'] !== 'string') {
    return false;
  }
  if ('timestamp' in val && val['timestamp'] !== undefined && typeof val['timestamp'] !== 'number') {
    return false;
  }
  return true;
}
