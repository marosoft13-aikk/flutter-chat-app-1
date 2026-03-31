// Simple Cloudinary signing server (Node/Express) - fixed version
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const cloudinary = require('cloudinary').v2;

// Load env and basic validation / logging
const { CLOUDINARY_API_KEY, CLOUDINARY_API_SECRET, CLOUDINARY_CLOUD_NAME, PORT } = process.env;
console.log('Loaded env ->', {
  CLOUDINARY_API_KEY: CLOUDINARY_API_KEY ? '[REDACTED]' : undefined,
  CLOUDINARY_CLOUD_NAME,
  PORT,
});

if (!CLOUDINARY_API_KEY || !CLOUDINARY_API_SECRET || !CLOUDINARY_CLOUD_NAME) {
  console.error('Missing Cloudinary env vars. Check .env and restart the server.');
  console.error('Expected variables: CLOUDINARY_API_KEY, CLOUDINARY_API_SECRET, CLOUDINARY_CLOUD_NAME, PORT (optional)');
  process.exit(1);
}

// Quick sanity checks
if (!/^\d+$/.test(CLOUDINARY_API_KEY)) {
  console.warn('Warning: CLOUDINARY_API_KEY does not look like all-digits. Make sure it is correct and not concatenated with other codes.');
}
if (CLOUDINARY_API_KEY.length < 6) {
  console.warn('Warning: CLOUDINARY_API_KEY looks unusually short.');
}

cloudinary.config({
  cloud_name: CLOUDINARY_CLOUD_NAME,
  api_key: CLOUDINARY_API_KEY,
  api_secret: CLOUDINARY_API_SECRET,
});

const app = express();
app.use(cors());
app.use(bodyParser.json());

// Health
app.get('/', (req, res) => {
  res.send('Cloudinary sign server running');
});

// Optional: quick debug endpoint to verify sign payload (no secrets returned)
app.get('/_debug', (req, res) => {
  res.json({
    ok: true,
    cloud_name: CLOUDINARY_CLOUD_NAME,
    api_key_present: !!CLOUDINARY_API_KEY,
  });
});

// POST /cloudinary/sign
// body: { conversationId?: string, folder?: string }
// Returns: { signature, timestamp, api_key, cloud_name, folder }
app.post('/cloudinary/sign', (req, res) => {
  try {
    const { folder, conversationId } = req.body || {};
    const timestamp = Math.floor(Date.now() / 1000);
    const finalFolder = folder || (conversationId ? `chat_uploads/${conversationId}` : 'chat_uploads');

    // Sign the minimal params (folder + timestamp). Adjust if you sign more params.
    const paramsToSign = { folder: finalFolder, timestamp };

    // Create signature using cloudinary utils
    const signature = cloudinary.utils.api_sign_request(paramsToSign, CLOUDINARY_API_SECRET);

    return res.json({
      signature,
      timestamp,
      api_key: CLOUDINARY_API_KEY,
      cloud_name: CLOUDINARY_CLOUD_NAME,
      folder: finalFolder,
    });
  } catch (err) {
    console.error('Sign error', err && err.stack ? err.stack : err);
    return res.status(500).json({ error: 'Sign failed', details: err && err.message ? err.message : String(err) });
  }
});

const listenPort = PORT || 3000;
app.listen(listenPort, () => console.log(`Cloudinary sign server running on port ${listenPort}`));