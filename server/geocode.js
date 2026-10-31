import { readFileSync } from "node:fs";

// Where an address is, for the local delivery radius (docs/design/local-delivery.md).
// Street addresses go to the free US Census Geocoder (no key). ZIP codes use the
// Census ZCTA centroids bundled in data/ (scripts/zcta-centroids.hs), which is
// all a wallet reveals before the buyer confirms.

const CENSUS = process.env.CENSUS_GEOCODER_URL || "https://geocoding.geo.census.gov/geocoder/locations/address";

// When a Census lookup last failed (timeout or error, not "no match");
// /api/health reports it.
export let lastGeocodeFailure = 0;

let centroids;
function zctaCentroids() {
  centroids ??= JSON.parse(readFileSync(new URL("./data/zcta-centroids.json", import.meta.url), "utf8"));
  return centroids;
}

// The centroid of a 5-digit ZIP (or ZIP+4), or null if unknown.
export function zipCentroid(zip) {
  const found = zctaCentroids()[String(zip ?? "").trim().slice(0, 5)];
  return found ? { lat: found[0], lon: found[1] } : null;
}

// { lat, lon } for a street address, null when Census has no match. Throws when
// Census can't be reached, so callers can tell an outage from a bad address.
export async function geocodeAddress({ line1, city, state, postal_code }) {
  const url = new URL(CENSUS);
  url.searchParams.set("street", line1 ?? "");
  url.searchParams.set("city", city ?? "");
  url.searchParams.set("state", state ?? "");
  url.searchParams.set("zip", postal_code ?? "");
  url.searchParams.set("benchmark", "Public_AR_Current");
  url.searchParams.set("format", "json");
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error(`Census geocoder returned ${response.status}`);
    const match = (await response.json())?.result?.addressMatches?.[0];
    return match ? { lat: match.coordinates.y, lon: match.coordinates.x } : null;
  } catch (error) {
    lastGeocodeFailure = Date.now();
    throw error;
  }
}

// Great-circle distance in miles.
export function milesBetween(a, b) {
  const rad = (degrees) => (degrees * Math.PI) / 180;
  const h = Math.sin(rad(b.lat - a.lat) / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(rad(b.lon - a.lon) / 2) ** 2;
  return 2 * 3958.8 * Math.asin(Math.sqrt(h));
}
