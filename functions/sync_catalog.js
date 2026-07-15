const fs = require("fs");
const path = require("path");

const catalogSourcePath = path.join(__dirname, "..", "lib", "catalog_items.dart");
const catalogOutputPath = path.join(__dirname, "catalog_items.json");

function extractList(source, variableName) {
  const assignmentIndex = source.indexOf(variableName);
  if (assignmentIndex === -1) {
    throw new Error(`Could not find ${variableName} in catalog_items.dart`);
  }

  const start = source.indexOf("[", assignmentIndex);
  if (start === -1) {
    throw new Error(`Could not find list start for ${variableName}`);
  }

  let depth = 0;
  let quote = null;
  let escaping = false;

  for (let index = start; index < source.length; index++) {
    const char = source[index];
    const previous = source[index - 1];
    const next = source[index + 1];

    if (quote) {
      if (escaping) {
        escaping = false;
      } else if (char === "\\") {
        escaping = true;
      } else if (char === quote) {
        quote = null;
      }
      continue;
    }

    if (char === "/" && next === "/") {
      index = source.indexOf("\n", index);
      if (index === -1) break;
      continue;
    }

    if (char === "/" && next === "*") {
      const commentEnd = source.indexOf("*/", index + 2);
      if (commentEnd === -1) {
        throw new Error(`Unclosed block comment in ${variableName}`);
      }
      index = commentEnd + 1;
      continue;
    }

    if (char === "\"" || char === "'") {
      quote = char;
      continue;
    }

    if (char === "[") depth++;
    if (char === "]") depth--;

    if (depth === 0) {
      return source.slice(start, index + 1);
    }

    if (previous === "\r") {
      continue;
    }
  }

  throw new Error(`Could not find list end for ${variableName}`);
}

function parseDartList(listText, variableName) {
  const jsText = listText.replaceAll(
    /requiresCarDeliveryKey\s*:/g,
    "\"requiresCarDelivery\":",
  );

  try {
    return Function(`"use strict"; return (${jsText});`)();
  } catch (error) {
    throw new Error(`Could not parse ${variableName}: ${error.message}`);
  }
}

function slug(value) {
  const text = String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return text || "item";
}

function catalogId(tradeType, name) {
  return `${tradeType.toLowerCase()}:${slug(name)}`;
}

function normalizeItem(item, tradeType) {
  const name = String(item.name || "").trim();
  if (!name) {
    throw new Error(`${tradeType} catalog has an item without a name`);
  }

  const price = Number(item.price || 0);
  if (!Number.isFinite(price) || price < 0) {
    throw new Error(`${tradeType} catalog item "${name}" has an invalid price`);
  }

  return {
    tradeType,
    name,
    price,
    priceCents: Math.round(price * 100),
    image: item.image || null,
    description: item.description || "",
    categories: Array.isArray(item.categories) ? item.categories : [],
    specialtyStoreTag: item.specialtyStoreTag || null,
    requiresCarDelivery: item.requiresCarDelivery === true,
  };
}

function addItems(catalog, items, tradeType) {
  for (const item of items) {
    const normalized = normalizeItem(item, tradeType);
    const id = catalogId(tradeType, normalized.name);

    if (catalog[id]) {
      if (JSON.stringify(catalog[id]) === JSON.stringify(normalized)) {
        console.warn(`Skipped duplicate catalog item: ${id}`);
        continue;
      }

      throw new Error(`Conflicting duplicate catalog item ID: ${id}`);
    }

    catalog[id] = normalized;
  }
}

const source = fs.readFileSync(catalogSourcePath, "utf8");
const plumbingItems = parseDartList(
  extractList(source, "plumbingCatalogParts"),
  "plumbingCatalogParts",
);
const hvacItems = parseDartList(
  extractList(source, "hvacCatalogParts"),
  "hvacCatalogParts",
);

const catalog = {};
addItems(catalog, plumbingItems, "Plumbing");
addItems(catalog, hvacItems, "HVAC");

fs.writeFileSync(catalogOutputPath, `${JSON.stringify(catalog, null, 2)}\n`);

console.log(
  `Synced ${Object.keys(catalog).length} catalog items to ${path.relative(
    path.join(__dirname, ".."),
    catalogOutputPath,
  )}`,
);
