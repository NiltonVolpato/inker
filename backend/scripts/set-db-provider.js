const fs = require('fs');
const path = require('path');

const provider = process.env.DB_PROVIDER || 'postgresql';

if (!['postgresql', 'sqlite'].includes(provider)) {
  console.error(`Invalid DB_PROVIDER: ${provider}. Must be 'postgresql' or 'sqlite'.`);
  process.exit(1);
}

const schemaPath = path.join(__dirname, '../prisma/schema.prisma');
const generatedDir = path.join(__dirname, '../prisma/.generated');
const generatedSchemaPath = path.join(generatedDir, 'schema.prisma');

if (!fs.existsSync(generatedDir)) {
  fs.mkdirSync(generatedDir, { recursive: true });
}

let schema = fs.readFileSync(schemaPath, 'utf8');

schema = schema.replace(
  /datasource db \{\s*provider\s*=\s*"[^"]+"\s*url\s*=\s*env\("DATABASE_URL"\)\s*\}/,
  `datasource db {\n  provider = "${provider}"\n  url      = env("DATABASE_URL")\n}`
);

if (provider === 'sqlite') {
  schema = schema.replace(/ Json\?/g, ' String?');
  schema = schema.replace(/ Json/g, ' String');
}

fs.writeFileSync(generatedSchemaPath, schema);
console.log(`Database provider set to: ${provider} (written to ${generatedSchemaPath})`);