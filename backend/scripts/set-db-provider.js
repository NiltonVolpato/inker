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

const datasourceRegex = /datasource db \{\s*provider\s*=\s*"[^"]+"\s*url\s*=\s*env\("DATABASE_URL"\)\s*\}/;
if (!datasourceRegex.test(schema)) {
  console.error(`[set-db-provider] Error: Could not find matching datasource block in schema.prisma.`);
  process.exit(1);
}

schema = schema.replace(
  datasourceRegex,
  `datasource db {\n  provider = "${provider}"\n  url      = env("DATABASE_URL")\n}`
);

if (provider === 'sqlite') {
  if (!schema.includes(' Json?') && !schema.includes(' Json')) {
    console.error(`[set-db-provider] Error: Found no 'Json' or 'Json?' fields to convert to 'String' for SQLite provider. Schema might have changed.`);
    process.exit(1);
  }

  schema = schema.replace(/ Json\?/g, ' String?');
  schema = schema.replace(/ Json/g, ' String');
}

fs.writeFileSync(generatedSchemaPath, schema);
console.log(`Database provider set to: ${provider} (written to ${generatedSchemaPath})`);