/**
 * Email Analyzer Web App — Express API server.
 * Serves React SPA in production, provides JSON API for Cosmos DB + Blob Storage.
 */

const path = require("path");
const express = require("express");
const { CosmosClient } = require("@azure/cosmos");
const { BlobServiceClient } = require("@azure/storage-blob");
const { DefaultAzureCredential } = require("@azure/identity");
const sanitizeHtml = require("sanitize-html");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const COSMOS_ENDPOINT = process.env.COSMOS_ENDPOINT || "";
const COSMOS_DATABASE = process.env.COSMOS_DATABASE || "email-analyzer-db";
const COSMOS_CONTAINER = process.env.COSMOS_CONTAINER || "emails";
const COSMOS_KEY = process.env.COSMOS_KEY || "";

const STORAGE_ACCOUNT_URL = process.env.STORAGE_ACCOUNT_URL || "";
const STORAGE_CONTAINER = process.env.STORAGE_CONTAINER || "email-attachments";
const STORAGE_CONNECTION_STRING = process.env.STORAGE_CONNECTION_STRING || "";

const PORT = parseInt(process.env.PORT || "8000", 10);

// ---------------------------------------------------------------------------
// Azure clients (lazy init)
// ---------------------------------------------------------------------------
let credential = null;
let cosmosClient = null;
let blobService = null;

function getCredential() {
  if (!credential) credential = new DefaultAzureCredential();
  return credential;
}

function getCosmosContainer() {
  if (!cosmosClient) {
    cosmosClient = COSMOS_KEY
      ? new CosmosClient({ endpoint: COSMOS_ENDPOINT, key: COSMOS_KEY })
      : new CosmosClient({ endpoint: COSMOS_ENDPOINT, aadCredentials: getCredential() });
  }
  return cosmosClient.database(COSMOS_DATABASE).container(COSMOS_CONTAINER);
}

function getBlobService() {
  if (!blobService) {
    blobService = STORAGE_CONNECTION_STRING
      ? BlobServiceClient.fromConnectionString(STORAGE_CONNECTION_STRING)
      : new BlobServiceClient(STORAGE_ACCOUNT_URL, getCredential());
  }
  return blobService;
}

// ---------------------------------------------------------------------------
// HTML sanitization
// ---------------------------------------------------------------------------
const ALLOWED_TAGS = [
  "p", "br", "strong", "em", "a", "ul", "ol", "li",
  "h1", "h2", "h3", "h4", "h5", "h6",
  "table", "tr", "td", "th", "thead", "tbody",
  "img", "span", "div", "blockquote", "b", "i", "u",
  "html", "body", "head",
];

const ALLOWED_ATTRIBUTES = {
  a: ["href", "title", "target"],
  img: ["src", "alt", "width", "height"],
  td: ["colspan", "rowspan"],
  th: ["colspan", "rowspan"],
  "*": ["style", "class"],
};

function sanitize(html) {
  if (!html) return "";
  return sanitizeHtml(html, {
    allowedTags: ALLOWED_TAGS,
    allowedAttributes: ALLOWED_ATTRIBUTES,
    disallowedTagsMode: "discard",
  });
}

/** Extract HTML string from either string or object body form. */
function extractBody(value) {
  if (value && typeof value === "object") return value.content || "";
  if (typeof value === "string") return value;
  return "";
}

// ---------------------------------------------------------------------------
// Express app
// ---------------------------------------------------------------------------
const app = express();

// Serve React build in production
const distPath = path.join(__dirname, "dist");
app.use(express.static(distPath));

// ---------------------------------------------------------------------------
// API routes
// ---------------------------------------------------------------------------
app.get("/health", (_req, res) => {
  res.json({ status: "healthy" });
});

app.get("/api/emails", async (req, res) => {
  try {
    const container = getCosmosContainer();
    const q = req.query.q || "";

    let querySpec;
    if (q) {
      querySpec = {
        query:
          "SELECT * FROM c WHERE CONTAINS(LOWER(c.subject), LOWER(@q)) " +
          "OR CONTAINS(LOWER(c['from']), LOWER(@q)) " +
          "ORDER BY c.receivedDateTime DESC",
        parameters: [{ name: "@q", value: q }],
      };
    } else {
      querySpec = {
        query: "SELECT * FROM c ORDER BY c.receivedDateTime DESC",
      };
    }

    const { resources } = await container.items.query(querySpec).fetchAll();

    // Sanitize bodies before sending to client
    const emails = resources.map((email) => {
      if (email.body) {
        email.body = sanitize(extractBody(email.body));
      }
      return email;
    });

    res.json(emails);
  } catch (err) {
    console.error("Failed to fetch emails from Cosmos DB:", err.message);
    res.status(503).json({ error: "Unable to load emails. Please try again later." });
  }
});

app.get("/api/emails/:id", async (req, res) => {
  try {
    const container = getCosmosContainer();
    const querySpec = {
      query: "SELECT * FROM c WHERE c.id = @id",
      parameters: [{ name: "@id", value: req.params.id }],
    };

    const { resources } = await container.items.query(querySpec).fetchAll();

    if (resources.length === 0) {
      return res.status(404).json({ error: "Email not found" });
    }

    const email = resources[0];
    if (email.body) {
      email.body = sanitize(extractBody(email.body));
    }

    res.json(email);
  } catch (err) {
    console.error("Failed to fetch email detail from Cosmos DB:", err.message);
    res.status(503).json({ error: "Unable to load this email. Please try again later." });
  }
});

app.get("/api/emails/:id/attachments/:filename", async (req, res) => {
  const { id, filename } = req.params;
  const blobPath = `${id}/${filename}`;

  try {
    const containerClient = getBlobService().getContainerClient(STORAGE_CONTAINER);
    const blobClient = containerClient.getBlobClient(blobPath);
    const download = await blobClient.download(0);

    const contentType =
      download.contentType || "application/octet-stream";

    res.set({
      "Content-Type": contentType,
      "Content-Disposition": `attachment; filename="${filename}"`,
    });

    if (download.contentLength != null) {
      res.set("Content-Length", String(download.contentLength));
    }

    download.readableStreamBody.pipe(res);
  } catch (err) {
    console.error("Attachment download error:", err.message);
    res.status(404).json({ error: "Attachment not found" });
  }
});

// SPA fallback — serve index.html for all non-API routes
app.get("*", (_req, res) => {
  res.sendFile(path.join(distPath, "index.html"));
});

// ---------------------------------------------------------------------------
// Start (only when run directly, not imported for testing)
// ---------------------------------------------------------------------------
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`Email Analyzer web app listening on port ${PORT}`);
  });
}

module.exports = app;
