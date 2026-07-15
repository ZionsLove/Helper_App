// Backend checkout catalog.
// Generated from ../lib/catalog_items.dart by `npm run sync-catalog`.
// Edit prices/tags/items in lib/catalog_items.dart, not this wrapper.

const catalogItems = require("./catalog_items.json");

function getCatalogItem(itemId) {
  return catalogItems[itemId] || null;
}

module.exports = {
  catalogItems,
  getCatalogItem,
};
