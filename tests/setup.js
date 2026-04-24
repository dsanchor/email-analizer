/**
 * Global test setup — runs before all test suites.
 *
 * Sets dummy environment variables so the Express server module can be
 * required without real Azure credentials.
 */

process.env.COSMOS_ENDPOINT = 'https://fake-cosmos.documents.azure.com:443/';
process.env.COSMOS_DATABASE = 'email-parser-db';
process.env.COSMOS_CONTAINER = 'emails';
process.env.STORAGE_ACCOUNT_URL = 'https://fakestorage.blob.core.windows.net';
process.env.STORAGE_CONTAINER = 'email-attachments';
