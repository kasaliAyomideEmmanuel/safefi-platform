# SafeFi Platform — Netlify Deployment Guide
**SafeFi Tech Solutions Ltd | Kasali Ayomide Emmanuel**

---

## Option A — Deploy via GitHub (Recommended)

### Step 1 — Create GitHub repository
1. Go to https://github.com and sign in
2. Click **New repository**
3. Name it `safefi-platform`
4. Set to **Public**
5. Click **Create repository**

### Step 2 — Upload files
1. Click **uploading an existing file**
2. Drag and drop ALL files from this folder keeping the folder structure:
```
safefi-platform/
├── src/
│   ├── main.jsx
│   └── App.jsx
├── public/
│   └── favicon.svg
├── index.html
├── package.json
├── vite.config.js
├── netlify.toml
└── DEPLOY_INSTRUCTIONS.md
```
3. Click **Commit changes**

### Step 3 — Connect to Netlify
1. Go to https://netlify.com and sign in
2. Click **Add new site → Import an existing project**
3. Choose **GitHub**
4. Select your `safefi-platform` repository
5. Build settings are auto-detected from netlify.toml:
   - Build command: `npm run build`
   - Publish directory: `dist`
6. Click **Deploy site**

### Step 4 — Set custom domain
1. In Netlify → Domain settings
2. Add your custom domain: `safefi.netlify.app` (already yours)
3. Or point to `app.safefi.io` when ready

---

## Option B — Deploy via Netlify CLI (Faster)

```bash
# Install Netlify CLI
npm install -g netlify-cli

# Navigate to this folder
cd safefi-netlify

# Install dependencies
npm install

# Build
npm run build

# Deploy
netlify deploy --prod --dir=dist
```

---

## After Deployment

Your SafeFi platform will be live at your Netlify URL with:
- ✅ Overview dashboard with live stats
- ✅ Pool balances
- ✅ Claims registry
- ✅ My Protection tab (wallet connect + SFI redeem)
- ✅ Partner onboarding form
- ✅ All 8 contract addresses with BscScan links
- ✅ MetaMask wallet connect
- ✅ Auto switch to BNB Chain Testnet

---

*SafeFi Tech Solutions Ltd © 2026*
