'use strict';

const fs = require('fs');
const path = require('path');
const xml2js = require('xml2js');

const supportedTypes = new Set([
  'ApexClass',
  'ApexTrigger',
  'ApexPage',
  'ApexComponent',
  'CustomObject',
  'CustomField',
  'Layout',
  'Profile',
  'PermissionSet',
  'ValidationRule',
  'Flow',
  'RecordType',
  'CustomMetadata',
  'LightningComponentBundle',
  'StaticResource',
]);

async function parseDestructiveXml(xmlPath) {
  const resolvedPath = path.resolve(xmlPath);
  if (!fs.existsSync(resolvedPath)) {
    throw new Error(`destructiveChanges.xml not found at ${resolvedPath}`);
  }

  const xml = fs.readFileSync(resolvedPath, 'utf8');
  let parsed;
  try {
    parsed = await xml2js.parseStringPromise(xml, {
      explicitArray: true,
      trim: true,
      normalizeTags: false,
      normalize: true,
    });
  } catch (err) {
    throw new Error(`Invalid XML in ${resolvedPath}: ${err.message}`);
  }

  const packageNode = parsed && parsed.Package;
  if (!packageNode || !Array.isArray(packageNode.types)) {
    return [];
  }

  const components = [];
  for (const typeNode of packageNode.types) {
    const typeName = typeNode.name && typeNode.name[0];
    const members = Array.isArray(typeNode.members) ? typeNode.members : [];
    if (!typeName || members.length === 0) {
      continue;
    }

    for (const rawMember of members) {
      const member = String(rawMember || '').trim();
      if (!member) {
        continue;
      }

      components.push({
        type: String(typeName).trim(),
        name: member,
        supportedType: supportedTypes.has(String(typeName).trim()),
      });
    }
  }

  return components;
}

module.exports = {
  parseDestructiveXml,
  supportedTypes,
};
