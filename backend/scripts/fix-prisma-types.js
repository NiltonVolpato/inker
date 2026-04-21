const fs = require('fs');
const path = require('path');

const provider = process.env.DB_PROVIDER || 'postgresql';
if (provider !== 'sqlite') {
  // Only apply JSON type fixes when using SQLite
  process.exit(0);
}

const dtsPath = path.join(__dirname, '../node_modules/.prisma/client/index.d.ts');
if (fs.existsSync(dtsPath)) {
  let dts = fs.readFileSync(dtsPath, 'utf8');
  const fields = ['config', 'headers', 'lastData', 'metadata', 'defaultConfig', 'dataHeaders', 'settingsSchema', 'settings', 'settingsEncrypted'];
  
  let anyError = false;

  fields.forEach(field => {
    let replacements = 0;
    const regex1 = new RegExp(`(\\b${field}\\s*\\??\\s*:)\\s*string(\\s*\\|\\s*null)?(?=[\\n\\r;,])`, 'g');
    dts = dts.replace(regex1, (match, p1, p2) => {
      replacements++;
      return `${p1} any`;
    });
    
    const regex2 = new RegExp(`(\\b${field}\\s*\\??\\s*:)\\s*[a-zA-Z<>\\"_]+\\s*\\|\\s*string\\s*\\|\\s*null(?=[\\n\\r;,])`, 'g');
    dts = dts.replace(regex2, (match, p1) => {
      replacements++;
      return `${p1} any`;
    });
    
    const regex3 = new RegExp(`(\\b${field}\\s*\\??\\s*:)\\s*[a-zA-Z<>\\"_]+\\s*\\|\\s*string(?=[\\n\\r;,])`, 'g');
    dts = dts.replace(regex3, (match, p1) => {
      replacements++;
      return `${p1} any`;
    });

    if (replacements === 0) {
      console.error(`[fix-prisma-types] Error: Zero replacements made for field '${field}'. Prisma generated types might have changed.`);
      anyError = true;
    }
  });

  // replace Prisma.DbNull
  const dbNullRegex = /Prisma\.DbNull/g;
  const dbNullMatches = (dts.match(dbNullRegex) || []).length;
  if (dbNullMatches > 0) {
    dts = dts.replace(dbNullRegex, 'any');
  }

  if (anyError) {
    console.error(`[fix-prisma-types] Script failed due to unmatched regexes. Please update regex patterns in ${__filename}`);
    process.exit(1);
  }

  fs.writeFileSync(dtsPath, dts);
  console.log('Fixed Prisma TS types for SQLite');
}